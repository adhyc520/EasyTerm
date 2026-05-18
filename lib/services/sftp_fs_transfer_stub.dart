import 'package:dartssh2/dartssh2.dart';

import 'sftp_planned_download.dart';
import 'sftp_planned_upload.dart';
import 'sftp_upload_progress_hooks.dart';

const String _kDesktopOnlyMsg = '本地文件上传/下载仅在支持 dart:io 的桌面端可用';

Future<void> uploadLocalPathToRemote({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
  SftpUploadProgressHooks? hooks,
}) async {
  throw UnsupportedError(_kDesktopOnlyMsg);
}

Future<void> uploadPlannedFiles({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
  required List<SftpPlannedUploadFile> plan,
  SftpUploadProgressHooks? hooks,
}) async {
  throw UnsupportedError(_kDesktopOnlyMsg);
}

Future<SftpRemoteUploadConflict> inspectUploadConflict({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
}) async {
  throw UnsupportedError(_kDesktopOnlyMsg);
}

Future<void> removeRemotePathRecursive({
  required SftpClient sftp,
  required String remotePath,
}) async {
  throw UnsupportedError(_kDesktopOnlyMsg);
}

Future<List<SftpPlannedUploadFile>> planLocalUpload({
  required String remoteCwd,
  required String localPath,
}) async {
  throw UnsupportedError(_kDesktopOnlyMsg);
}

Future<List<SftpPlannedDownloadFile>> planDownloadSingleFile({
  required SftpClient sftp,
  required String remotePath,
  required String localPath,
  required String displayLabel,
}) async {
  throw UnsupportedError(_kDesktopOnlyMsg);
}

Future<List<SftpPlannedDownloadFile>> planRemoteDirectoryDownload({
  required SftpClient sftp,
  required String remoteTreeRoot,
  required String localTreeRoot,
  required String displayRootLabel,
  String? taskIdPrefix,
  bool Function()? shouldAbort,
  void Function(SftpPlannedDownloadFile entry)? onEntryDiscovered,
}) async {
  throw UnsupportedError(_kDesktopOnlyMsg);
}

Future<void> executeDownloadPlan({
  required SftpClient sftp,
  required List<SftpPlannedDownloadFile> plan,
  SftpUploadProgressHooks? hooks,
}) async {
  throw UnsupportedError(_kDesktopOnlyMsg);
}

Future<void> saveRemoteFileToLocalPath({
  required SftpClient sftp,
  required String remoteCwd,
  required String relativeName,
  required String localFilePath,
}) async {
  throw UnsupportedError(_kDesktopOnlyMsg);
}

void deleteLocalFileQuiet(String localFilePath) {}

void deleteLocalDirectoryQuiet(String localDirPath) {}

Future<void> ensureLocalDirectoryExists(String localDirPath) async {
  throw UnsupportedError(_kDesktopOnlyMsg);
}

bool localFileExistsSync(String path) => false;
