import 'dart:async';

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
    _seenRemoteFsEpoch = _workspace.remoteFsEpoch;
    _workspace.addListener(_onWorkspace);
  }

  final SshWorkspaceController _workspace;
  bool _wasConnected = false;
  int _seenRemoteFsEpoch = 0;
  String _lastFollowedTerminalCwd = '';
  DateTime? _lastManualNavAt;
  Timer? _followDebounce;
  String? _pendingFollowTarget;

  /// 底层会话（拖出/临时文件登记等仍走工作区静态与实例方法）。
  SshWorkspaceController get workspace => _workspace;

  String _remoteCwd = '/';
  List<SftpName> _entries = [];
  bool _loadingDir = false;
  String? _loadError;
  bool _showHidden = false;
  SftpSortColumn _sortColumn = SftpSortColumn.name;
  bool _sortAscending = true;
  final List<String> _historyBack = [];
  final List<String> _historyForward = [];

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

  @override
  String? get loadError => _loadError;

  @override
  bool get showHidden => _showHidden;

  @override
  set showHidden(bool value) {
    if (_showHidden == value) return;
    _showHidden = value;
    unawaited(refreshDirectory());
  }

  @override
  SftpSortColumn get sortColumn => _sortColumn;

  @override
  bool get sortAscending => _sortAscending;

  @override
  void setSort(SftpSortColumn col) {
    if (_sortColumn == col) {
      _sortAscending = !_sortAscending;
    } else {
      _sortColumn = col;
      _sortAscending = true;
    }
    if (_entries.isNotEmpty) {
      final next = List<SftpName>.of(_entries);
      sortSftpEntries(
        next,
        column: _sortColumn,
        ascending: _sortAscending,
      );
      _entries = next;
    }
    notifyListeners();
  }

  @override
  bool get canGoBack => _historyBack.isNotEmpty;

  @override
  bool get canGoForward => _historyForward.isNotEmpty;

  @override
  bool get canGoUp => _remoteCwd.isNotEmpty && _remoteCwd != '/';

  void _onWorkspace() {
    final nowConnected = _workspace.connected && !_workspace.dropped;
    if (!nowConnected) {
      _wasConnected = false;
      _seenRemoteFsEpoch = _workspace.remoteFsEpoch;
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
      _seenRemoteFsEpoch = _workspace.remoteFsEpoch;
      unawaited(refreshDirectory());
      notifyListeners();
      return;
    }
    final epoch = _workspace.remoteFsEpoch;
    if (epoch != _seenRemoteFsEpoch) {
      _seenRemoteFsEpoch = epoch;
      unawaited(refreshDirectory());
    }
    if (sftp != null && _entries.isEmpty && !_loadingDir) {
      unawaited(refreshDirectory());
    }
    _maybeFollowTerminalCwd();
    notifyListeners();
  }

  void _markManualNav() {
    _lastManualNavAt = DateTime.now();
  }

  void _maybeFollowTerminalCwd() {
    if (!_workspace.settings.followTerminalCwd) return;
    final target = _workspace.terminalCwd;
    if (target.isEmpty || target == _lastFollowedTerminalCwd) return;
    if (normalizeRemotePathForCompare(target) ==
        normalizeRemotePathForCompare(_remoteCwd)) {
      _lastFollowedTerminalCwd = target;
      return;
    }
    final at = _lastManualNavAt;
    if (at != null &&
        DateTime.now().difference(at) < const Duration(milliseconds: 1500)) {
      return;
    }
    _pendingFollowTarget = target;
    _followDebounce?.cancel();
    _followDebounce = Timer(const Duration(milliseconds: 400), () {
      _followDebounce = null;
      final path = _pendingFollowTarget;
      _pendingFollowTarget = null;
      if (path == null) return;
      if (!_workspace.settings.followTerminalCwd) return;
      if (path == _lastFollowedTerminalCwd) return;
      if (normalizeRemotePathForCompare(path) ==
          normalizeRemotePathForCompare(_remoteCwd)) {
        _lastFollowedTerminalCwd = path;
        return;
      }
      final manualAt = _lastManualNavAt;
      if (manualAt != null &&
          DateTime.now().difference(manualAt) <
              const Duration(milliseconds: 1500)) {
        return;
      }
      _lastFollowedTerminalCwd = path;
      unawaited(_navigateFollowing(path));
    });
  }

  Future<void> _navigateFollowing(String absolutePath) async {
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
      _beginNavigate(path, manual: false);
      await refreshDirectory();
    } catch (e) {
      debugPrint('DesktopSftpController._navigateFollowing: $e');
    }
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
      final next = list.where((e) {
        if (e.filename == '.' || e.filename == '..') return false;
        if (!_showHidden && e.filename.startsWith('.')) return false;
        return true;
      }).toList();
      sortSftpEntries(
        next,
        column: _sortColumn,
        ascending: _sortAscending,
      );
      final clearedError = _loadError != null;
      _loadError = null;
      if (!_sameDirectoryEntries(_entries, next)) {
        _entries = next;
        if (!showLoading) notifyListeners();
      } else if (clearedError) {
        if (!showLoading) notifyListeners();
      }
    } catch (e) {
      debugPrint('DesktopSftpController.refreshDirectory: $e');
      _loadError = '$e';
      if (!showLoading) notifyListeners();
    } finally {
      if (showLoading) {
        _loadingDir = false;
        notifyListeners();
      }
    }
  }

  /// 切到新路径：清空当前项，让 UI 走 loading，避免短暂显示旧目录内容。
  void _beginNavigate(
    String path, {
    bool pushHistory = true,
    bool manual = true,
  }) {
    if (manual) _markManualNav();
    if (pushHistory && path != _remoteCwd) {
      _historyBack.add(_remoteCwd);
      if (_historyBack.length > 64) _historyBack.removeAt(0);
      // 标准浏览器行为：从历史中点开新路径时丢弃前进栈。
      _historyForward.clear();
    }
    _remoteCwd = path;
    _entries = [];
    _loadError = null;
  }

  @override
  Future<void> goBack() async {
    if (_historyBack.isEmpty) return;
    _historyForward.add(_remoteCwd);
    if (_historyForward.length > 64) _historyForward.removeAt(0);
    final prev = _historyBack.removeLast();
    _beginNavigate(prev, pushHistory: false);
    await refreshDirectory();
  }

  @override
  Future<void> goForward() async {
    if (_historyForward.isEmpty) return;
    _historyBack.add(_remoteCwd);
    if (_historyBack.length > 64) _historyBack.removeAt(0);
    final next = _historyForward.removeLast();
    _beginNavigate(next, pushHistory: false);
    await refreshDirectory();
  }

  @override
  Future<void> navigateUp() async {
    final parent = remoteDirname(_remoteCwd);
    if (parent == _remoteCwd) return;
    _beginNavigate(parent);
    await refreshDirectory();
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
      _loadError = '$e';
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
      _loadError = '$e';
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
    String? toCwd,
  }) async {
    final client = sftp;
    if (client == null) return const [];
    final dest = toCwd ?? _remoteCwd;
    try {
      final pasted = await sftp_copy.sftpCopyRemoteNames(
        client: client,
        fromCwd: fromCwd,
        toCwd: dest,
        names: names,
      );
      _workspace.notifyRemoteFsChanged();
      await refreshDirectory();
      return pasted;
    } on sftp_copy.SftpRemotePastePartialFailure {
      _workspace.notifyRemoteFsChanged();
      await refreshDirectory();
      rethrow;
    }
  }

  @override
  Future<List<String>> moveRemoteNamesFrom({
    required String fromCwd,
    required List<String> names,
    String? toCwd,
  }) async {
    final client = sftp;
    if (client == null) return const [];
    final dest = toCwd ?? _remoteCwd;
    try {
      final pasted = await sftp_copy.sftpMoveRemoteNames(
        client: client,
        fromCwd: fromCwd,
        toCwd: dest,
        names: names,
      );
      _workspace.clearRemoteClipboardAfterMove(
        fromCwd: fromCwd,
        names: names,
      );
      _workspace.notifyRemoteFsChanged();
      await refreshDirectory();
      return pasted;
    } on sftp_copy.SftpRemotePastePartialFailure catch (e) {
      if (e.pasted.isNotEmpty) {
        _workspace.clearRemoteClipboardAfterMove(
          fromCwd: fromCwd,
          names: e.pasted,
        );
      }
      _workspace.notifyRemoteFsChanged();
      await refreshDirectory();
      rethrow;
    }
  }

  SftpUploadProgressHooks _hooks() {
    return SftpUploadProgressHooks(
      shouldCancelUpload: uploadTasks.isCancellationRequested,
      shouldPauseUpload: uploadTasks.isPauseRequested,
      preferredUploadOrder: uploadTasks.preferredUploadOrder,
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
              localPath: e.localPath,
              remotePath: e.remotePath,
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
              localPath: entry.localPath,
              remotePath: entry.remotePath,
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
            localPath: e.localPath,
            remotePath: remoteJoin(
              e.remoteParentDir,
              p.basename(e.localPath),
            ),
            remoteCwd: _remoteCwd,
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
    _followDebounce?.cancel();
    _followDebounce = null;
    _pendingFollowTarget = null;
    _workspace.removeListener(_onWorkspace);
    super.dispose();
  }
}
