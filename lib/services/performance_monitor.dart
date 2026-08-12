import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 简易性能监控：帧耗时采样 + 可选开发叠加提示。
class PerformanceMonitor {
  PerformanceMonitor._();
  static final PerformanceMonitor instance = PerformanceMonitor._();

  bool enabled = false;
  double lastFrameMs = 0;
  double avgFrameMs = 0;
  int _sampleCount = 0;
  double _sampleSum = 0;
  TimingsCallback? _callback;

  void start() {
    if (_callback != null) return;
    _callback = (timings) {
      if (!enabled || timings.isEmpty) return;
      final t = timings.last;
      final ms = t.totalSpan.inMicroseconds / 1000.0;
      lastFrameMs = ms;
      _sampleSum += ms;
      _sampleCount++;
      if (_sampleCount >= 30) {
        avgFrameMs = _sampleSum / _sampleCount;
        _sampleSum = 0;
        _sampleCount = 0;
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_callback!);
  }

  void stop() {
    final cb = _callback;
    if (cb != null) {
      SchedulerBinding.instance.removeTimingsCallback(cb);
      _callback = null;
    }
  }

  void setEnabled(bool v) {
    enabled = v;
    if (v) {
      start();
    } else {
      stop();
    }
  }

  /// 开发模式下打印平均帧耗时。
  void debugLogIfSlow({double thresholdMs = 20}) {
    if (!kDebugMode || !enabled) return;
    if (avgFrameMs > thresholdMs) {
      debugPrint(
        'PerformanceMonitor: avg frame ${avgFrameMs.toStringAsFixed(1)} ms',
      );
    }
  }
}
