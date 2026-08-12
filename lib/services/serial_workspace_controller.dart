import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../models/connection_protocol.dart';
import '../models/proxy_config.dart';
import '../models/serial_port_config.dart';
import 'command_history_service.dart';
import 'pty_interceptor.dart';
import 'remote_exec_capable.dart';
import 'remote_host_metrics.dart';
import 'remote_process_list.dart' show RemoteOsKind;
import 'remote_stream.dart';
import 'serial/serial_transport.dart';
import 'session_recorder.dart';
import 'shell_exec_emulator.dart';
import 'term_write_batcher.dart';
import 'terminal_charset.dart';
import 'terminal_session_controller.dart';
import 'workbench_settings_store.dart';

class _SerialShellBackend implements ShellBackend {
  _SerialShellBackend(this._transport);

  final SerialTransport _transport;

  @override
  void write(List<int> bytes) => _transport.add(bytes);

  @override
  Stream<List<int>> get output => _transport.input;
}

/// Serial workspace: single-port terminal + ShellExecEmulator on the main stream.
class SerialWorkspaceController extends ChangeNotifier
    implements TerminalSessionController, RemoteExecCapable {
  SerialWorkspaceController({
    required this.settings,
    required SerialPortConfig serialConfig,
    this.encoding = TerminalEncoding.utf8,
  })  : _serialConfig = serialConfig,
        host = serialConfig.name,
        port = serialConfig.baudRate {
    settings.addListener(_onSettingsChanged);
  }

  final WorkbenchSettingsStore settings;
  final SerialPortConfig _serialConfig;

  @override
  final String host;

  @override
  final int port;

  @override
  String get username => '';

  TerminalEncoding encoding;

  SerialPortConfig get serialConfig => _serialConfig;

  @override
  ConnectionProtocol get protocol => ConnectionProtocol.serial;

  @override
  Set<RemoteCapability> get capabilities => const {
        RemoteCapability.terminal,
        RemoteCapability.exec,
      };

  @override
  String get password => '';

  @override
  ProxyConfig? get proxyConfig => null;

  @override
  String get sessionLabel => '$host@$port';

  final SerialTransport _transport = SerialTransport();
  StreamSubscription<List<int>>? _inputSub;
  Terminal? _terminal;
  final TermWriteBatcher _termWriteBatcher = TermWriteBatcher();
  SessionRecorder? _sessionRecorder;
  ShellExecEmulator? _emulator;
  final Set<RemoteStream> _activeStreams = {};
  String? _lastExecError;
  String _remoteCwd = '/';
  RemoteHostSnapshot? _lastSnapshot;
  DateTime? _lastSnapshotAt;
  Timer? _sttyDebounce;
  int? _pendingSttyCols;
  int? _pendingSttyRows;

  String _terminalCwd = '/';
  bool _mouseMode = false;
  bool _sawOsc7 = false;
  late final PtyInterceptor _ptyInterceptor = PtyInterceptor(
    onCwd: (cwd) {
      if (_terminalCwd == cwd && _sawOsc7) return;
      _terminalCwd = cwd;
      _sawOsc7 = true;
      notifyListeners();
    },
    onMouseMode: (active) {
      if (_mouseMode == active) return;
      _mouseMode = active;
      notifyListeners();
    },
  );

  String? _error;
  bool _connecting = false;
  bool _connected = false;
  bool _dropped = false;
  bool _sessionDisposed = false;

  @override
  Terminal? get terminal => _terminal;
  @override
  bool get connecting => _connecting;
  @override
  bool get connected => _connected;
  @override
  bool get dropped => _dropped;
  @override
  String? get error => _error;
  @override
  String get terminalCwd => _terminalCwd;
  @override
  bool get mouseModeActive => _mouseMode;
  bool get sawOsc7 => _sawOsc7;

  @override
  SessionRecorder? get sessionRecorder => _sessionRecorder;
  @override
  bool get isSessionRecording => _sessionRecorder?.isRecording ?? false;

  Encoding get _codec => encoding.codec;

  void _onSettingsChanged() => notifyListeners();

  void setEncoding(TerminalEncoding next) {
    if (encoding == next) return;
    encoding = next;
    // Emulator captures codec at construction — rebuild on next exec use.
    unawaited(() async {
      await _emulator?.dispose();
      _emulator = null;
    }());
    notifyListeners();
  }

  @override
  void startSessionRecording() {
    final term = _terminal;
    _sessionRecorder ??= SessionRecorder();
    _sessionRecorder!.start(
      cols: term?.viewWidth ?? 80,
      rows: term?.viewHeight ?? 24,
    );
    notifyListeners();
  }

  @override
  void stopSessionRecording() {
    if (_sessionRecorder == null || !_sessionRecorder!.isRecording) return;
    _sessionRecorder!.stop();
    notifyListeners();
  }

  @override
  void toggleSessionRecording() {
    if (isSessionRecording) {
      stopSessionRecording();
    } else {
      startSessionRecording();
    }
  }

  @override
  void pasteRemoteInput(String text) {
    if (!_connected) return;
    _terminal?.paste(text);
  }

  @override
  String pasteRemoteInputWithLineSubmit(String text) {
    if (!_connected) return text;
    var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (t.isNotEmpty && !t.endsWith('\n') && !t.endsWith('\r')) {
      t = '$t\r';
    }
    _terminal?.textInput(t);
    _maybeRecordSubmittedCommand(t);
    return t;
  }

  void _maybeRecordSubmittedCommand(String submitted) {
    final hist = CommandHistoryService.shared;
    if (hist == null) return;
    var cmd = submitted.replaceAll(RegExp(r'[\r\n]+$'), '');
    if (cmd.contains('\n') || cmd.trim().isEmpty) return;
    unawaited(
      hist.recordCommand(sessionLabel, cmd.trim(), cwd: terminalCwd),
    );
  }

  @override
  String snapshotTerminalTail({int maxLines = 120, int maxChars = 24000}) {
    final t = _terminal;
    if (t == null || !_connected) return '';
    try {
      final buf = t.buffer;
      final h = buf.height;
      final w = buf.viewWidth;
      if (h <= 0 || w <= 0) return '';
      final startY = math.max(0, h - maxLines);
      final range = BufferRangeLine(
        CellOffset(0, startY),
        CellOffset(w - 1, h - 1),
      );
      var text = buf.getText(range);
      if (text.length > maxChars) {
        text = text.substring(text.length - maxChars);
      }
      return text;
    } catch (e, st) {
      debugPrint('snapshotTerminalTail: $e\n$st');
      return '';
    }
  }

  @override
  void injectTerminalLocalDisplay(String text) {
    final t = _terminal;
    if (t == null || !_connected) return;
    try {
      t.write(text);
      notifyListeners();
    } catch (e, st) {
      debugPrint('injectTerminalLocalDisplay: $e\n$st');
    }
  }

  @override
  Future<void> connect() async {
    if (_sessionDisposed) return;
    if (_connecting) return;
    _connecting = true;
    _error = null;
    _dropped = false;
    notifyListeners();
    try {
      await _teardownConnection(keepTerminal: true);
      await _transport.open(_serialConfig);
      if (_sessionDisposed) {
        await _transport.close();
        return;
      }
      _initTerminal();
      _wirePort();
      _ensureEmulator();
      _connected = true;
      _connecting = false;
      _dropped = false;
      notifyListeners();
    } catch (e) {
      _connecting = false;
      _connected = false;
      _error = '$e';
      notifyListeners();
    }
  }

  void _initTerminal() {
    if (_terminal != null) return;
    final term = Terminal(
      maxLines: settings.terminalMaxLines,
      platform: _xtermPlatform(),
      onOutput: (data) {
        if (!_connected || _dropped) return;
        _transport.add(_codec.encode(data));
        _sessionRecorder?.recordInput(data);
      },
      onResize: (w, h, pw, ph) {
        _sessionRecorder?.recordResize(w, h);
        // Best-effort: no NAWS on serial; debounce stty so rapid resizes
        // do not flood the main console.
        _pendingSttyCols = w;
        _pendingSttyRows = h;
        _sttyDebounce?.cancel();
        _sttyDebounce = Timer(const Duration(milliseconds: 400), () {
          final cols = _pendingSttyCols;
          final rows = _pendingSttyRows;
          if (cols == null || rows == null) return;
          if (!_connected || _dropped) return;
          unawaited(
            runQueued(
              'stty rows $rows cols $cols',
              timeout: const Duration(seconds: 2),
            ),
          );
        });
      },
    );
    _terminal = term;
  }

  void _wirePort() {
    _inputSub = _transport.input.listen(
      (data) {
        if (data.isEmpty) return;
        final text = _codec.decode(data);
        final processed = _ptyInterceptor.process(text);
        final term = _terminal;
        if (term != null) {
          unawaited(_termWriteBatcher.writeBatched(term, processed));
        }
        _sessionRecorder?.recordOutput(processed);
      },
      onError: (Object e) {
        _onTransportLost('$e');
      },
      onDone: () {
        _onTransportLost('串口已关闭');
      },
      cancelOnError: true,
    );
  }

  void _ensureEmulator() {
    _emulator ??= ShellExecEmulator(
      _SerialShellBackend(_transport),
      encoding: _codec,
    );
  }

  void _onTransportLost(String reason) {
    if (_sessionDisposed || !_connected) return;
    _dropped = true;
    _connected = false;
    _error = reason;
    unawaited(_teardownConnection(keepTerminal: true));
    notifyListeners();
  }

  @override
  Future<String?> runQueued(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    List<int>? stdinBytes,
  }) async {
    if (!_connected || _dropped) return null;
    try {
      _ensureEmulator();
      final emu = _emulator;
      if (emu == null) return null;
      final out = await emu.run(
        command,
        timeout: timeout,
        stdinBytes: stdinBytes,
      );
      _lastExecError = emu.lastError;
      return out;
    } catch (e) {
      _lastExecError = '$e';
      return null;
    }
  }

  @override
  Future<String?> runRemoteForStatus(String command) => runQueued(command);

  @override
  String? get lastRemoteCommandError => _lastExecError ?? _emulator?.lastError;

  @override
  bool get lightweightRemoteExec => true;

  @override
  Future<RemoteStream> startRemoteStream(
    String command, {
    int maxLines = 5000,
    List<int>? stdinBytes,
  }) async {
    if (!_connected || _dropped) {
      throw StateError('串口未连接');
    }
    _ensureEmulator();
    final emu = _emulator;
    if (emu == null) throw StateError('exec 仿真器不可用');
    final stream = await emu.startStream(
      command,
      maxLines: maxLines,
      stdinBytes: stdinBytes,
    );
    _activeStreams.add(stream);
    return stream;
  }

  @override
  void unregisterRemoteStream(RemoteStream stream) {
    _activeStreams.remove(stream);
  }

  @override
  String get remoteCwd => _remoteCwd;

  Future<void> _refreshRemoteCwd() async {
    final out = await runQueued('pwd', timeout: const Duration(seconds: 3));
    final line = out
        ?.split(RegExp(r'[\r\n]+'))
        .map((s) => s.trim())
        .firstWhere((s) => s.startsWith('/'), orElse: () => '');
    if (line != null && line.isNotEmpty) {
      _remoteCwd = line;
    }
  }

  @override
  Future<RemoteHostSnapshot?> snapshot({
    Duration maxAge = const Duration(seconds: 3),
    RemoteOsKind? osHint,
  }) async {
    final now = DateTime.now();
    final cached = _lastSnapshot;
    final at = _lastSnapshotAt;
    if (cached != null && at != null && now.difference(at) <= maxAge) {
      return cached;
    }
    final snap = await fetchRemoteHostSnapshot(this, osHint: osHint);
    if (snap != null) {
      _lastSnapshot = snap;
      _lastSnapshotAt = DateTime.now();
    }
    unawaited(_refreshRemoteCwd());
    return snap;
  }

  @override
  Future<SecondaryShell?> openSecondaryShell({int? cols, int? rows}) async {
    return null;
  }

  @override
  Future<void> disconnect() async {
    await _teardownConnection(keepTerminal: false);
    _connected = false;
    _dropped = false;
    _error = null;
    notifyListeners();
  }

  @override
  Future<void> reconnect() async {
    if (_connecting) return;
    await connect();
  }

  Future<void> _teardownConnection({bool keepTerminal = false}) async {
    _sttyDebounce?.cancel();
    _sttyDebounce = null;
    for (final s in List<RemoteStream>.from(_activeStreams)) {
      try {
        await s.stop();
      } catch (_) {}
    }
    _activeStreams.clear();
    await _emulator?.dispose();
    _emulator = null;
    await _inputSub?.cancel();
    _inputSub = null;
    _ptyInterceptor.reset();
    _mouseMode = false;
    await _transport.close();
    if (!keepTerminal) {
      _terminal = null;
      _terminalCwd = '/';
      _sawOsc7 = false;
    }
  }

  static TerminalTargetPlatform _xtermPlatform() {
    if (kIsWeb) return TerminalTargetPlatform.web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return TerminalTargetPlatform.android;
      case TargetPlatform.iOS:
        return TerminalTargetPlatform.ios;
      case TargetPlatform.fuchsia:
        return TerminalTargetPlatform.fuchsia;
      case TargetPlatform.linux:
        return TerminalTargetPlatform.linux;
      case TargetPlatform.macOS:
        return TerminalTargetPlatform.macos;
      case TargetPlatform.windows:
        return TerminalTargetPlatform.windows;
    }
  }

  @override
  void dispose() {
    _sessionDisposed = true;
    settings.removeListener(_onSettingsChanged);
    unawaited(_teardownConnection(keepTerminal: false));
    unawaited(_transport.dispose());
    super.dispose();
  }
}
