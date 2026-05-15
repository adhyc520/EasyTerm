import 'package:dartssh2/dartssh2.dart';

import 'sftp_planned_download.dart';
import 'sftp_planned_upload.dart';
import 'sftp_upload_progress_hooks.dart';

Future<void> uploadLocalPathToRemote({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
  SftpUploadProgressHooks? hooks,
}) async {
  throw UnsupportedError('本地文件上传仅在支持 dart:io 的桌面端可用');
}

Future<void> uploadPlannedFiles({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
  required List<SftpPlannedUploadFile> plan,
  SftpUploadProgressHooks? hooks,
}) async {
  throw UnsupportedError('本地文件上传仅在支持 dart:io 的桌面端可用');
}

Future<SftpRemoteUploadConflict> inspectUploadConflict({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
}) async {
  throw UnsupportedError('本地文件上传仅在支持 dart:io 的桌面端可用');
}

Future<void> removeRemotePathRecursive({
  required SftpClient sftp,
  required String remotePath,
}) async {
  throw UnsupportedError('本地文件上传仅在支持 dart:io 的桌面端可用');
}

Future<List<SftpPlannedUploadFile>> planLocalUpload({
  required String remoteCwd,
  required String localPath,
}) async {
  throw UnsupportedError('本地文件上传仅在支持 dart:io 的桌面端可用');
}

Future<List<SftpPlannedDownloadFile>> planDownloadSingleFile({
  required SftpClient sftp,
  required String remotePath,
  required String localPath,
  required String displayLabel,
}) async {
  throw UnsupportedError('本地文件上传仅在支持 dart:io 的桌面端可用');
}

Future<List<SftpPlannedDownloadFile>> planRemoteDirectoryDownload({
  required SftpClient sftp,
  required String remoteTreeRoot,
  required String localTreeRoot,
  required String displayRootLabel,
}) async {
  throw UnsupportedError('本地文件上传仅在支持 dart:io 的桌面端可用');
}

Future<void> executeDownloadPlan({
  required SftpClient sftp,
  required List<SftpPlannedDownloadFile> plan,
  SftpUploadProgressHooks? hooks,
}) async {
  throw UnsupportedError('本地文件上传仅在支持 dart:io 的桌面端可用');
}

Future<void> saveRemoteFileToLocalPath({
  required SftpClient sftp,
  required String remoteCwd,
  required String relativeName,
  required String localFilePath,
}) async {
  throw UnsupportedError('保存到本地路径仅在支持 dart:io 的桌面端可用');
}

Future<void> downloadRemoteTreeToLocalPath({
  required SftpClient sftp,
  required String remotePath,
  required String localDirPath,
  bool Function()? shouldAbort,
}) async {
  throw UnsupportedError('目录下载到本地仅在支持 dart:io 的桌面端可用');
}

void deleteLocalFileQuiet(String localFilePath) {}
