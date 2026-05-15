import 'dart:async';

import 'package:flutter/foundation.dart';

/// 传输方向（用于队列图标与语义）。
enum SftpTransferDirection {
  upload,
  download,
}

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
  });

  final String id;
  final String label;
  final int totalBytes;
  final SftpTransferDirection direction;
  int uploadedBytes;
  Object? error;
  SftpUploadRowState state;
}

/// 上传/下载队列展示用，与 [SshWorkspaceController] 并列。
class SftpUploadTaskList extends ChangeNotifier {
  final List<SftpUploadTaskView> _items = [];

  final Set<String> _cancelledIds = {};

  int _batchTotal = 0;
  int _batchSucceeded = 0;

  List<SftpUploadTaskView> get items => List.unmodifiable(_items);

  /// 本批任务总数（随 [appendTasks] / 成功 / 取消 变化）。
  int get batchTotal => _batchTotal;

  /// 已成功完成并从列表移除的数量。
  int get batchSucceeded => _batchSucceeded;

  Timer? _debounce;
  var _dirty = false;
  var _disposed = false;

  void clear() {
    _debounce?.cancel();
    _debounce = null;
    _dirty = false;
    _batchTotal = 0;
    _batchSucceeded = 0;
    _cancelledIds.clear();
    if (_items.isEmpty) return;
    _items.clear();
    if (!_disposed) notifyListeners();
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
    _items
      ..clear()
      ..addAll(rows);
    _batchTotal = rows.length;
    _batchSucceeded = 0;
    _notifyNow();
  }

  /// 在现有队列末尾追加任务（下载时使用，不清空进行中的上传）。
  void appendTasks(List<SftpUploadTaskView> rows) {
    if (_disposed) return;
    if (rows.isEmpty) return;
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

  /// 传输层在用户取消完成后调用。
  void removeCancelled(String id) {
    if (_disposed) return;
    _cancelledIds.remove(id);
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _items.removeAt(idx);
    if (_batchTotal > 0) _batchTotal--;
    _notifyNow();
  }

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
    _items.removeAt(idx);
    _batchSucceeded++;
    _notifyNow();
  }

  void fail(String id, Object error) {
    if (_disposed) return;
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _items[idx].error = error;
    _items[idx].state = SftpUploadRowState.failed;
    _notifyNow();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _items.clear();
    _cancelledIds.clear();
    _batchTotal = 0;
    _batchSucceeded = 0;
    super.dispose();
  }
}
