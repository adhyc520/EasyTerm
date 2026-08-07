import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// 串行化（或低并发）执行一次性命令，避免多窗口轮询在同一 SSH 连接上并发 exec 拥塞。
class RemoteCommandQueue {
  RemoteCommandQueue(
    this._clientGetter, {
    this.maxConcurrent = 2,
    Future<String?> Function(
      String command,
      Duration timeout, {
      List<int>? stdinBytes,
    })? testRunner,
  }) : _testRunner = testRunner;

  /// 无 SSH 的单元测试入口。
  @visibleForTesting
  factory RemoteCommandQueue.test(
    Future<String?> Function(
      String command,
      Duration timeout, {
      List<int>? stdinBytes,
    }) runner, {
    int maxConcurrent = 2,
  }) {
    return RemoteCommandQueue(
      () => null,
      maxConcurrent: maxConcurrent,
      testRunner: runner,
    );
  }

  final SSHClient? Function() _clientGetter;
  final Future<String?> Function(
    String command,
    Duration timeout, {
    List<int>? stdinBytes,
  })? _testRunner;
  final int maxConcurrent;

  int _inFlight = 0;
  final List<_QueuedCmd> _pending = [];
  bool _disposed = false;

  int get inFlight => _inFlight;
  int get pendingCount => _pending.length;

  /// 排队执行；失败 / 掉线 / 超时均返回 `null`，错误写入 [lastError]。
  ///
  /// [stdinBytes] 写入远端 stdin 后关闭（用于 `sudo -S` 等）。
  Future<String?> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    List<int>? stdinBytes,
  }) {
    if (_disposed) return Future.value(null);
    final c = Completer<String?>();
    _enqueue(_QueuedCmd(command, timeout, c, stdinBytes));
    return c.future;
  }

  String? lastError;
  DateTime? lastErrorAt;

  void _enqueue(_QueuedCmd cmd) {
    _pending.add(cmd);
    _pump();
  }

  void _pump() {
    while (!_disposed &&
        _inFlight < maxConcurrent &&
        _pending.isNotEmpty) {
      final cmd = _pending.removeAt(0);
      _inFlight++;
      unawaited(_exec(cmd));
    }
  }

  Future<void> _exec(_QueuedCmd cmd) async {
    try {
      final testRunner = _testRunner;
      if (testRunner != null) {
        final out = await testRunner(
          cmd.command,
          cmd.timeout,
          stdinBytes: cmd.stdinBytes,
        );
        if (out == null) {
          lastError = '命令失败或已断开';
          lastErrorAt = DateTime.now();
        } else {
          lastError = null;
        }
        if (!cmd.completer.isCompleted) cmd.completer.complete(out);
        return;
      }
      final client = _clientGetter();
      if (client == null) {
        lastError = '连接已断开';
        lastErrorAt = DateTime.now();
        if (!cmd.completer.isCompleted) cmd.completer.complete(null);
        return;
      }
      final out = await _runOnce(
        client,
        cmd.command,
        stdinBytes: cmd.stdinBytes,
      ).timeout(cmd.timeout);
      lastError = null;
      if (!cmd.completer.isCompleted) {
        cmd.completer.complete(out);
      }
    } catch (e) {
      debugPrint('cmdq run: $e');
      lastError = '$e';
      lastErrorAt = DateTime.now();
      if (!cmd.completer.isCompleted) {
        cmd.completer.complete(null);
      }
    } finally {
      _inFlight--;
      _pump();
    }
  }

  /// 有 stdin 时走 [SSHClient.execute]；否则沿用 [SSHClient.run]。
  static Future<String> _runOnce(
    SSHClient client,
    String command, {
    List<int>? stdinBytes,
  }) async {
    if (stdinBytes == null || stdinBytes.isEmpty) {
      final out = await client.run(command, stderr: false);
      return utf8.decode(out, allowMalformed: true).trim();
    }

    final session = await client.execute(command);
    try {
      final outputBuilder = BytesBuilder(copy: false);
      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();

      session.stdout.listen(
        outputBuilder.add,
        onDone: stdoutDone.complete,
        onError: stdoutDone.completeError,
        cancelOnError: true,
      );
      // 命令侧通常已 `2>&1`；仍吞掉 stderr 以免阻塞。
      session.stderr.listen(
        (_) {},
        onDone: stderrDone.complete,
        onError: stderrDone.completeError,
        cancelOnError: true,
      );

      session.write(Uint8List.fromList(stdinBytes));
      await session.stdin.close();

      await stdoutDone.future;
      await stderrDone.future;
      await session.done;
      return utf8.decode(outputBuilder.takeBytes(), allowMalformed: true).trim();
    } finally {
      // timeout / 取消时也关掉通道，避免 sudo -S session 泄漏。
      try {
        session.close();
      } catch (_) {}
    }
  }

  /// 掉线 / 退桌面：清空排队。
  void clearPending() {
    final waiting = List<_QueuedCmd>.from(_pending);
    _pending.clear();
    for (final cmd in waiting) {
      if (!cmd.completer.isCompleted) {
        cmd.completer.complete(null);
      }
    }
  }

  void dispose() {
    _disposed = true;
    clearPending();
  }
}

class _QueuedCmd {
  _QueuedCmd(this.command, this.timeout, this.completer, this.stdinBytes);
  final String command;
  final Duration timeout;
  final Completer<String?> completer;
  final List<int>? stdinBytes;
}
