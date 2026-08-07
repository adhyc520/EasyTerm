import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'sftp_planned_upload.dart';
import 'sftp_upload_task_list.dart';

/// 列表排序列（目录始终优先，再按此列）。
enum SftpSortColumn { name, size, mtime }

/// 目录优先后按 [column]/[ascending] 排序（原地）。
void sortSftpEntries(
  List<SftpName> entries, {
  required SftpSortColumn column,
  required bool ascending,
}) {
  entries.sort((a, b) {
    if (a.attr.isDirectory != b.attr.isDirectory) {
      return a.attr.isDirectory ? -1 : 1;
    }
    final int cmp;
    switch (column) {
      case SftpSortColumn.name:
        cmp = a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      case SftpSortColumn.size:
        cmp = (a.attr.size ?? 0).compareTo(b.attr.size ?? 0);
      case SftpSortColumn.mtime:
        cmp = (a.attr.modifyTime ?? 0).compareTo(b.attr.modifyTime ?? 0);
    }
    return ascending ? cmp : -cmp;
  });
}

/// SFTP 浏览器对主机的依赖面：侧栏与桌面文件管理器共用。
abstract class SftpBrowserHost extends ChangeNotifier {
  SftpClient? get sftp;
  String get remoteCwd;
  List<SftpName> get entries;
  bool get loadingDir;
  /// 最近一次目录加载失败；成功刷新后应为 null。
  String? get loadError;
  SftpUploadTaskList get uploadTasks;

  /// 是否显示以 `.` 开头的隐藏项。
  bool get showHidden;
  set showHidden(bool value);

  SftpSortColumn get sortColumn;
  bool get sortAscending;
  /// 同列再点则切换升降序；换列则升序。
  void setSort(SftpSortColumn col);

  bool get canGoBack;
  bool get canGoForward;
  bool get canGoUp;
  Future<void> goBack();
  Future<void> goForward();
  Future<void> navigateUp();

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

  /// 将 [fromCwd] 下的 [names] 复制到 [toCwd]（默认当前 [remoteCwd]），返回粘贴后的新文件名。
  Future<List<String>> copyRemoteNamesFrom({
    required String fromCwd,
    required List<String> names,
    String? toCwd,
  });

  /// 将 [fromCwd] 下的 [names] 移动到 [toCwd]（默认当前 [remoteCwd]），返回粘贴后的新文件名。
  Future<List<String>> moveRemoteNamesFrom({
    required String fromCwd,
    required List<String> names,
    String? toCwd,
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
