import 'dart:async';

import 'package:flutter/foundation.dart';

/// 传输方向（用于队列图标与语义）。
enum SftpTransferDirection { upload, download }

/// 列表中单行状态。
enum SftpUploadRowState {
  /// 尚未开始。
  pending,

  /// 正在进行（上传或下载）。
  uploading,

  /// 已失败，保留在列表中。
  failed,
}

/// 单个传输任务（每个文件一行；成功后从列表移除；失败保留）。
class SftpUploadTaskView {
  SftpUploadTaskView({
    required this.id,
    required this.label,
    required this.totalBytes,
    required this.direction,
    this.uploadedBytes = 0,
    this.error,
    this.state = SftpUploadRowState.pending,
    this.localPath,
    this.remotePath,
    this.remoteCwd,
  });

  final String id;
  final String label;
  final int totalBytes;
  final SftpTransferDirection direction;
  int uploadedBytes;
  Object? error;
  SftpUploadRowState state;

  /// 上传源路径，或下载目标本机路径（失败重试用）。
  final String? localPath;

  /// 远端文件绝对路径（失败重试用）。
  final String? remotePath;

  /// 入队时的远程工作目录（上传上下文；cwd 变更后仍按 [remotePath] 父目录重试）。
  final String? remoteCwd;

  /// 是否具备重试所需路径信息。
  bool get canRetry {
    if (state != SftpUploadRowState.failed) return false;
    if (direction == SftpTransferDirection.upload) {
      return localPath != null && localPath!.isNotEmpty;
    }
    return localPath != null &&
        localPath!.isNotEmpty &&
        remotePath != null &&
        remotePath!.isNotEmpty;
  }
}

/// 上传/下载队列展示用，与 [SshWorkspaceController] 并列。
class SftpUploadTaskList extends ChangeNotifier {
  final List<SftpUploadTaskView> _items = [];

  final Set<String> _cancelledIds = {};
  final Set<String> _pausedIds = {};

  int _batchTotal = 0;
  int _batchSucceeded = 0;

  List<SftpUploadTaskView> get items => List.unmodifiable(_items);

  /// 本批任务总数（随 [appendTasks] / 成功 / 取消 变化）。
  int get batchTotal => _batchTotal;

  /// 已成功完成并从列表移除的数量。
  int get batchSucceeded => _batchSucceeded;

  /// 是否存在排队中或传输中的任务（含已暂停）。
  bool get hasActive => _items.any(
        (t) =>
            t.state == SftpUploadRowState.pending ||
            t.state == SftpUploadRowState.uploading,
      );

  /// 是否有任务处于用户暂停（整表或逐行）。
  bool get hasPaused => _pausedIds.isNotEmpty;

  /// 是否全部进行中任务都已暂停（用于「全部继续」按钮可用性）。
  bool get allActivePaused {
    final active = _items.where(
      (t) =>
          t.state == SftpUploadRowState.pending ||
          t.state == SftpUploadRowState.uploading,
    );
    if (active.isEmpty) return false;
    return active.every((t) => _pausedIds.contains(t.id));
  }

  /// 失败行数量。
  int get failedCount =>
      _items.where((t) => t.state == SftpUploadRowState.failed).length;

  /// 进行中（pending + uploading）数量。
  int get activeCount => _items
      .where(
        (t) =>
            t.state == SftpUploadRowState.pending ||
            t.state == SftpUploadRowState.uploading,
      )
      .length;

  /// 已暂停的进行中任务数。
  int get pausedCount => _items
      .where(
        (t) =>
            (t.state == SftpUploadRowState.pending ||
                t.state == SftpUploadRowState.uploading) &&
            _pausedIds.contains(t.id),
      )
      .length;

  Timer? _debounce;
  var _dirty = false;
  var _disposed = false;

  /// 清空全部（含进行中）。调用方应优先 [clearFailed] / [clearFinished]。
  void clear() {
    _debounce?.cancel();
    _debounce = null;
    _dirty = false;
    _batchTotal = 0;
    _batchSucceeded = 0;
    _cancelledIds.clear();
    _pausedIds.clear();
    if (_items.isEmpty) return;
    _items.clear();
    if (!_disposed) notifyListeners();
  }

  /// 仅移除失败行；不触碰 pending/uploading。
  void clearFailed() {
    if (_disposed) return;
    final before = _items.length;
    _items.removeWhere((t) => t.state == SftpUploadRowState.failed);
    if (_items.length == before) return;
    if (!hasActive && _items.isEmpty) {
      _batchTotal = 0;
      _batchSucceeded = 0;
    }
    _notifyNow();
  }

  /// 移除失败（及任何已完成展示行）；有进行中任务时不清除 active。
  void clearFinished() {
    if (_disposed) return;
    clearFailed();
  }

  void _notifyNow() {
    _debounce?.cancel();
    _debounce = null;
    _dirty = false;
    if (!_disposed) notifyListeners();
  }

  void _scheduleDebounced() {
    _dirty = true;
    _debounce ??= Timer(const Duration(milliseconds: 90), () {
      _debounce = null;
      if (_dirty) {
        _dirty = false;
        if (!_disposed) notifyListeners();
      }
    });
  }

  /// 清空并作为新的一批上传任务（拖入上传时使用）。
  void startBatch(List<SftpUploadTaskView> rows) {
    if (_disposed) return;
    _debounce?.cancel();
    _debounce = null;
    _dirty = false;
    _cancelledIds.clear();
    _pausedIds.clear();
    _items
      ..clear()
      ..addAll(rows);
    _batchTotal = rows.length;
    _batchSucceeded = 0;
    _notifyNow();
  }

  /// 在现有队列末尾追加任务（下载时使用，不清空进行中的上传）。
  ///
  /// 当队列里没有正在进行的任务（pending / uploading）时，视为「新一批」开始：
  /// 把 [batchTotal] / [batchSucceeded] 清零，避免脚部计数永远叠加上次的成功量
  /// （否则用户每拖一次都看到 `7/13`、`12/25`、`19/40`，无法看清当前这一批的
  /// 实际进度）。失败任务允许留在列表里展示，但不会让新批次被视为延续。
  void appendTasks(List<SftpUploadTaskView> rows) {
    if (_disposed) return;
    if (rows.isEmpty) return;
    final hasActive = _items.any(
      (t) =>
          t.state == SftpUploadRowState.pending ||
          t.state == SftpUploadRowState.uploading,
    );
    if (!hasActive) {
      _batchTotal = 0;
      _batchSucceeded = 0;
    }
    _items.addAll(rows);
    _batchTotal += rows.length;
    _notifyNow();
  }

  /// 用户请求取消该任务：排队中则立即从列表移除；进行中则标记，由传输层在块间隙中止。
  void userCancelFile(String id) {
    if (_disposed) return;
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final t = _items[idx];
    if (t.state == SftpUploadRowState.failed) return;

    _cancelledIds.add(id);
    if (t.state == SftpUploadRowState.pending) {
      _items.removeAt(idx);
      if (_batchTotal > 0) _batchTotal--;
      _notifyNow();
      return;
    }
    if (t.state == SftpUploadRowState.uploading) {
      _notifyNow();
      return;
    }
  }

  bool isCancellationRequested(String id) => _cancelledIds.contains(id);

  bool isPauseRequested(String id) => _pausedIds.contains(id);

  /// 暂停单个任务：传输层在 chunk 边界自旋等待；pending 在开始前等待。
  void userPauseFile(String id) {
    if (_disposed) return;
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final t = _items[idx];
    if (t.state == SftpUploadRowState.failed) return;
    if (_cancelledIds.contains(id)) return;
    if (_pausedIds.add(id)) _notifyNow();
  }

  void userResumeFile(String id) {
    if (_disposed) return;
    if (_pausedIds.remove(id)) _notifyNow();
  }

  /// 暂停全部进行中任务（pending + uploading）。
  bool userPauseAll() {
    if (_disposed) return false;
    var any = false;
    for (final t in _items) {
      if (t.state == SftpUploadRowState.failed) continue;
      if (_cancelledIds.contains(t.id)) continue;
      if (_pausedIds.add(t.id)) any = true;
    }
    if (any) _notifyNow();
    return any;
  }

  /// 恢复全部已暂停任务。
  bool userResumeAll() {
    if (_disposed) return false;
    if (_pausedIds.isEmpty) return false;
    _pausedIds.clear();
    _notifyNow();
    return true;
  }

  /// 一键取消整个队列。
  ///
  /// * `uploading` 行：把 id 写进 [_cancelledIds]，让传输层在下一个 chunk 边界
  ///   看到取消标记后通过 [removeCancelled] 自然出列。**不能**立刻从 [_items]
  ///   抹掉 —— 否则传输层结束时调 `onFileEnd → removeCancelled` 已经找不到对应
  ///   行，进度对账会乱（`_batchTotal` 也可能被减两次）。
  /// * `pending` 行：传输层还没轮到（没 `sftp.open`、没读流），可以立刻从列表
  ///   抹掉。**但同时必须** 把 id 加入 [_cancelledIds]，否则执行器
  ///   （`executeDownloadPlan` / `uploadPlannedFiles`）真正轮到该 entry 时
  ///   `shouldCancelUpload` 还是返回 false，会按部就班把这个已经从 UI 拿掉的
  ///   "假死"任务再下载一遍。被加入后执行器只需在 entry 顶端发现取消标记，立刻
  ///   `onFileEnd(SftpUserCancelled)` → `removeCancelled`（id 已不在 `_items`
  ///   里，`removeCancelled` 的 `idx < 0` 守卫会自动跳过二次 `_batchTotal--`）。
  /// * `failed` 行：已经是终态、传输层不再跑它，直接清掉，让"全部取消"等价于
  ///   "脚部清空"的语义。
  ///
  /// 返回 `true` 表示真的有任务被影响（用于 UI 给出反馈，或避免无意义的通知）。
  bool userCancelAll() {
    if (_disposed) return false;
    if (_items.isEmpty) return false;
    final keep = <SftpUploadTaskView>[];
    var anyChanged = false;
    for (final t in _items) {
      switch (t.state) {
        case SftpUploadRowState.uploading:
          if (_cancelledIds.add(t.id)) anyChanged = true;
          keep.add(t);
        case SftpUploadRowState.pending:
          _cancelledIds.add(t.id);
          if (_batchTotal > 0) _batchTotal--;
          anyChanged = true;
        case SftpUploadRowState.failed:
          anyChanged = true;
      }
    }
    if (!anyChanged) return false;
    _items
      ..clear()
      ..addAll(keep);
    _notifyNow();
    return true;
  }

  /// 传输层在用户取消完成后调用。
  void removeCancelled(String id) {
    if (_disposed) return;
    _cancelledIds.remove(id);
    _pausedIds.remove(id);
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _items.removeAt(idx);
    if (_batchTotal > 0) _batchTotal--;
    _notifyNow();
  }

  /// 按 id 移除一行（失败重试前出列；不计取消）。
  void removeById(String id) {
    if (_disposed) return;
    _cancelledIds.remove(id);
    _pausedIds.remove(id);
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _items.removeAt(idx);
    if (_batchTotal > 0) _batchTotal--;
    _notifyNow();
  }

  /// 失败行列表快照（「全部重试」用）。
  List<SftpUploadTaskView> get failedItems =>
      _items.where((t) => t.state == SftpUploadRowState.failed).toList();

  void setUploading(String id) {
    if (_disposed) return;
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _items[idx].state = SftpUploadRowState.uploading;
    _notifyNow();
  }

  void progress(String id, int uploadedBytes) {
    if (_disposed) return;
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _items[idx].uploadedBytes = uploadedBytes;
    _scheduleDebounced();
  }

  void succeed(String id) {
    if (_disposed) return;
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _cancelledIds.remove(id);
    _pausedIds.remove(id);
    _items.removeAt(idx);
    _batchSucceeded++;
    _notifyNow();
  }

  void fail(String id, Object error) {
    if (_disposed) return;
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _pausedIds.remove(id);
    _items[idx].error = error;
    _items[idx].state = SftpUploadRowState.failed;
    _notifyNow();
  }

  /// 调整列表显示顺序，并影响尚未开始的 pending 项执行次序
  /// （执行器每取下一项前按 [preferredUploadOrder] 重排剩余 plan）。
  void reorder(int oldIndex, int newIndex) {
    if (_disposed) return;
    if (oldIndex < 0 || oldIndex >= _items.length) return;
    var dest = newIndex;
    if (dest > oldIndex) dest -= 1;
    if (dest < 0 || dest >= _items.length) return;
    if (oldIndex == dest) return;
    final item = _items.removeAt(oldIndex);
    _items.insert(dest, item);
    _notifyNow();
  }

  /// 将任务移到 pending 队列最前（紧接在所有 uploading 行之后）。
  /// 尚未开始的项会因此被执行器优先拾取。
  void prioritize(String id) {
    if (_disposed) return;
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final item = _items[idx];
    if (item.state == SftpUploadRowState.uploading) return;
    _items.removeAt(idx);
    var insertAt = 0;
    while (insertAt < _items.length &&
        _items[insertAt].state == SftpUploadRowState.uploading) {
      insertAt++;
    }
    _items.insert(insertAt, item);
    _notifyNow();
  }

  /// 当前列表中的任务 id 顺序（供上传执行器尊重 UI 优先级）。
  List<String> preferredUploadOrder() => [for (final t in _items) t.id];

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _debounce?.cancel();
    _items.clear();
    _cancelledIds.clear();
    _pausedIds.clear();
    _batchTotal = 0;
    _batchSucceeded = 0;
    super.dispose();
  }
}
