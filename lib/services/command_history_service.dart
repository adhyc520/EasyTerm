import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../io/host_profiles_disk.dart';

class CommandRecord {
  CommandRecord({
    required this.id,
    required this.hostKey,
    required this.command,
    required this.cwd,
    this.exitCode,
    required this.timestamp,
    this.durationMs = 0,
  });

  final String id;
  final String hostKey;
  final String command;
  final String cwd;
  final int? exitCode;
  final DateTime timestamp;
  final int durationMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'hostKey': hostKey,
        'command': command,
        'cwd': cwd,
        if (exitCode != null) 'exitCode': exitCode,
        'timestamp': timestamp.toIso8601String(),
        'durationMs': durationMs,
      };

  factory CommandRecord.fromJson(Map<String, dynamic> j) {
    return CommandRecord(
      id: j['id']?.toString() ?? '',
      hostKey: j['hostKey']?.toString() ?? '',
      command: j['command']?.toString() ?? '',
      cwd: j['cwd']?.toString() ?? '/',
      exitCode: (j['exitCode'] as num?)?.toInt(),
      timestamp: DateTime.tryParse(j['timestamp']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Cross-session command history under `sessions/command_history.json`.
class CommandHistoryService {
  CommandHistoryService();

  static const int maxHistoryPerHost = 500;
  static const int maxHistoryGlobal = 2000;

  /// Optional shared instance for paste/submit hooks.
  static CommandHistoryService? shared;

  final List<CommandRecord> _records = [];
  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<void>? _persistFuture;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loadFuture ??= _loadFromDisk();
    await _loadFuture;
    _loaded = true;
    _loadFuture = null;
  }

  Future<String> _historyPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/sessions/command_history.json';
  }

  Future<void> _loadFromDisk() async {
    if (kIsWeb) return;
    try {
      final path = await _historyPath();
      final raw = await readUtf8IfExists(path);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _records
        ..clear()
        ..addAll(
          decoded.whereType<Map>().map(
                (e) => CommandRecord.fromJson(Map<String, dynamic>.from(e)),
              ),
        );
    } catch (e, st) {
      debugPrint('CommandHistoryService.load: $e\n$st');
      _records.clear();
    }
  }

  Future<void> _persist() async {
    if (kIsWeb) return;
    final path = await _historyPath();
    final payload = _records.map((r) => r.toJson()).toList();
    await writeUtf8EnsureParent(
      path,
      const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  void _schedulePersist() {
    _persistFuture = _persist().catchError((Object e, StackTrace st) {
      debugPrint('CommandHistoryService.persist: $e\n$st');
    });
  }

  Future<void> recordCommand(
    String hostKey,
    String command, {
    String cwd = '/',
    int? exitCode,
    int durationMs = 0,
  }) async {
    final cmd = command.trim();
    if (cmd.isEmpty) return;
    await ensureLoaded();

    final rec = CommandRecord(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      hostKey: hostKey,
      command: cmd,
      cwd: cwd,
      exitCode: exitCode,
      timestamp: DateTime.now(),
      durationMs: durationMs,
    );
    _records.insert(0, rec);

    // Cap per-host then global.
    final perHost = <String, int>{};
    final kept = <CommandRecord>[];
    for (final r in _records) {
      final n = (perHost[r.hostKey] ?? 0) + 1;
      if (n > maxHistoryPerHost) continue;
      perHost[r.hostKey] = n;
      kept.add(r);
      if (kept.length >= maxHistoryGlobal) break;
    }
    _records
      ..clear()
      ..addAll(kept);
    _schedulePersist();
  }

  Future<List<CommandRecord>> getHistory(
    String hostKey, {
    int limit = 50,
    String? query,
  }) async {
    await ensureLoaded();
    final q = query?.trim().toLowerCase();
    final out = <CommandRecord>[];
    for (final r in _records) {
      if (r.hostKey != hostKey) continue;
      if (q != null && q.isNotEmpty && !r.command.toLowerCase().contains(q)) {
        continue;
      }
      out.add(r);
      if (out.length >= limit) break;
    }
    return out;
  }

  Future<List<CommandRecord>> searchHistory(
    String query, {
    int limit = 50,
    String? hostKey,
  }) async {
    await ensureLoaded();
    final q = query.trim().toLowerCase();
    final out = <CommandRecord>[];
    for (final r in _records) {
      if (hostKey != null && r.hostKey != hostKey) continue;
      if (q.isNotEmpty && !r.command.toLowerCase().contains(q)) continue;
      out.add(r);
      if (out.length >= limit) break;
    }
    return out;
  }

  Future<void> clearHistory(String hostKey) async {
    await ensureLoaded();
    _records.removeWhere((r) => r.hostKey == hostKey);
    _schedulePersist();
    await _persistFuture;
  }
}
