import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../io/host_profiles_disk.dart';

/// 按主机持久化助手对话（application support 目录下的 JSON）。
final class AssistantChatStore {
  AssistantChatStore();

  static const _dirName = 'assistant_chats';

  static final AssistantChatStore instance = AssistantChatStore();

  Future<String> _dirPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/$_dirName';
  }

  Future<String> _filePath(String hostKey) async {
    final safe = _sanitizeHostKey(hostKey);
    final dir = await _dirPath();
    return '$dir/$safe.json';
  }

  static String _sanitizeHostKey(String hostKey) {
    final s = hostKey.trim();
    if (s.isEmpty) return '_unknown';
    return s.replaceAll(RegExp(r'[^A-Za-z0-9@._+:-]'), '_');
  }

  Future<void> save(String hostKey, List<Map<String, Object?>> messages) async {
    if (kIsWeb) return;
    final key = hostKey.trim();
    if (key.isEmpty) return;
    try {
      final path = await _filePath(key);
      final payload = {
        'hostKey': key,
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
        'messages': messages,
      };
      await writeUtf8EnsureParent(
        path,
        const JsonEncoder.withIndent('  ').convert(payload),
      );
    } catch (e, st) {
      debugPrint('AssistantChatStore.save: $e\n$st');
    }
  }

  Future<List<Map<String, Object?>>> load(String hostKey) async {
    if (kIsWeb) return const [];
    final key = hostKey.trim();
    if (key.isEmpty) return const [];
    try {
      final path = await _filePath(key);
      final raw = await readUtf8IfExists(path);
      if (raw == null || raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const [];
      final list = decoded['messages'];
      if (list is! List) return const [];
      final out = <Map<String, Object?>>[];
      for (final e in list) {
        if (e is Map) {
          out.add(Map<String, Object?>.from(e));
        }
      }
      return out;
    } catch (e, st) {
      debugPrint('AssistantChatStore.load: $e\n$st');
      return const [];
    }
  }

  Future<void> delete(String hostKey) async {
    if (kIsWeb) return;
    final key = hostKey.trim();
    if (key.isEmpty) return;
    try {
      final path = await _filePath(key);
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (e, st) {
      debugPrint('AssistantChatStore.delete: $e\n$st');
    }
  }

  Future<List<String>> listHostsWithChats() async {
    if (kIsWeb) return const [];
    try {
      final dir = Directory(await _dirPath());
      if (!await dir.exists()) return const [];
      final keys = <String>[];
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.json')) continue;
        try {
          final raw = await entity.readAsString();
          final decoded = jsonDecode(raw);
          if (decoded is Map && decoded['hostKey'] is String) {
            keys.add(decoded['hostKey'] as String);
          } else {
            final base = entity.uri.pathSegments.isNotEmpty
                ? entity.uri.pathSegments.last
                : '';
            if (base.endsWith('.json')) {
              keys.add(base.substring(0, base.length - 5));
            }
          }
        } catch (_) {
          continue;
        }
      }
      keys.sort();
      return keys;
    } catch (e, st) {
      debugPrint('AssistantChatStore.listHostsWithChats: $e\n$st');
      return const [];
    }
  }
}
