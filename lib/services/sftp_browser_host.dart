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
  Future<void> createRemoteDirectory(String name);
  /// 在当前目录创建空文件；若同名已存在则失败。
  Future<void> createRemoteFile(String name);
  Future<void> renameRemote(String oldName, String newName);

  /// 将 [fromCwd] 下的 [names] 复制到当前 [remoteCwd]，返回粘贴后的新文件名。
  Future<List<String>> copyRemoteNamesFrom({
    required String fromCwd,
    required List<String> names,
  });

  /// 将 [fromCwd] 下的 [names] 移动到当前 [remoteCwd]，返回粘贴后的新文件名。
  Future<List<String>> moveRemoteNamesFrom({
    required String fromCwd,
    required List<String> names,
  });

  Future<void> downloadRemoteFileToLocalPath(String name, String localPath);
  Future<void> downloadRemoteDirectoryToLocal(
    String name,
    String localParentPath,
  );
  Future<SftpRemoteUploadConflict> inspectLocalUploadConflict(String localPath);
  Future<void> removeRemoteSubtreeForOverwrite(String name);
  Future<void> uploadMultipleLocalPaths(List<String> paths);
}
