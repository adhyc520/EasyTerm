import 'remote_containers.dart' show isSafeContainerRef;
import 'remote_process_list.dart';
import 'ssh_workspace_controller.dart';

/// 日志来源。
enum RemoteLogSource {
  /// Linux journalctl / Windows 事件日志。
  journal,

  /// 指定文件尾部（tail）。
  file,

  /// `docker logs`（unit 字段存容器名/ID）。
  docker,
}

/// 一条日志行。
class RemoteLogLine {
  const RemoteLogLine({
    required this.text,
    this.level,
    this.timestamp,
  });

  final String text;
  final String? level;
  final String? timestamp;

  bool get isError {
    final l = (level ?? text).toLowerCase();
    return l.contains('error') ||
        l.contains('err') ||
        l.contains('fatal') ||
        l.contains('crit') ||
        l.contains('emerg') ||
        l.contains(' exception');
  }

  bool get isWarn {
    final l = (level ?? text).toLowerCase();
    return l.contains('warn') || l.contains('warning');
  }
}

class RemoteLogSnapshot {
  const RemoteLogSnapshot({
    required this.os,
    required this.source,
    required this.lines,
    this.label,
    this.error,
  });

  final RemoteOsKind os;
  final RemoteLogSource source;
  final List<RemoteLogLine> lines;
  final String? label;
  final String? error;
}

bool isSafeLogUnit(String name) {
  if (name.isEmpty || name.length > 128) return false;
  return RegExp(r'^[A-Za-z0-9_@.\-]+$').hasMatch(name);
}

/// 允许相对/绝对路径常见字符（禁止 shell 元字符）。
bool isSafeLogPath(String path) {
  if (path.isEmpty || path.length > 512) return false;
  if (path.contains('..')) return false;
  return RegExp(r'^[A-Za-z0-9_./\\:@+\-]+$').hasMatch(path);
}

String? _shellSingleQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// 构建 Linux 实时跟随命令；不支持时返回 `null`（保留快照）。
String? buildLinuxLogFollowCommand({
  required RemoteLogSource source,
  String? unit,
  String? path,
  int lines = 300,
  String? priority,
  int? pid,
}) {
  final n = lines.clamp(20, 2000);
  switch (source) {
    case RemoteLogSource.docker:
      final ref = (unit ?? '').trim();
      if (!isSafeContainerRef(ref)) return null;
      return 'docker logs -f --tail $n $ref 2>&1';
    case RemoteLogSource.file:
      final p = (path ?? '').trim();
      if (!isSafeLogPath(p)) return null;
      final q = _shellSingleQuote(p)!;
      return 'tail -F -n $n $q 2>&1';
    case RemoteLogSource.journal:
      final u = (unit ?? '').trim();
      if (u.isNotEmpty && !isSafeLogUnit(u)) return null;
      final pri = (priority ?? '').trim().toLowerCase();
      final priOk =
          RegExp(r'^(emerg|alert|crit|err|warning|notice|info|debug)$')
              .hasMatch(pri);
      final buf = StringBuffer(
        'journalctl -f --no-pager -n $n -o short-iso',
      );
      if (u.isNotEmpty) buf.write(' -u $u');
      if (priOk) buf.write(' -p $pri');
      if (pid != null && pid > 0) buf.write(' _PID=$pid');
      return buf.toString();
  }
}

/// 将原始文本行转为 [RemoteLogLine]（流式模式复用解析启发式）。
List<RemoteLogLine> remoteLogLinesFromRaw(List<String> rawLines) {
  return [
    for (final line in rawLines)
      if (line.trimRight().isNotEmpty)
        RemoteLogLine(
          text: line.trimRight(),
          level: _inferLevel(line),
        ),
  ];
}

Future<RemoteLogSnapshot?> fetchRemoteLogs(
  SshWorkspaceController controller, {
  RemoteOsKind? osHint,
  RemoteLogSource source = RemoteLogSource.journal,
  String? unit,
  String? path,
  int lines = 200,
  String? priority,
  int? pid,
}) async {
  if (!controller.connected) return null;
  final n = lines.clamp(20, 2000);
  final os = osHint ?? await detectRemoteOs(controller);
  switch (os) {
    case RemoteOsKind.linux:
      return _fetchLinux(
        controller,
        source: source,
        unit: unit,
        path: path,
        lines: n,
        priority: priority,
        pid: pid,
      );
    case RemoteOsKind.windows:
      return _fetchWindows(
        controller,
        source: source,
        unit: unit,
        path: path,
        lines: n,
      );
    case RemoteOsKind.unknown:
      final linux = await _fetchLinux(
        controller,
        source: source,
        unit: unit,
        path: path,
        lines: n,
        priority: priority,
        pid: pid,
      );
      if (linux.lines.isNotEmpty || linux.error == null) {
        return linux;
      }
      return _fetchWindows(
        controller,
        source: source,
        unit: unit,
        path: path,
        lines: n,
      );
  }
}

Future<RemoteLogSnapshot> _fetchLinux(
  SshWorkspaceController controller, {
  required RemoteLogSource source,
  String? unit,
  String? path,
  required int lines,
  String? priority,
  int? pid,
}) async {
  if (source == RemoteLogSource.docker) {
    final ref = (unit ?? '').trim();
    if (!isSafeContainerRef(ref)) {
      return const RemoteLogSnapshot(
        os: RemoteOsKind.linux,
        source: RemoteLogSource.docker,
        lines: [],
        error: '非法容器名',
      );
    }
    final cmd =
        'docker logs --tail $lines $ref 2>&1 || echo "__ET_LOG_ERR__ docker logs failed"';
    final raw = await controller.runRemoteForStatus(cmd);
    return parseDockerLogs(raw ?? '', ref: ref, os: RemoteOsKind.linux);
  }

  if (source == RemoteLogSource.file) {
    final p = (path ?? '').trim();
    if (!isSafeLogPath(p)) {
      return const RemoteLogSnapshot(
        os: RemoteOsKind.linux,
        source: RemoteLogSource.file,
        lines: [],
        error: '非法文件路径',
      );
    }
    final q = _shellSingleQuote(p)!;
    final cmd =
        'tail -n $lines $q 2>&1 || echo "__ET_LOG_ERR__ cannot read file"';
    final raw = await controller.runRemoteForStatus(cmd);
    return parseLinuxFileTail(
      raw ?? '',
      path: p,
    );
  }

  final u = (unit ?? '').trim();
  if (u.isNotEmpty && !isSafeLogUnit(u)) {
    return const RemoteLogSnapshot(
      os: RemoteOsKind.linux,
      source: RemoteLogSource.journal,
      lines: [],
      error: '非法 unit 名',
    );
  }
  final pri = (priority ?? '').trim().toLowerCase();
  final priOk = RegExp(r'^(emerg|alert|crit|err|warning|notice|info|debug)$')
      .hasMatch(pri);
  final buf = StringBuffer(
    'journalctl --no-pager -n $lines -o short-iso',
  );
  if (u.isNotEmpty) buf.write(' -u $u');
  if (priOk) buf.write(' -p $pri');
  if (pid != null && pid > 0) buf.write(' _PID=$pid');
  buf.write(
    r' 2>/dev/null || (dmesg -T 2>/dev/null | tail -n '
    '$lines) || echo "__ET_LOG_ERR__ journalctl unavailable"',
  );
  final raw = await controller.runRemoteForStatus(buf.toString());
  final label = u.isNotEmpty
      ? u
      : (pid != null && pid > 0 ? 'PID $pid' : null);
  return parseLinuxJournal(
    raw ?? '',
    unit: label,
  );
}

Future<RemoteLogSnapshot> _fetchWindows(
  SshWorkspaceController controller, {
  required RemoteLogSource source,
  String? unit,
  String? path,
  required int lines,
}) async {
  if (source == RemoteLogSource.docker) {
    final ref = (unit ?? '').trim();
    if (!isSafeContainerRef(ref)) {
      return const RemoteLogSnapshot(
        os: RemoteOsKind.windows,
        source: RemoteLogSource.docker,
        lines: [],
        error: '非法容器名',
      );
    }
    final cmd =
        'docker.exe logs --tail $lines $ref 2>&1 || docker logs --tail $lines $ref 2>&1 || echo "__ET_LOG_ERR__ docker logs failed"';
    final raw = await controller.runRemoteForStatus(cmd);
    return parseDockerLogs(raw ?? '', ref: ref, os: RemoteOsKind.windows);
  }

  if (source == RemoteLogSource.file) {
    final p = (path ?? '').trim();
    if (!isSafeLogPath(p)) {
      return const RemoteLogSnapshot(
        os: RemoteOsKind.windows,
        source: RemoteLogSource.file,
        lines: [],
        error: '非法文件路径',
      );
    }
    final escaped = p.replaceAll("'", "''");
    final cmd =
        '''powershell -NoProfile -NonInteractive -Command "if(Test-Path -LiteralPath '$escaped'){ Get-Content -LiteralPath '$escaped' -Tail $lines } else { Write-Output '__ET_LOG_ERR__ file not found' }"''';
    final raw = await controller.runRemoteForStatus(cmd);
    return parseWindowsFileTail(raw ?? '', path: p);
  }

  final logName = ((unit ?? '').trim().isEmpty) ? 'System' : unit!.trim();
  if (!isSafeLogUnit(logName)) {
    return const RemoteLogSnapshot(
      os: RemoteOsKind.windows,
      source: RemoteLogSource.journal,
      lines: [],
      error: '非法日志名（可用 System / Application / Security）',
    );
  }
  final cmd =
      '''powershell -NoProfile -NonInteractive -Command "try { Get-WinEvent -LogName '$logName' -MaxEvents $lines -ErrorAction Stop | ForEach-Object { \$_.TimeCreated.ToString('s') + '|' + \$_.LevelDisplayName + '|' + ((\$_.Message -replace '[\\r\\n]+',' ') ) } } catch { Write-Output ('__ET_LOG_ERR__ ' + \$_.Exception.Message) }"''';
  final raw = await controller.runRemoteForStatus(cmd);
  return parseWindowsEventLog(raw ?? '', logName: logName);
}

RemoteLogSnapshot parseLinuxJournal(String raw, {String? unit}) {
  if (raw.contains('__ET_LOG_ERR__')) {
    final msg = raw
        .split('__ET_LOG_ERR__')
        .last
        .trim()
        .split(RegExp(r'[\r\n]+'))
        .first
        .trim();
    return RemoteLogSnapshot(
      os: RemoteOsKind.linux,
      source: RemoteLogSource.journal,
      lines: const [],
      label: unit,
      error: msg.isEmpty ? '无法读取 journal' : msg,
    );
  }
  final lines = <RemoteLogLine>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trimRight();
    if (t.isEmpty) continue;
    lines.add(_parseJournalLine(t));
  }
  return RemoteLogSnapshot(
    os: RemoteOsKind.linux,
    source: RemoteLogSource.journal,
    lines: lines,
    label: unit == null || unit.isEmpty ? 'journal' : unit,
  );
}

RemoteLogLine _parseJournalLine(String t) {
  // short-iso: 2026-08-06T12:00:00+08:00 host prog[pid]: message
  final m = RegExp(
    r'^(\d{4}-\d{2}-\d{2}T\S+)\s+\S+\s+(\S+?):\s*(.*)$',
  ).firstMatch(t);
  if (m != null) {
    final rest = m.group(3) ?? '';
    return RemoteLogLine(
      text: t,
      timestamp: m.group(1),
      level: _inferLevel('${m.group(2)} $rest'),
    );
  }
  return RemoteLogLine(text: t, level: _inferLevel(t));
}

RemoteLogSnapshot parseDockerLogs(
  String raw, {
  required String ref,
  required RemoteOsKind os,
}) {
  if (raw.contains('__ET_LOG_ERR__')) {
    final msg = raw
        .split('__ET_LOG_ERR__')
        .last
        .trim()
        .split(RegExp(r'[\r\n]+'))
        .first
        .trim();
    return RemoteLogSnapshot(
      os: os,
      source: RemoteLogSource.docker,
      lines: const [],
      label: ref,
      error: msg.isEmpty ? '无法读取 docker logs' : msg,
    );
  }
  final lines = <RemoteLogLine>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trimRight();
    if (t.isEmpty) continue;
    lines.add(RemoteLogLine(text: t, level: _inferLevel(t)));
  }
  return RemoteLogSnapshot(
    os: os,
    source: RemoteLogSource.docker,
    lines: lines,
    label: ref,
  );
}

RemoteLogSnapshot parseLinuxFileTail(String raw, {required String path}) {
  if (raw.contains('__ET_LOG_ERR__')) {
    return RemoteLogSnapshot(
      os: RemoteOsKind.linux,
      source: RemoteLogSource.file,
      lines: const [],
      label: path,
      error: '无法读取文件',
    );
  }
  final lines = <RemoteLogLine>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trimRight();
    if (t.isEmpty) continue;
    lines.add(RemoteLogLine(text: t, level: _inferLevel(t)));
  }
  return RemoteLogSnapshot(
    os: RemoteOsKind.linux,
    source: RemoteLogSource.file,
    lines: lines,
    label: path,
  );
}

RemoteLogSnapshot parseWindowsFileTail(String raw, {required String path}) {
  if (raw.contains('__ET_LOG_ERR__')) {
    final msg = raw.split('__ET_LOG_ERR__').last.trim();
    return RemoteLogSnapshot(
      os: RemoteOsKind.windows,
      source: RemoteLogSource.file,
      lines: const [],
      label: path,
      error: msg.isEmpty ? '无法读取文件' : msg,
    );
  }
  final lines = <RemoteLogLine>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trimRight();
    if (t.isEmpty) continue;
    lines.add(RemoteLogLine(text: t, level: _inferLevel(t)));
  }
  return RemoteLogSnapshot(
    os: RemoteOsKind.windows,
    source: RemoteLogSource.file,
    lines: lines,
    label: path,
  );
}

/// `Time|Level|Message`
RemoteLogSnapshot parseWindowsEventLog(String raw, {required String logName}) {
  if (raw.contains('__ET_LOG_ERR__')) {
    final msg = raw
        .split('__ET_LOG_ERR__')
        .last
        .trim()
        .split(RegExp(r'[\r\n]+'))
        .first
        .trim();
    return RemoteLogSnapshot(
      os: RemoteOsKind.windows,
      source: RemoteLogSource.journal,
      lines: const [],
      label: logName,
      error: msg.isEmpty ? '无法读取事件日志' : msg,
    );
  }
  final lines = <RemoteLogLine>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trimRight();
    if (t.isEmpty) continue;
    final parts = t.split('|');
    if (parts.length >= 3) {
      final ts = parts[0].trim();
      final level = parts[1].trim();
      final msg = parts.sublist(2).join('|').trim();
      lines.add(
        RemoteLogLine(
          text: '$ts  $level  $msg',
          timestamp: ts,
          level: level,
        ),
      );
    } else {
      lines.add(RemoteLogLine(text: t, level: _inferLevel(t)));
    }
  }
  return RemoteLogSnapshot(
    os: RemoteOsKind.windows,
    source: RemoteLogSource.journal,
    lines: lines,
    label: logName,
  );
}

String? _inferLevel(String text) {
  final l = text.toLowerCase();
  if (l.contains('emerg') ||
      l.contains('fatal') ||
      l.contains('crit') ||
      RegExp(r'\berror\b').hasMatch(l) ||
      RegExp(r'\berr\b').hasMatch(l)) {
    return 'error';
  }
  if (l.contains('warn')) return 'warning';
  if (l.contains('notice') || l.contains('info')) return 'info';
  if (l.contains('debug')) return 'debug';
  return null;
}
