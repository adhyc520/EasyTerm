import 'package:dartssh2/dartssh2.dart';

Future<void> uploadLocalPathToRemote({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
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
}) async {
  throw UnsupportedError('目录下载到本地仅在支持 dart:io 的桌面端可用');
}
