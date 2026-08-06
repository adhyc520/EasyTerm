import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'sftp_planned_upload.dart';
import 'sftp_upload_task_list.dart';

/// SFTP 浏览器对主机的依赖面：侧栏与桌面文件管理器共用。
abstract class SftpBrowserHost extends ChangeNotifier {
  SftpClient? get sftp;
  String get remoteCwd;
  List<SftpName> get entries;
  bool get loadingDir;
  SftpUploadTaskList get uploadTasks;

  Future<void> refreshDirectory();
  Future<void> navigateInto(String name);
  Future<void> navigateToAbsolutePath(String path);
  Future<Uint8List?> readRemoteFile(String name);
  Future<void> writeRemoteFile(String name, Uint8List bytes);
  Future<int?> remoteMtime(String name);
  Future<void> deleteRemote(String name);
  Future<void> downloadRemoteFileToLocalPath(String name, String localPath);
  Future<void> downloadRemoteDirectoryToLocal(
    String name,
    String localParentPath,
  );
  Future<SftpRemoteUploadConflict> inspectLocalUploadConflict(String localPath);
  Future<void> removeRemoteSubtreeForOverwrite(String name);
  Future<void> uploadMultipleLocalPaths(List<String> paths);
}
