import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// 一条流式 exec 通道：跑一条命令，按行吐出 stdout/stderr，可停止、可观察退出码。
///
/// 用于实时 `tail -f` / `journalctl -f` 等持续输出场景，替代轮询快照。
class RemoteStream extends ChangeNotifier {
  RemoteStream._({
    required this.maxLines,
    SSHSession? session,
    String command = '',
  })  : _session = session,
        _cmd = command;

  final SSHSession? _session;
  final String _cmd;
  final int maxLines;

  StreamSubscription<Uint8List>? _outSub;
  StreamSubscription<Uint8List>? _errSub;
  final List<String> _lines = [];
  String _pendingLine = '';
  bool _closed = false;
  bool _debugCounted = false;
  int? _exitCode;
  String? _error;

  /// 启动流式命令。
  ///
  /// [stdinBytes] 写入远端 stdin 后关闭（例如 `sudo -S`）。
  static Future<RemoteStream> start(
    SSHClient? client, {
    required String command,
    int maxLines = 5000,
    List<int>? stdinBytes,
  }) async {
    if (client == null) {
      throw StateError('SSH 未连接');
    }
    final session = await client.execute(command);
    final s = RemoteStream._(
      session: session,
      command: command,
      maxLines: maxLines,
    );
    s._wire();
    if (stdinBytes != null && stdinBytes.isNotEmpty) {
      session.write(Uint8List.fromList(stdinBytes));
      await session.stdin.close();
    }
    s._debugCounted = true;
    debugAliveStreams++;
    if (kDebugMode) {
      debugPrint('RemoteStream+ alive=$debugAliveStreams cmd=$command');
    }
    return s;
  }

  /// debug：当前未 stop 的流式通道数。
  static int debugAliveStreams = 0;

  void _releaseDebugCount() {
    if (!_debugCounted) return;
    _debugCounted = false;
    if (debugAliveStreams > 0) debugAliveStreams--;
    if (kDebugMode) {
      debugPrint('RemoteStream- alive=$debugAliveStreams');
    }
  }

  /// 无 SSH 的单元测试入口：直接喂文本块。
  @visibleForTesting
  static RemoteStream forTest({int maxLines = 5000}) {
    return RemoteStream._(maxLines: maxLines, command: 'test');
  }

  @visibleForTesting
  void injectChunk(String chunk) => _append(chunk);

  @visibleForTesting
  void markDone({int? exitCode}) {
    if (_pendingLine.isNotEmpty) {
      _pushLine(_pendingLine);
      _pendingLine = '';
    }
    _exitCode = exitCode;
    _closed = true;
    notifyListeners();
  }

  @visibleForTesting
  void injectError(Object e) => _fail(e);

  void _wire() {
    final session = _session;
    if (session == null) return;
    _outSub = session.stdout.listen(
      (data) => _append(utf8.decode(data, allowMalformed: true)),
      onError: (Object e) => _fail(e),
      onDone: () => _done(),
    );
    _errSub = session.stderr.listen(
      (data) => _append(utf8.decode(data, allowMalformed: true)),
      onError: (Object e) => _fail(e),
    );
  }

  void _append(String chunk) {
    if (_closed || chunk.isEmpty) return;
    var data = '$_pendingLine$chunk';
    _pendingLine = '';
    while (true) {
      final i = data.indexOf('\n');
      if (i < 0) {
        _pendingLine = data;
        break;
      }
      var line = data.substring(0, i);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      _pushLine(line);
      data = data.substring(i + 1);
    }
    notifyListeners();
  }

  void _pushLine(String line) {
    _lines.add(line);
    while (_lines.length > maxLines) {
      _lines.removeAt(0);
    }
  }

  void _fail(Object e) {
    _error = '$e';
    _closed = true;
    _releaseDebugCount();
    notifyListeners();
  }

  void _done() {
    if (_pendingLine.isNotEmpty) {
      _pushLine(_pendingLine);
      _pendingLine = '';
    }
    try {
      _exitCode = _session?.exitCode;
    } catch (_) {}
    _closed = true;
    _releaseDebugCount();
    notifyListeners();
  }

  List<String> get lines => List.unmodifiable(_lines);
  bool get closed => _closed;
  int? get exitCode => _exitCode;
  String? get error => _error;
  String get command => _cmd;

  /// 等到通道关闭（成功 / 失败 / [stop]）。
  Future<void> waitUntilClosed() {
    if (_closed) return Future.value();
    final c = Completer<void>();
    void listener() {
      if (!_closed) return;
      removeListener(listener);
      if (!c.isCompleted) c.complete();
    }

    addListener(listener);
    if (_closed) {
      removeListener(listener);
      if (!c.isCompleted) c.complete();
    }
    return c.future;
  }

  Future<void> stop() async {
    _closed = true;
    await _outSub?.cancel();
    await _errSub?.cancel();
    _outSub = null;
    _errSub = null;
    try {
      _session?.close();
    } catch (_) {}
    _releaseDebugCount();
    notifyListeners();
  }
}
