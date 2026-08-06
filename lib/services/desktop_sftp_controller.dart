import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../util/remote_paths.dart';
import 'sftp_browser_host.dart';
import 'sftp_fs_transfer.dart' as sftp_transfer;
import 'sftp_planned_upload.dart';
import 'sftp_remote_copy.dart' as sftp_copy;
import 'sftp_upload_progress_hooks.dart';
import 'sftp_upload_task_list.dart';
import 'ssh_workspace_controller.dart';

/// 桌面文件管理器窗口专用：共享父会话的 [SftpClient] 与传输队列，独立 cwd / entries。
class DesktopSftpController extends ChangeNotifier implements SftpBrowserHost {
  DesktopSftpController(this._workspace, {String? initialCwd}) {
    _remoteCwd = initialCwd ?? _workspace.remoteCwd;
    _wasConnected = _workspace.connected && !_workspace.dropped;
    _workspace.addListener(_onWorkspace);
  }

  final SshWorkspaceController _workspace;
  bool _wasConnected = false;

  /// 底层会话（拖出/临时文件登记等仍走工作区静态与实例方法）。
  SshWorkspaceController get workspace => _workspace;

  String _remoteCwd = '/';
  List<SftpName> _entries = [];
  bool _loadingDir = false;

  /// 与主会话共用，便于桌面「传输」面板统一展示。
  @override
  SftpUploadTaskList get uploadTasks => _workspace.uploadTasks;

  @override
  SftpClient? get sftp => _workspace.sftp;

  @override
  String get remoteCwd => _remoteCwd;

  @override
  List<SftpName> get entries => List.unmodifiable(_entries);

  @override
  bool get loadingDir => _loadingDir;

  void _onWorkspace() {
    final nowConnected = _workspace.connected && !_workspace.dropped;
    if (!nowConnected) {
      _wasConnected = false;
      if (_entries.isNotEmpty) {
        _entries = [];
        notifyListeners();
      } else {
        notifyListeners();
      }
      return;
    }
    // 重连成功：强制刷新当前目录（SFTP 客户端已重建）。
    if (!_wasConnected) {
      _wasConnected = true;
      unawaited(refreshDirectory());
      notifyListeners();
      return;
    }
    if (sftp != null && _entries.isEmpty && !_loadingDir) {
      unawaited(refreshDirectory());
    }
    notifyListeners();
  }

  Future<void> bindInitial() async {
    if (sftp != null) await refreshDirectory();
  }

  @override
  Future<void> refreshDirectory() async {
    final client = sftp;
    if (client == null) return;
    // 已有列表时静默刷新，避免整页 loading；仅首次/切目录后才转圈。
    final showLoading = _entries.isEmpty;
    if (showLoading) {
      _loadingDir = true;
      notifyListeners();
    }
    try {
      final list = await client.listdir(_remoteCwd);
      list.sort((a, b) {
        if (a.attr.isDirectory != b.attr.isDirectory) {
          return a.attr.isDirectory ? -1 : 1;
        }
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      final next = list
          .where((e) => e.filename != '.' && e.filename != '..')
          .toList();
      if (!_sameDirectoryEntries(_entries, next)) {
        _entries = next;
        if (!showLoading) notifyListeners();
      }
    } catch (e) {
      debugPrint('DesktopSftpController.refreshDirectory: $e');
    } finally {
      if (showLoading) {
        _loadingDir = false;
        notifyListeners();
      }
    }
  }

  /// 切到新路径：清空当前项，让 UI 走 loading，避免短暂显示旧目录内容。
  void _beginNavigate(String path) {
    _remoteCwd = path;
    _entries = [];
  }

  static bool _sameDirectoryEntries(List<SftpName> a, List<SftpName> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.filename != y.filename) return false;
      if (x.attr.isDirectory != y.attr.isDirectory) return false;
      if (x.attr.size != y.attr.size) return false;
      if (x.attr.modifyTime != y.attr.modifyTime) return false;
    }
    return true;
  }

  @override
  Future<void> navigateInto(String name) async {
    final path = remoteJoin(_remoteCwd, name);
    final client = sftp;
    if (client == null) return;
    try {
      final attrs = await client.stat(path);
      if (attrs.isDirectory) {
        _beginNavigate(path);
        await refreshDirectory();
      }
    } catch (e) {
      debugPrint('DesktopSftpController.navigateInto: $e');
      notifyListeners();
    }
  }

  @override
  Future<void> navigateToAbsolutePath(String absolutePath) async {
    final client = sftp;
    if (client == null) return;
    var path = absolutePath.replaceAll('\\', '/');
    if (path.isEmpty) return;
    if (path != '/' && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (!path.startsWith('/')) return;
    try {
      final attrs = await client.stat(path);
      if (!attrs.isDirectory) return;
      if (path == _remoteCwd) {
        await refreshDirectory();
        return;
      }
      _beginNavigate(path);
      await refreshDirectory();
    } catch (e) {
      debugPrint('DesktopSftpController.navigateToAbsolutePath: $e');
      notifyListeners();
    }
  }

  @override
  Future<Uint8List?> readRemoteFile(String relativeName) async {
    final client = sftp;
    if (client == null) return null;
    final path = remoteJoin(_remoteCwd, relativeName);
    final file = await client.open(path, mode: SftpFileOpenMode.read);
    try {
      final stat = await file.stat();
      final size = stat.size ?? 0;
      if (size > kMaxEditorBytes) {
        throw StateError('文件过大（$size 字节），上限为 $kMaxEditorBytes 字节');
      }
      return await file.readBytes();
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> writeRemoteFile(String relativeName, Uint8List bytes) async {
    final client = sftp;
    if (client == null) return;
    final path = remoteJoin(_remoteCwd, relativeName);
    final file = await client.open(
      path,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(bytes);
    } finally {
      await file.close();
    }
    await refreshDirectory();
  }

  @override
  Future<int?> remoteMtime(String relativeName) async {
    final client = sftp;
    if (client == null) return null;
    final path = remoteJoin(_remoteCwd, relativeName);
    final attrs = await client.stat(path);
    return attrs.modifyTime;
  }

  @override
  Future<void> deleteRemote(String name) async {
    final client = sftp;
    if (client == null) return;
    final path = remoteJoin(_remoteCwd, name);
    try {
      await sftp_transfer.removeRemotePathRecursive(
        sftp: client,
        remotePath: path,
      );
    } catch (e) {
      debugPrint('DesktopSftpController.deleteRemote: $e');
    }
    await refreshDirectory();
  }

  @override
  Future<void> createRemoteDirectory(String name) async {
    final client = sftp;
    if (client == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.contains('/') || trimmed.contains('\\')) {
      throw ArgumentError('invalid directory name');
    }
    final path = remoteJoin(_remoteCwd, trimmed);
    await client.mkdir(path);
    await refreshDirectory();
  }

  @override
  Future<void> createRemoteFile(String name) async {
    final client = sftp;
    if (client == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.contains('/') || trimmed.contains('\\')) {
      throw ArgumentError('invalid file name');
    }
    final path = remoteJoin(_remoteCwd, trimmed);
    final file = await client.open(
      path,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.exclusive,
    );
    await file.close();
    await refreshDirectory();
  }

  @override
  Future<void> renameRemote(String oldName, String newName) async {
    final client = sftp;
    if (client == null) return;
    final next = newName.trim();
    if (next.isEmpty || next.contains('/') || next.contains('\\')) {
      throw ArgumentError('invalid name');
    }
    if (next == oldName) return;
    final from = remoteJoin(_remoteCwd, oldName);
    final to = remoteJoin(_remoteCwd, next);
    await client.rename(from, to);
    await refreshDirectory();
  }

  @override
  Future<List<String>> copyRemoteNamesFrom({
    required String fromCwd,
    required List<String> names,
  }) async {
    final client = sftp;
    if (client == null) return const [];
    try {
      final pasted = await sftp_copy.sftpCopyRemoteNames(
        client: client,
        fromCwd: fromCwd,
        toCwd: _remoteCwd,
        names: names,
      );
      await refreshDirectory();
      return pasted;
    } on sftp_copy.SftpRemotePastePartialFailure {
      await refreshDirectory();
      rethrow;
    }
  }

  @override
  Future<List<String>> moveRemoteNamesFrom({
    required String fromCwd,
    required List<String> names,
  }) async {
    final client = sftp;
    if (client == null) return const [];
    try {
      final pasted = await sftp_copy.sftpMoveRemoteNames(
        client: client,
        fromCwd: fromCwd,
        toCwd: _remoteCwd,
        names: names,
      );
      await refreshDirectory();
      return pasted;
    } on sftp_copy.SftpRemotePastePartialFailure {
      await refreshDirectory();
      rethrow;
    }
  }

  SftpUploadProgressHooks _hooks() {
    return SftpUploadProgressHooks(
      shouldCancelUpload: uploadTasks.isCancellationRequested,
      onFileStart: (path, label, total) => uploadTasks.setUploading(path),
      onFileProgress: (path, up, _) => uploadTasks.progress(path, up),
      onFileEnd: (path, err) {
        if (err is SftpUserCancelled) {
          uploadTasks.removeCancelled(path);
          return;
        }
        if (err != null) {
          uploadTasks.fail(path, err);
        } else {
          uploadTasks.succeed(path);
        }
      },
    );
  }

  void _failRemaining(Set<String> taskIds, Object error) {
    for (final row in List<SftpUploadTaskView>.of(uploadTasks.items)) {
      if (taskIds.contains(row.id) && row.state != SftpUploadRowState.failed) {
        uploadTasks.fail(row.id, error);
      }
    }
  }

  @override
  Future<void> downloadRemoteFileToLocalPath(
    String relativeName,
    String localFilePath,
  ) async {
    final client = sftp;
    if (client == null) return;
    final remotePath = remoteJoin(_remoteCwd, relativeName);
    final plan = await sftp_transfer.planDownloadSingleFile(
      sftp: client,
      remotePath: remotePath,
      localPath: localFilePath,
      displayLabel: relativeName,
    );
    final taskIds = plan.map((e) => e.taskId).toSet();
    uploadTasks.appendTasks(
      plan
          .map(
            (e) => SftpUploadTaskView(
              id: e.taskId,
              label: e.displayLabel,
              totalBytes: e.sizeBytes,
              direction: SftpTransferDirection.download,
            ),
          )
          .toList(),
    );
    try {
      await sftp_transfer.executeDownloadPlan(
        sftp: client,
        plan: plan,
        hooks: _hooks(),
      );
    } catch (e) {
      _failRemaining(taskIds, e);
    }
  }

  @override
  Future<void> downloadRemoteDirectoryToLocal(
    String relativeDirName,
    String localParentPath,
  ) async {
    final client = sftp;
    if (client == null) return;
    final remotePath = remoteJoin(_remoteCwd, relativeDirName);
    final localDest = p.join(localParentPath, relativeDirName);
    await sftp_transfer.ensureLocalDirectoryExists(localDest);
    final taskIds = <String>{};
    try {
      final plan = await sftp_transfer.planRemoteDirectoryDownload(
        sftp: client,
        remoteTreeRoot: remotePath,
        localTreeRoot: localDest,
        displayRootLabel: relativeDirName,
        onEntryDiscovered: (entry) {
          taskIds.add(entry.taskId);
          uploadTasks.appendTasks([
            SftpUploadTaskView(
              id: entry.taskId,
              label: entry.displayLabel,
              totalBytes: entry.sizeBytes,
              direction: SftpTransferDirection.download,
            ),
          ]);
        },
      );
      await sftp_transfer.executeDownloadPlan(
        sftp: client,
        plan: plan,
        hooks: _hooks(),
      );
    } catch (e) {
      debugPrint('DesktopSftpController.downloadRemoteDirectoryToLocal: $e');
      _failRemaining(taskIds, e);
    }
  }

  @override
  Future<SftpRemoteUploadConflict> inspectLocalUploadConflict(
    String localPath,
  ) async {
    final client = sftp;
    if (client == null) return SftpRemoteUploadConflict.none;
    return sftp_transfer.inspectUploadConflict(
      sftp: client,
      remoteCwd: _remoteCwd,
      localPath: localPath,
    );
  }

  @override
  Future<void> removeRemoteSubtreeForOverwrite(String relativeName) async {
    final client = sftp;
    if (client == null) return;
    final path = remoteJoin(_remoteCwd, relativeName);
    await sftp_transfer.removeRemotePathRecursive(
      sftp: client,
      remotePath: path,
    );
    await refreshDirectory();
  }

  @override
  Future<void> uploadMultipleLocalPaths(List<String> localPaths) async {
    final client = sftp;
    if (client == null) return;
    final allPlans = <(String localPath, List<SftpPlannedUploadFile> plan)>[];
    final allTaskIds = <String>{};
    for (final lp in localPaths) {
      final plan = await sftp_transfer.planLocalUpload(
        remoteCwd: _remoteCwd,
        localPath: lp,
      );
      allPlans.add((lp, plan));
      allTaskIds.addAll(plan.map((e) => e.localPath));
    }
    final taskViews = <SftpUploadTaskView>[];
    for (final (_, plan) in allPlans) {
      for (final e in plan) {
        taskViews.add(
          SftpUploadTaskView(
            id: e.localPath,
            label: e.displayLabel,
            totalBytes: e.sizeBytes,
            direction: SftpTransferDirection.upload,
          ),
        );
      }
    }
    if (taskViews.isNotEmpty) {
      uploadTasks.appendTasks(taskViews);
    }
    for (final (localPath, plan) in allPlans) {
      try {
        await sftp_transfer.uploadPlannedFiles(
          sftp: client,
          remoteCwd: _remoteCwd,
          localPath: localPath,
          plan: plan,
          hooks: _hooks(),
        );
      } catch (e) {
        _failRemaining(allTaskIds, e);
      }
    }
    await refreshDirectory();
  }

  @override
  void dispose() {
    _workspace.removeListener(_onWorkspace);
    super.dispose();
  }
}
