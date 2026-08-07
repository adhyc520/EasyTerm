/// 远端文件管理器内的复制 / 剪切剪贴板（按会话共享，跨文件管理器窗口可用）。
class SftpRemoteClipboard {
  const SftpRemoteClipboard({
    required this.sourceCwd,
    required this.names,
    required this.isCut,
  });

  final String sourceCwd;
  final List<String> names;
  final bool isCut;
}
