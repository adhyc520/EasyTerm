import '../services/remote_process_list.dart';

/// 构造在远端 shell 中切换工作目录的一行命令（不含尾部换行）。
///
/// - Linux / unknown：POSIX `cd '…'`
/// - Windows：PowerShell `Set-Location -LiteralPath '…'`（OpenSSH 常见默认壳；
///   亦兼容多数已把 `cd` 配成该 cmdlet 的环境）
String remoteShellCdCommand(String path, RemoteOsKind os) {
  final raw = path.trim();
  if (raw.isEmpty) return 'cd';
  switch (os) {
    case RemoteOsKind.windows:
      final lit = raw.replaceAll("'", "''");
      return "Set-Location -LiteralPath '$lit'";
    case RemoteOsKind.linux:
    case RemoteOsKind.unknown:
      return 'cd ${_posixShellQuote(raw)}';
  }
}

String _posixShellQuote(String value) =>
    "'${value.replaceAll("'", "'\\''")}'";
