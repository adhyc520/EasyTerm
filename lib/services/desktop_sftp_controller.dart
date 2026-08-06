import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../util/remote_paths.dart';
import 'sftp_browser_host.dart';
import 'sftp_fs_transfer.dart' as sftp_transfer;
import 'sftp_planned_upload.dart';
import 'sftp_upload_progress_hooks.dart';
import 'sftp_upload_task_list.dart';
import 'ssh_workspace_controller.dart';

/// 桌面文件管理器窗口专用：共享父会话的 [SftpClient]，独立 cwd / entries / 上传队列。
class DesktopSftpController extends ChangeNotifier implements SftpBrowserHost {
  DesktopSftpController(this._workspace, {String? initialCwd}) {
    _remoteCwd = initialCwd ?? _workspace.remoteCwd;
    _workspace.addListener(_onWorkspace);
  }

  final SshWorkspaceController _workspace;

  /// 底层会话（拖出/临时文件登记等仍走工作区静态与实例方法）。
  SshWorkspaceController get workspace => _workspace;

  String _remoteCwd = '/';
  List<SftpName> _entries = [];
  bool _loadingDir = false;

  @override
  final SftpUploadTaskList uploadTasks = SftpUploadTaskList();

  @override
  SftpClient? get sftp => _workspace.sftp;

  @override
  String get remoteCwd => _remoteCwd;

  @override
  List<SftpName> get entries => List.unmodifiable(_entries);

  @override
  bool get loadingDir => _loadingDir;

  void _onWorkspace() {
    if (!_workspace.connected) {
      _entries = [];
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
    _loadingDir = true;
    notifyListeners();
    try {
      final list = await client.listdir(_remoteCwd);
      list.sort((a, b) {
        if (a.attr.isDirectory != b.attr.isDirectory) {
          return a.attr.isDirectory ? -1 : 1;
        }
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      _entries = list
          .where((e) => e.filename != '.' && e.filename != '..')
          .toList();
    } catch (e) {
      debugPrint('DesktopSftpController.refreshDirectory: $e');
    } finally {
      _loadingDir = false;
      notifyListeners();
    }
  }

  @override
  Future<void> navigateInto(String name) async {
    final path = remoteJoin(_remoteCwd, name);
    final client = sftp;
    if (client == null) return;
    try {
      final attrs = await client.stat(path);
      if (attrs.isDirectory) {
        _remoteCwd = path;
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
      _remoteCwd = path;
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
    uploadTasks.dispose();
    super.dispose();
  }
}
