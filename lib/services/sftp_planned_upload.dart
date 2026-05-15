/// 单次本地上传计划中的一项（一个实际文件）。
class SftpPlannedUploadFile {
  const SftpPlannedUploadFile({
    required this.localPath,
    required this.displayLabel,
    required this.remoteParentDir,
    required this.sizeBytes,
  });

  final String localPath;
  final String displayLabel;

  /// 远程文件所在父目录的绝对路径（以 `/` 开头）。
  final String remoteParentDir;
  final int sizeBytes;
}

/// 与远端同名冲突时的分类（在支持 dart:io 的平台由 SFTP 探测）。
enum SftpRemoteUploadConflict {
  /// 远端不存在同名路径，可直接上传。
  none,

  /// 远端已有同名文件/目录，且与本地类型一致，覆盖即替换远端该项。
  existsReplaceable,

  /// 远端为文件而本地为目录，或相反，无法直接覆盖。
  typeMismatch,
}
