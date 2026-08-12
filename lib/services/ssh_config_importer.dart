import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/proxy_config.dart';
import '../models/saved_host_profile.dart';
import 'host_profiles_store.dart';

enum ConflictResolution { skip, overwrite, duplicate }

class SshConfigEntry {
  SshConfigEntry({
    required this.host,
    required this.hostname,
    this.port = 22,
    this.user = '',
    this.identityFile,
    this.proxyJump,
  });

  /// `Host` 别名（配置块名）。
  final String host;
  final String hostname;
  final int port;
  final String user;
  final String? identityFile;
  final String? proxyJump;

  String get displayLabel => host;

  String get subtitle {
    final u = user.isEmpty ? '?' : user;
    return '$u@$hostname:$port';
  }
}

class ImportResult {
  ImportResult({
    required this.imported,
    required this.skipped,
    required this.overwritten,
    required this.duplicated,
  });

  final int imported;
  final int skipped;
  final int overwritten;
  final int duplicated;

  int get total => imported + skipped + overwritten + duplicated;
}

/// 手动解析 `~/.ssh/config`（不依赖 dartssh2 SSHConfig）。
class SshConfigImporter {
  SshConfigImporter();

  static String defaultConfigPath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    return p.join(home, '.ssh', 'config');
  }

  Future<List<SshConfigEntry>> parseConfig([String? path]) async {
    if (kIsWeb) return const [];
    final filePath = path ?? defaultConfigPath();
    final file = File(filePath);
    if (!await file.exists()) return const [];
    final text = await file.readAsString();
    return parseConfigText(text);
  }

  /// 纯文本解析，便于单测。
  List<SshConfigEntry> parseConfigText(String text) {
    final blocks = <_HostBlock>[];
    _HostBlock? current;

    for (final rawLine in const LineSplitter().convert(text)) {
      var line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      // 行内注释
      final hash = line.indexOf('#');
      if (hash > 0) line = line.substring(0, hash).trimRight();

      final parts = line.split(RegExp(r'\s+'));
      if (parts.isEmpty) continue;
      final key = parts.first.toLowerCase();
      final value = parts.length > 1 ? parts.sublist(1).join(' ').trim() : '';

      if (key == 'host') {
        if (current != null && current.patterns.isNotEmpty) {
          blocks.add(current);
        }
        current = _HostBlock(
          patterns: value
              .split(RegExp(r'\s+'))
              .where((e) => e.isNotEmpty)
              .toList(),
        );
        continue;
      }
      current ??= _HostBlock(patterns: const []);
      switch (key) {
        case 'hostname':
          current.hostname = value;
          break;
        case 'port':
          current.port = int.tryParse(value) ?? current.port;
          break;
        case 'user':
          current.user = value;
          break;
        case 'identityfile':
          current.identityFile = value;
          break;
        case 'proxyjump':
          current.proxyJump = value;
          break;
      }
    }
    if (current != null && current.patterns.isNotEmpty) {
      blocks.add(current);
    }

    final entries = <SshConfigEntry>[];
    for (final b in blocks) {
      for (final pattern in b.patterns) {
        if (_isWildcardPattern(pattern)) continue;
        final hostname =
            (b.hostname != null && b.hostname!.trim().isNotEmpty)
            ? b.hostname!.trim()
            : pattern;
        entries.add(
          SshConfigEntry(
            host: pattern,
            hostname: hostname,
            port: b.port,
            user: b.user?.trim() ?? '',
            identityFile: _expandHome(b.identityFile),
            proxyJump: b.proxyJump?.trim(),
          ),
        );
      }
    }
    return entries;
  }

  static bool _isWildcardPattern(String pattern) {
    return pattern.contains('*') || pattern.contains('?') || pattern.contains('!');
  }

  static String? _expandHome(String? path) {
    if (path == null) return null;
    final t = path.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('~/') || t == '~') {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      if (home.isEmpty) return t;
      if (t == '~') return home;
      return p.join(home, t.substring(2));
    }
    return t;
  }

  List<SavedHostProfile> toProfiles(List<SshConfigEntry> entries) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      for (var i = 0; i < entries.length; i++)
        SavedHostProfile(
          id: 'sshcfg_${now}_$i',
          label: entries[i].host,
          host: entries[i].hostname,
          port: entries[i].port,
          username: entries[i].user.isEmpty ? 'root' : entries[i].user,
          keyPath: entries[i].identityFile,
          password: null,
          updatedAtMs: now + i,
          // ProxyJump 仅记录字符串到 proxyConfig.host 字段不够；导入时若有 ProxyJump
          // 先把跳板别名写入 password 以外的扩展：用 proxyConfig 存跳板主机名占位。
          proxyConfig: _proxyFromJump(entries[i].proxyJump),
        ),
    ];
  }

  static ProxyConfig? _proxyFromJump(String? proxyJump) {
    if (proxyJump == null || proxyJump.trim().isEmpty) return null;
    // 仅取第一跳；格式可为 user@host:port 或 host
    final first = proxyJump.split(',').first.trim();
    if (first.isEmpty) return null;
    var user = '';
    var hostPort = first;
    final at = first.lastIndexOf('@');
    if (at >= 0) {
      user = first.substring(0, at);
      hostPort = first.substring(at + 1);
    }
    var host = hostPort;
    var port = 22;
    // IPv6 in brackets [::1]:22
    if (hostPort.startsWith('[')) {
      final end = hostPort.indexOf(']');
      if (end > 0) {
        host = hostPort.substring(1, end);
        final rest = hostPort.substring(end + 1);
        if (rest.startsWith(':')) {
          port = int.tryParse(rest.substring(1)) ?? 22;
        }
      }
    } else {
      final colon = hostPort.lastIndexOf(':');
      if (colon > 0 && !hostPort.contains('::')) {
        final maybePort = int.tryParse(hostPort.substring(colon + 1));
        if (maybePort != null) {
          host = hostPort.substring(0, colon);
          port = maybePort;
        }
      }
    }
    return ProxyConfig(
      type: ProxyType.sshJump,
      host: host,
      port: port,
      username: user.isEmpty ? 'root' : user,
    );
  }

  Future<ImportResult> importTo(
    HostProfilesStore store, {
    List<SshConfigEntry>? entries,
    ConflictResolution conflict = ConflictResolution.skip,
    String? configPath,
  }) async {
    await store.ensureLoaded();
    final parsed = entries ?? await parseConfig(configPath);
    var imported = 0;
    var skipped = 0;
    var overwritten = 0;
    var duplicated = 0;

    for (final entry in parsed) {
      final profiles = toProfiles([entry]);
      if (profiles.isEmpty) continue;
      final draft = profiles.first;
      SavedHostProfile? existing;
      for (final p in store.profiles) {
        if (p.label == draft.label ||
            p.matchesEndpoint(
              host: draft.host,
              port: draft.port,
              username: draft.username,
            )) {
          existing = p;
          break;
        }
      }

      if (existing == null) {
        await store.add(
          label: draft.label,
          host: draft.host,
          port: draft.port,
          username: draft.username,
          keyPath: draft.keyPath,
          password: draft.password,
          proxyConfig: draft.proxyConfig,
        );
        imported++;
        continue;
      }

      switch (conflict) {
        case ConflictResolution.skip:
          skipped++;
          break;
        case ConflictResolution.overwrite:
          await store.updateById(
            id: existing.id,
            label: draft.label,
            host: draft.host,
            port: draft.port,
            username: draft.username,
            keyPath: draft.keyPath,
            password: draft.password,
            proxyConfig: draft.proxyConfig,
            clearProxyConfig: draft.proxyConfig == null,
          );
          overwritten++;
          break;
        case ConflictResolution.duplicate:
          await store.add(
            label: '${draft.label} (import)',
            host: draft.host,
            port: draft.port,
            username: draft.username,
            keyPath: draft.keyPath,
            password: draft.password,
            proxyConfig: draft.proxyConfig,
          );
          duplicated++;
          break;
      }
    }

    return ImportResult(
      imported: imported,
      skipped: skipped,
      overwritten: overwritten,
      duplicated: duplicated,
    );
  }
}

class _HostBlock {
  _HostBlock({required this.patterns});

  final List<String> patterns;
  String? hostname;
  int port = 22;
  String? user;
  String? identityFile;
  String? proxyJump;
}
