/// 上传过程中按文件粒度回调（用于侧栏任务列表）。
class SftpUploadProgressHooks {
  const SftpUploadProgressHooks({
    this.onFileStart,
    this.onFileProgress,
    this.onFileEnd,
  });

  final void Function(String localFilePath, String displayLabel, int totalBytes)? onFileStart;
  final void Function(String localFilePath, int uploadedBytes, int totalBytes)? onFileProgress;
  final void Function(String localFilePath, Object? error)? onFileEnd;
}
