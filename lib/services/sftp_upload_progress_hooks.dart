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
    this.shouldPauseUpload,
    this.preferredUploadOrder,
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

  /// 在打开文件前、每个写入块边界调用；返回 `true` 则自旋等待直至恢复或取消。
  final bool Function(String localFilePath)? shouldPauseUpload;

  /// 返回当前期望的上传顺序（任务 id / localPath）。
  /// 执行器在每取下一项前按此顺序重排剩余 plan，使 UI「优先/拖拽」真正生效。
  final List<String> Function()? preferredUploadOrder;
}
