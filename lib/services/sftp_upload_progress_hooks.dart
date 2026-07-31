/// 用户在上传过程中取消该文件（非网络错误）。
class SftpUserCancelled {
  const SftpUserCancelled();
}

/// 上传过程中按文件粒度回调（用于侧栏任务列表）。
class SftpUploadProgressHooks {
  const SftpUploadProgressHooks({
    this.onFileStart,
    this.onFileProgress,
    this.onFileEnd,
    this.shouldCancelUpload,
  });

  final void Function(
    String localFilePath,
    String displayLabel,
    int totalBytes,
  )?
  onFileStart;
  final void Function(String localFilePath, int uploadedBytes, int totalBytes)?
  onFileProgress;
  final void Function(String localFilePath, Object? error)? onFileEnd;

  /// 在打开文件前、每个写入块之后调用；返回 `true` 则中止该文件上传。
  final bool Function(String localFilePath)? shouldCancelUpload;
}
