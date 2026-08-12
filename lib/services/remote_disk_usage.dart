import 'remote_process_list.dart';
import 'remote_sudo.dart';
import 'remote_exec_capable.dart';

/// 目录占用失败原因（权限 vs 不存在）。
enum RemoteDiskUsageErrorKind {
  permission,
  notFound,
  other,
}

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
    this.errorKind,
  });

  final RemoteOsKind os;
  final String path;
  final List<RemoteDiskUsageEntry> entries;
  final String? error;
  final RemoteDiskUsageErrorKind? errorKind;

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
  if (path.contains('\u0000') || path.contains('\n') || path.contains('\r')) {
    return false;
  }
  // 禁止路径穿越段；其余字符由 shell 单引号转义保护。
  final parts = path.replaceAll('\\', '/').split('/');
  for (final p in parts) {
    if (p == '..') return false;
  }
  return true;
}

/// 从文案判断是否像权限不足。
bool looksLikeDiskUsagePermissionDenied(String? msg) {
  if (msg == null || msg.isEmpty) return false;
  final lower = msg.toLowerCase();
  return lower.contains('permission denied') ||
      lower.contains('access denied') ||
      lower.contains('operation not permitted') ||
      lower.contains('requires root') ||
      lower.contains('permission_denied') ||
      msg.contains('权限不足') ||
      msg.contains('权限被拒绝');
}

/// 从文案判断是否像路径不存在。
bool looksLikeDiskUsageNotFound(String? msg) {
  if (msg == null || msg.isEmpty) return false;
  final lower = msg.toLowerCase();
  return lower.contains('not_found') ||
      lower.contains('no such file') ||
      lower.contains('path not found') ||
      lower.contains('cannot find') ||
      lower.contains('does not exist') ||
      msg.contains('路径不存在') ||
      msg.contains('不存在');
}

RemoteDiskUsageErrorKind? classifyDiskUsageError(String? msg) {
  if (msg == null || msg.isEmpty) return null;
  if (RemoteSudo.isPasswordRequired(msg) || RemoteSudo.isAuthFailed(msg)) {
    return null;
  }
  if (looksLikeDiskUsageNotFound(msg)) {
    return RemoteDiskUsageErrorKind.notFound;
  }
  if (looksLikeDiskUsagePermissionDenied(msg)) {
    return RemoteDiskUsageErrorKind.permission;
  }
  return RemoteDiskUsageErrorKind.other;
}

String _shellSingleQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

String _linuxDuPipeline(
  String quotedPath,
  int maxEntries, {
  required bool oneFilesystem,
}) {
  if (oneFilesystem) {
    return '(du -x -B1 -d 1 $quotedPath 2>/dev/null || '
        'du -B1 -d 1 $quotedPath 2>/dev/null) | sort -nr | head -n $maxEntries';
  }
  return 'du -B1 -d 1 $quotedPath 2>/dev/null | sort -nr | head -n $maxEntries';
}

Future<RemoteDiskUsageSnapshot?> fetchRemoteDiskUsage(
  RemoteExecCapable controller, {
  required String path,
  RemoteOsKind? osHint,
  int maxEntries = 60,
  bool oneFilesystem = true,
  /// 为 true 时用 `sudo -n`（或 [sudoPassword] 时的 `sudo -S`）跑 du。
  bool useSudo = false,
  String? sudoPassword,
}) async {
  if (!controller.connected) return null;
  final p = path.trim().isEmpty ? '/' : path.trim();
  if (!isSafeDiskUsagePath(p)) {
    return RemoteDiskUsageSnapshot(
      os: osHint ?? RemoteOsKind.unknown,
      path: p,
      entries: const [],
      error: '非法路径',
      errorKind: RemoteDiskUsageErrorKind.other,
    );
  }
  final os = osHint ?? await detectRemoteOs(controller);
  final n = maxEntries.clamp(10, 200);
  switch (os) {
    case RemoteOsKind.linux:
      return _fetchLinux(
        controller,
        p,
        n,
        oneFilesystem: oneFilesystem,
        useSudo: useSudo,
        sudoPassword: sudoPassword,
      );
    case RemoteOsKind.windows:
      return _fetchWindows(controller, p, n);
    case RemoteOsKind.unknown:
      final linux = await _fetchLinux(
        controller,
        p,
        n,
        oneFilesystem: oneFilesystem,
        useSudo: useSudo,
        sudoPassword: sudoPassword,
      );
      if (linux.entries.isNotEmpty || linux.error == null) return linux;
      return _fetchWindows(controller, p, n);
  }
}

Future<RemoteDiskUsageSnapshot> _fetchLinux(
  RemoteExecCapable controller,
  String path,
  int maxEntries, {
  bool oneFilesystem = true,
  bool useSudo = false,
  String? sudoPassword,
}) async {
  final q = _shellSingleQuote(path);
  final pipeline = _linuxDuPipeline(
    q,
    maxEntries,
    oneFilesystem: oneFilesystem,
  );
  final usePwd = sudoPassword != null && sudoPassword.isNotEmpty;
  final wantSudo = useSudo || usePwd;

  late final String cmd;
  if (wantSudo) {
    var sudoCmd =
        'sudo -n sh -c ${_shellSingleQuote(pipeline)} 2>&1; echo __EC:\$?';
    if (usePwd) {
      sudoCmd = RemoteSudo.toStdinCommand(sudoCmd);
    }
    cmd = sudoCmd;
  } else {
    // 区分路径不存在 vs 不可读/不可进目录；再跑 du（子项权限问题仍吞 stderr）。
    cmd = 'if [ ! -e $q ]; then printf \'%s\\n\' \'__ET_DU_ERR__ not_found\'; '
        'elif { [ -d $q ] && [ ! -x $q ]; } || [ ! -r $q ]; then '
        'printf \'%s\\n\' \'__ET_DU_ERR__ permission_denied\'; '
        'else $pipeline; fi';
  }

  final raw = await controller.runQueued(
    cmd,
    timeout: const Duration(seconds: 60),
    stdinBytes: usePwd ? RemoteSudo.passwordStdin(sudoPassword) : null,
  );

  if (wantSudo) {
    final sudoErr = RemoteSudo.interpretExit(raw, usedPassword: usePwd);
    if (sudoErr != null) {
      final kind = classifyDiskUsageError(sudoErr) ??
          (RemoteSudo.isPasswordRequired(sudoErr) ||
                  RemoteSudo.isAuthFailed(sudoErr)
              ? null
              : RemoteDiskUsageErrorKind.permission);
      return RemoteDiskUsageSnapshot(
        os: RemoteOsKind.linux,
        path: path,
        entries: const [],
        error: sudoErr,
        errorKind: kind,
      );
    }
    final cleaned =
        (raw ?? '').replaceAll(RegExp(r'__EC:\d+\s*$'), '').trim();
    if (cleaned.isEmpty) {
      return RemoteDiskUsageSnapshot(
        os: RemoteOsKind.linux,
        path: path,
        entries: const [],
        error: '无法执行 du（权限不足或路径不存在）',
        errorKind: RemoteDiskUsageErrorKind.permission,
      );
    }
    return parseLinuxDu(cleaned, path: path);
  }

  if (raw == null || raw.trim().isEmpty) {
    return RemoteDiskUsageSnapshot(
      os: RemoteOsKind.linux,
      path: path,
      entries: const [],
      error: '无法执行 du（权限不足或路径不存在）',
      errorKind: RemoteDiskUsageErrorKind.other,
    );
  }
  return parseLinuxDu(raw, path: path);
}

Future<RemoteDiskUsageSnapshot> _fetchWindows(
  RemoteExecCapable controller,
  String path,
  int maxEntries,
) async {
  final escaped = path.replaceAll("'", "''");
  final cmd =
      '''powershell -NoProfile -NonInteractive -Command "\$ErrorActionPreference='SilentlyContinue'; \$root='$escaped'; if(-not (Test-Path -LiteralPath \$root)){ Write-Output '__ET_DU_ERR__ path not found'; exit }; Get-ChildItem -LiteralPath \$root -Force | ForEach-Object { \$b=0; if(\$_.PSIsContainer){ \$b=(Get-ChildItem -LiteralPath \$_.FullName -Recurse -Force -File | Measure-Object -Property Length -Sum).Sum; if(-not \$b){\$b=0} } else { \$b=\$_.Length }; Write-Output ([string]\$b + '|' + \$_.Name) } | Sort-Object { [int64](\$_ -split '\\|')[0] } -Descending | Select-Object -First $maxEntries"''';
  final raw = await controller.runQueued(
    cmd,
    timeout: const Duration(seconds: 60),
  );
  if (raw == null || raw.trim().isEmpty) {
    return RemoteDiskUsageSnapshot(
      os: RemoteOsKind.windows,
      path: path,
      entries: const [],
      error: '无法统计目录占用',
      errorKind: RemoteDiskUsageErrorKind.other,
    );
  }
  return parseWindowsDu(raw, path: path);
}

/// `bytes\\tpath` 或 `bytes path`（du 默认）。
RemoteDiskUsageSnapshot parseLinuxDu(String raw, {required String path}) {
  if (raw.contains('__ET_DU_ERR__')) {
    final tag = raw.split('__ET_DU_ERR__').last.trim();
    final kind = classifyDiskUsageError(tag) ??
        (tag.toLowerCase().contains('permission')
            ? RemoteDiskUsageErrorKind.permission
            : tag.toLowerCase().contains('not_found') ||
                    tag.toLowerCase().contains('not found')
                ? RemoteDiskUsageErrorKind.notFound
                : RemoteDiskUsageErrorKind.other);
    final message = switch (kind) {
      RemoteDiskUsageErrorKind.permission => '权限不足',
      RemoteDiskUsageErrorKind.notFound => '路径不存在',
      RemoteDiskUsageErrorKind.other =>
        tag.isEmpty ? '无法统计' : tag,
    };
    return RemoteDiskUsageSnapshot(
      os: RemoteOsKind.linux,
      path: path,
      entries: const [],
      error: message,
      errorKind: kind,
    );
  }
  if (looksLikeDiskUsagePermissionDenied(raw) &&
      !RegExp(r'^\d+\s+\S', multiLine: true).hasMatch(raw.trim())) {
    return RemoteDiskUsageSnapshot(
      os: RemoteOsKind.linux,
      path: path,
      entries: const [],
      error: '权限不足',
      errorKind: RemoteDiskUsageErrorKind.permission,
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
    final kind = classifyDiskUsageError(msg) ??
        RemoteDiskUsageErrorKind.notFound;
    return RemoteDiskUsageSnapshot(
      os: RemoteOsKind.windows,
      path: path,
      entries: const [],
      error: msg.isEmpty
          ? (kind == RemoteDiskUsageErrorKind.permission ? '权限不足' : '路径不存在')
          : msg,
      errorKind: kind,
    );
  }
  if (looksLikeDiskUsagePermissionDenied(raw) &&
      !raw.contains('|')) {
    return RemoteDiskUsageSnapshot(
      os: RemoteOsKind.windows,
      path: path,
      entries: const [],
      error: '权限不足',
      errorKind: RemoteDiskUsageErrorKind.permission,
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
