/// 单次远程下载计划中的一项（一个远程文件 → 本机路径）。
class SftpPlannedDownloadFile {
  const SftpPlannedDownloadFile({
    required this.taskId,
    required this.displayLabel,
    required this.remotePath,
    required this.localPath,
    required this.sizeBytes,
  });

  final String taskId;
  final String displayLabel;
  final String remotePath;
  final String localPath;
  final int sizeBytes;
}
