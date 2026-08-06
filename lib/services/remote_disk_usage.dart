import 'remote_process_list.dart';
import 'ssh_workspace_controller.dart';

/// 目录占用分析中的一项（`du` / PowerShell 汇总）。
class RemoteDiskUsageEntry {
  const RemoteDiskUsageEntry({
    required this.name,
    required this.bytes,
    this.isTotal = false,
  });

  final String name;
  final int bytes;
  final bool isTotal;
}

class RemoteDiskUsageSnapshot {
  const RemoteDiskUsageSnapshot({
    required this.os,
    required this.path,
    required this.entries,
    this.error,
  });

  final RemoteOsKind os;
  final String path;
  final List<RemoteDiskUsageEntry> entries;
  final String? error;

  int? get totalBytes {
    for (final e in entries) {
      if (e.isTotal) return e.bytes;
    }
    if (entries.isEmpty) return null;
    return entries.fold<int>(0, (a, b) => a + b.bytes);
  }
}

bool isSafeDiskUsagePath(String path) {
  if (path.isEmpty || path.length > 512) return false;
  if (path.contains('..')) return false;
  return RegExp(r'^[A-Za-z0-9_./\\:@+\- ~]+$').hasMatch(path);
}

String _shellSingleQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

Future<RemoteDiskUsageSnapshot?> fetchRemoteDiskUsage(
  SshWorkspaceController controller, {
  required String path,
  RemoteOsKind? osHint,
  int maxEntries = 60,
}) async {
  if (!controller.connected) return null;
  final p = path.trim().isEmpty ? '/' : path.trim();
  if (!isSafeDiskUsagePath(p)) {
    return RemoteDiskUsageSnapshot(
      os: osHint ?? RemoteOsKind.unknown,
      path: p,
      entries: const [],
      error: '非法路径',
    );
  }
  final os = osHint ?? await detectRemoteOs(controller);
  final n = maxEntries.clamp(10, 200);
  switch (os) {
    case RemoteOsKind.linux:
      return _fetchLinux(controller, p, n);
    case RemoteOsKind.windows:
      return _fetchWindows(controller, p, n);
    case RemoteOsKind.unknown:
      final linux = await _fetchLinux(controller, p, n);
      if (linux.entries.isNotEmpty || linux.error == null) return linux;
      return _fetchWindows(controller, p, n);
  }
}

Future<RemoteDiskUsageSnapshot> _fetchLinux(
  SshWorkspaceController controller,
  String path,
  int maxEntries,
) async {
  final q = _shellSingleQuote(path);
  // -B1 字节；-d 1 仅一层；失败时退回不带 -x
  final cmd =
      '(du -x -B1 -d 1 $q 2>/dev/null || du -B1 -d 1 $q 2>/dev/null) | sort -nr | head -n $maxEntries';
  final raw = await controller.runRemoteForStatus(cmd);
  if (raw == null || raw.trim().isEmpty) {
    return RemoteDiskUsageSnapshot(
      os: RemoteOsKind.linux,
      path: path,
      entries: const [],
      error: '无法执行 du（权限不足或路径不存在）',
    );
  }
  return parseLinuxDu(raw, path: path);
}

Future<RemoteDiskUsageSnapshot> _fetchWindows(
  SshWorkspaceController controller,
  String path,
  int maxEntries,
) async {
  final escaped = path.replaceAll("'", "''");
  final cmd =
      '''powershell -NoProfile -NonInteractive -Command "\$ErrorActionPreference='SilentlyContinue'; \$root='$escaped'; if(-not (Test-Path -LiteralPath \$root)){ Write-Output '__ET_DU_ERR__ path not found'; exit }; Get-ChildItem -LiteralPath \$root -Force | ForEach-Object { \$b=0; if(\$_.PSIsContainer){ \$b=(Get-ChildItem -LiteralPath \$_.FullName -Recurse -Force -File | Measure-Object -Property Length -Sum).Sum; if(-not \$b){\$b=0} } else { \$b=\$_.Length }; Write-Output ([string]\$b + '|' + \$_.Name) } | Sort-Object { [int64](\$_ -split '\\|')[0] } -Descending | Select-Object -First $maxEntries"''';
  final raw = await controller.runRemoteForStatus(cmd);
  if (raw == null || raw.trim().isEmpty) {
    return RemoteDiskUsageSnapshot(
      os: RemoteOsKind.windows,
      path: path,
      entries: const [],
      error: '无法统计目录占用',
    );
  }
  return parseWindowsDu(raw, path: path);
}

/// `bytes\\tpath` 或 `bytes path`（du 默认）。
RemoteDiskUsageSnapshot parseLinuxDu(String raw, {required String path}) {
  if (raw.contains('__ET_DU_ERR__')) {
    return RemoteDiskUsageSnapshot(
      os: RemoteOsKind.linux,
      path: path,
      entries: const [],
      error: '无法统计',
    );
  }
  final entries = <RemoteDiskUsageEntry>[];
  final normRoot = path.replaceAll(RegExp(r'/+$'), '');
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final m = RegExp(r'^(\d+)\s+(.+)$').firstMatch(t);
    if (m == null) continue;
    final bytes = int.tryParse(m.group(1)!);
    if (bytes == null || bytes < 0) continue;
    var name = m.group(2)!.trim();
    final isTotal = name == path ||
        name == '$path/' ||
        name.replaceAll(RegExp(r'/+$'), '') == normRoot ||
        name == '.';
    if (!isTotal) {
      // 显示相对名
      if (name.startsWith('$normRoot/')) {
        name = name.substring(normRoot.length + 1);
      } else if (name.contains('/')) {
        name = name.split('/').last;
      }
    }
    entries.add(
      RemoteDiskUsageEntry(
        name: isTotal ? path : name,
        bytes: bytes,
        isTotal: isTotal,
      ),
    );
  }
  entries.sort((a, b) {
    if (a.isTotal != b.isTotal) return a.isTotal ? 1 : -1;
    return b.bytes.compareTo(a.bytes);
  });
  return RemoteDiskUsageSnapshot(
    os: RemoteOsKind.linux,
    path: path,
    entries: entries,
  );
}

/// `bytes|name`
RemoteDiskUsageSnapshot parseWindowsDu(String raw, {required String path}) {
  if (raw.contains('__ET_DU_ERR__')) {
    final msg = raw.split('__ET_DU_ERR__').last.trim();
    return RemoteDiskUsageSnapshot(
      os: RemoteOsKind.windows,
      path: path,
      entries: const [],
      error: msg.isEmpty ? '路径不存在' : msg,
    );
  }
  final entries = <RemoteDiskUsageEntry>[];
  var sum = 0;
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('__')) continue;
    final parts = t.split('|');
    if (parts.length < 2) continue;
    final bytes = int.tryParse(parts[0].trim());
    final name = parts.sublist(1).join('|').trim();
    if (bytes == null || bytes < 0 || name.isEmpty) continue;
    sum += bytes;
    entries.add(RemoteDiskUsageEntry(name: name, bytes: bytes));
  }
  entries.sort((a, b) => b.bytes.compareTo(a.bytes));
  if (entries.isNotEmpty) {
    entries.add(
      RemoteDiskUsageEntry(name: path, bytes: sum, isTotal: true),
    );
  }
  return RemoteDiskUsageSnapshot(
    os: RemoteOsKind.windows,
    path: path,
    entries: entries,
  );
}

String formatUsageBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / 1024;
  if (gb < 1024) return '${gb.toStringAsFixed(2)} GB';
  return '${(gb / 1024).toStringAsFixed(2)} TB';
}
