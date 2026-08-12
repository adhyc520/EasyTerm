import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// Streaming exec channel: runs one command, emits stdout/stderr lines.
///
/// Used for live `tail -f` / `journalctl -f`. Backed by SSH exec or a generic
/// byte source ([fromByteSource] / emulator).
class RemoteStream extends ChangeNotifier {
  RemoteStream._({
    required this.maxLines,
    SSHSession? session,
    String command = '',
    Future<void> Function()? onCancel,
  })  : _session = session,
        _cmd = command,
        _onCancel = onCancel;

  final SSHSession? _session;
  final String _cmd;
  final int maxLines;
  final Future<void> Function()? _onCancel;

  StreamSubscription<dynamic>? _outSub;
  StreamSubscription<dynamic>? _errSub;
  final List<String> _lines = [];
  String _pendingLine = '';
  bool _closed = false;
  bool _debugCounted = false;
  int? _exitCode;
  String? _error;
  Future<int?>? _exitFuture;

  /// Start via SSH `client.execute`.
  ///
  /// [stdinBytes] are written then stdin is closed (e.g. `sudo -S`).
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
    s._wireSsh();
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

  /// Generic byte-source constructor (Telnet/Serial ShellExecEmulator).
  ///
  /// [stdout] may be `Stream<List<int>>` or `Stream<String>`.
  factory RemoteStream.fromByteSource({
    required String command,
    int maxLines = 5000,
    required Stream<dynamic> stdout,
    Stream<dynamic>? stderr,
    Future<int?>? exitCode,
    Future<void> Function()? cancel,
    void Function(List<int> bytes)? writeStdin,
    List<int>? stdinBytes,
  }) {
    final s = RemoteStream._(
      maxLines: maxLines,
      command: command,
      onCancel: cancel,
    );
    s._exitFuture = exitCode;
    s._wireGeneric(stdout, stderr);
    if (stdinBytes != null && stdinBytes.isNotEmpty && writeStdin != null) {
      writeStdin(stdinBytes);
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

  void _wireSsh() {
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

  void _wireGeneric(Stream<dynamic> stdout, Stream<dynamic>? stderr) {
    _outSub = stdout.listen(
      (data) => _append(_asString(data)),
      onError: (Object e) => _fail(e),
      onDone: () => unawaited(_doneAsync()),
    );
    if (stderr != null) {
      _errSub = stderr.listen(
        (data) => _append(_asString(data)),
        onError: (Object e) => _fail(e),
      );
    }
  }

  static String _asString(dynamic data) {
    if (data is String) return data;
    if (data is List<int>) {
      return utf8.decode(data, allowMalformed: true);
    }
    return '$data';
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

  Future<void> _doneAsync() async {
    if (_pendingLine.isNotEmpty) {
      _pushLine(_pendingLine);
      _pendingLine = '';
    }
    try {
      if (_exitFuture != null) {
        _exitCode = await _exitFuture;
      } else {
        _exitCode = _session?.exitCode;
      }
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
    // Already closed by natural completion — do not re-run cancel (would
    // inject Ctrl-C into a shared Telnet/Serial shell).
    if (_closed) {
      await _outSub?.cancel();
      await _errSub?.cancel();
      _outSub = null;
      _errSub = null;
      return;
    }
    _closed = true;
    await _outSub?.cancel();
    await _errSub?.cancel();
    _outSub = null;
    _errSub = null;
    try {
      _session?.close();
    } catch (_) {}
    try {
      await _onCancel?.call();
    } catch (_) {}
    _releaseDebugCount();
    notifyListeners();
  }
}
