import 'dart:async';

import 'package:flutter/foundation.dart';

/// 单个本地上传任务（每个文件一行；成功后从列表移除，失败则保留并带 [error]）。
class SftpUploadTaskView {
  SftpUploadTaskView({
    required this.id,
    required this.label,
    required this.totalBytes,
    this.uploadedBytes = 0,
    this.error,
  });

  final String id;
  final String label;
  final int totalBytes;
  int uploadedBytes;
  Object? error;
}

/// 上传队列展示用，与 [SshWorkspaceController] 并列，避免进度回调触发整棵文件树重建。
class SftpUploadTaskList extends ChangeNotifier {
  final List<SftpUploadTaskView> _items = [];

  List<SftpUploadTaskView> get items => List.unmodifiable(_items);

  Timer? _debounce;
  var _dirty = false;
  var _disposed = false;

  void clear() {
    _debounce?.cancel();
    _debounce = null;
    _dirty = false;
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

  void startFile(String id, String label, int totalBytes) {
    if (_disposed) return;
    _items.add(SftpUploadTaskView(id: id, label: label, totalBytes: totalBytes));
    _notifyNow();
  }

  void progress(String id, int uploadedBytes) {
    if (_disposed) return;
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    _items[idx].uploadedBytes = uploadedBytes;
    _scheduleDebounced();
  }

  void endFile(String id, {Object? error}) {
    if (_disposed) return;
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    if (error != null) {
      _items[idx].error = error;
      _notifyNow();
    } else {
      _items.removeAt(idx);
      _notifyNow();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _items.clear();
    super.dispose();
  }
}
