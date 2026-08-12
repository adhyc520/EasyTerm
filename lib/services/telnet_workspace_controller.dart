import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../models/connection_protocol.dart';
import '../models/proxy_config.dart';
import 'command_history_service.dart';
import 'proxy_connector.dart';
import 'pty_interceptor.dart';
import 'remote_exec_capable.dart';
import 'remote_host_metrics.dart';
import 'remote_process_list.dart' show RemoteOsKind;
import 'remote_stream.dart';
import 'session_recorder.dart';
import 'shell_exec_emulator.dart';
import 'term_write_batcher.dart';
import 'terminal_charset.dart';
import 'terminal_session_controller.dart';
import 'telnet/telnet_login_matcher.dart';
import 'telnet/telnet_negotiator.dart';
import 'telnet/telnet_remote_shell.dart';
import 'workbench_settings_store.dart';

class _TelnetShellBackend implements ShellBackend {
  _TelnetShellBackend(this._add, this._output);
  final void Function(List<int>) _add;
  final StreamController<List<int>> _output;

  @override
  void write(List<int> bytes) => _add(bytes);

  @override
  Stream<List<int>> get output => _output.stream;
}

/// Telnet workspace: primary TCP+IAC terminal + optional second connection for exec.
class TelnetWorkspaceController extends ChangeNotifier
    implements TerminalSessionController, RemoteExecCapable {
  TelnetWorkspaceController({
    required this.settings,
    required this.host,
    required this.port,
    required this.username,
    required String password,
    ProxyConfig? proxyConfig,
    this.encoding = TerminalEncoding.utf8,
    this.autoInjectCredentials = true,
    int? connectTimeoutSecOverride,
  })  : _password = password,
        _proxyConfig = proxyConfig,
        _connectTimeoutSecOverride = connectTimeoutSecOverride {
    settings.addListener(_onSettingsChanged);
  }

  final WorkbenchSettingsStore settings;
  @override
  final String host;
  @override
  final int port;
  @override
  final String username;
  String _password;
  final ProxyConfig? _proxyConfig;
  TerminalEncoding encoding;
  final bool autoInjectCredentials;
  final int? _connectTimeoutSecOverride;

  @override
  ConnectionProtocol get protocol => ConnectionProtocol.telnet;

  @override
  Set<RemoteCapability> get capabilities => const {
        RemoteCapability.terminal,
        RemoteCapability.exec,
      };

  @override
  String get password => _password;

  @override
  ProxyConfig? get proxyConfig => _proxyConfig;

  @override
  String get sessionLabel {
    final user = username.trim();
    if (user.isEmpty) return '$host:$port';
    return '$user@$host:$port';
  }

  Socket? _socket;
  TelnetNegotiator? _negotiator;
  TelnetLoginMatcher? _loginMatcher;
  StreamSubscription? _socketSub;
  Terminal? _terminal;
  final TermWriteBatcher _termWriteBatcher = TermWriteBatcher();
  SessionRecorder? _sessionRecorder;

  // Exec: prefer second Telnet connection; fall back to primary shell (Serial-style).
  Socket? _execSocket;
  StreamSubscription? _execSub;
  final _execOutput = StreamController<List<int>>.broadcast();
  /// Tee of primary session payload for fallback exec on the main connection.
  final _primaryExecFanout = StreamController<List<int>>.broadcast();
  ShellExecEmulator? _emulator;
  bool _usePrimaryExec = false;
  Future<void>? _ensureExecInFlight;
  final Set<RemoteStream> _activeStreams = {};
  String? _lastExecError;
  String _remoteCwd = '/';
  RemoteHostSnapshot? _lastSnapshot;
  DateTime? _lastSnapshotAt;

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

  int get _effectiveConnectTimeoutSec =>
      _connectTimeoutSecOverride ?? settings.connectTimeoutSec;

  void _onSettingsChanged() => notifyListeners();

  void setEncoding(TerminalEncoding next) {
    if (encoding == next) return;
    encoding = next;
    // Exec emulator captures codec at construction — rebuild on change.
    unawaited(_closeExecBackend());
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

  Future<OpenedTcpSocket> _openSocket() async {
    final timeout = Duration(seconds: _effectiveConnectTimeoutSec);
    final proxy = _proxyConfig;
    if (proxy != null &&
        (proxy.type == ProxyType.socks5 || proxy.type == ProxyType.http)) {
      return ProxyConnector.openTcpViaProxy(
        proxy: proxy,
        targetHost: host,
        targetPort: port,
        timeout: timeout,
      );
    }
    final socket = await Socket.connect(host, port, timeout: timeout);
    return OpenedTcpSocket(socket);
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
      final opened = await _openSocket();
      if (_sessionDisposed) {
        await opened.socket.close();
        return;
      }
      _socket = opened.socket;
      _initTerminal();
      _wireSocket(opened.socket, pendingBytes: opened.pendingBytes);
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
        final sock = _socket;
        final neg = _negotiator;
        if (sock == null || neg == null) return;
        final raw = _codec.encode(data);
        sock.add(TelnetNegotiator.escapeIac(raw));
        _sessionRecorder?.recordInput(data);
      },
      onResize: (w, h, pw, ph) {
        _negotiator?.sendNaws(w, h);
        _sessionRecorder?.recordResize(w, h);
      },
    );
    _terminal = term;
  }

  void _wireSocket(Socket socket, {List<int> pendingBytes = const []}) {
    late final TelnetNegotiator negotiator;
    negotiator = TelnetNegotiator(
      send: (b) {
        try {
          socket.add(b);
        } catch (_) {}
      },
      terminalType: settings.terminalTermType,
      debugLog: kDebugMode ? (m) => debugPrint('TelnetIAC $m') : null,
    );
    _negotiator = negotiator;
    negotiator.startLocalOffers();

    _loginMatcher = TelnetLoginMatcher(
      username: username,
      password: _password,
      enabled: autoInjectCredentials,
      encoding: _codec,
    );

    void handle(List<int> data) {
      final payload = negotiator.feed(data);
      if (payload.isEmpty) return;
      // Always tee for primary-exec fallback (idle subscribers cost nothing).
      if (!_primaryExecFanout.isClosed) {
        _primaryExecFanout.add(List<int>.from(payload));
      }
      final text = _codec.decode(payload);
      final inject = _loginMatcher?.feedText(text) ?? const <int>[];
      if (inject.isNotEmpty) {
        socket.add(TelnetNegotiator.escapeIac(inject));
      }
      final processed = _ptyInterceptor.process(text);
      final term = _terminal;
      if (term != null) {
        unawaited(_termWriteBatcher.writeBatched(term, processed));
      }
      _sessionRecorder?.recordOutput(processed);
    }

    if (pendingBytes.isNotEmpty) {
      handle(pendingBytes);
    }
    _socketSub = socket.listen(
      handle,
      onError: (Object e) {
        _onTransportLost('$e');
      },
      onDone: () {
        _onTransportLost('连接已关闭');
      },
      cancelOnError: true,
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

  Future<void> _ensureExecBackend({bool allowInteractiveFallback = true}) async {
    while (true) {
      if (_sessionDisposed || !_connected || _dropped) return;
      if (_emulator != null) return;
      final inFlight = _ensureExecInFlight;
      if (inFlight != null) {
        await inFlight;
        continue;
      }
      final gate = Completer<void>();
      _ensureExecInFlight = gate.future;
      try {
        if (_sessionDisposed || !_connected || _dropped) return;
        if (_emulator != null) return;

        // 1) Try dedicated second Telnet connection (keeps main console clean).
        final secondaryOk = await _trySecondaryExecBackend();
        if (_emulator != null) return;
        if (secondaryOk) return;

        // 2) Fall back to primary connection (like Serial) — required when the
        // host allows only one Telnet session. Skipped for bulk/LLM to avoid
        // injecting into the interactive console.
        if (allowInteractiveFallback) {
          _attachPrimaryEmulator();
        } else {
          _lastExecError =
              'Telnet 无法建立独立 exec 会话；已禁止使用主终端执行以免干扰交互';
        }
        return;
      } catch (e) {
        debugPrint('telnet ensureExec: $e');
        await _closeSecondarySocket();
        if (_emulator == null &&
            _connected &&
            !_dropped &&
            allowInteractiveFallback) {
          _attachPrimaryEmulator();
        } else if (_emulator == null) {
          _lastExecError =
              'Telnet exec 后端启动失败；已禁止主终端 fallback：$e';
        }
        return;
      } finally {
        _ensureExecInFlight = null;
        if (!gate.isCompleted) gate.complete();
      }
    }
  }

  /// Returns true if secondary path fully succeeded (emulator ready).
  Future<bool> _trySecondaryExecBackend() async {
    try {
      final opened = await _openSocket();
      if (_sessionDisposed || !_connected || _dropped) {
        try {
          await opened.socket.close();
        } catch (_) {}
        try {
          opened.socket.destroy();
        } catch (_) {}
        return false;
      }
      final socket = opened.socket;
      _execSocket = socket;
      final outCtrl = _execOutput;
      late final TelnetNegotiator negotiator;
      negotiator = TelnetNegotiator(
        send: (b) {
          try {
            socket.add(b);
          } catch (_) {}
        },
        terminalType: settings.terminalTermType,
      );
      negotiator.startLocalOffers();

      final login = TelnetLoginMatcher(
        username: username,
        password: _password,
        enabled: autoInjectCredentials,
        encoding: _codec,
      );

      var shellReady = false;
      void handle(List<int> data) {
        final payload = negotiator.feed(data);
        if (payload.isEmpty) return;
        final text = _codec.decode(payload);
        final inject = login.feedText(text);
        if (inject.isNotEmpty) {
          socket.add(TelnetNegotiator.escapeIac(inject));
        }
        if (TelnetLoginMatcher.looksLikeShellPrompt(text)) {
          shellReady = true;
        }
        if (!outCtrl.isClosed) outCtrl.add(payload);
      }

      if (opened.pendingBytes.isNotEmpty) {
        handle(opened.pendingBytes);
      }
      _execSub = socket.listen(
        handle,
        onError: (Object e) {
          if (!outCtrl.isClosed) outCtrl.addError(e);
        },
        onDone: () {
          unawaited(_onSecondaryExecLost());
        },
      );

      final ready = await waitForTelnetReady(
        login: login,
        isAlive: () =>
            !_sessionDisposed && _connected && !_dropped && _execSocket != null,
        sawShellPrompt: () => shellReady,
      );
      if (_sessionDisposed || !_connected || _dropped) {
        await _closeSecondarySocket();
        return false;
      }
      if (!ready) {
        _lastExecError = 'Telnet 副连接登录超时，改用主会话';
        await _closeSecondarySocket();
        return false;
      }
      // 必须见到 shell 提示符；仅 injectComplete 不够（密码错误时也会 complete）。
      if (!shellReady) {
        _lastExecError = 'Telnet 副连接未进入 shell，改用主会话';
        await _closeSecondarySocket();
        return false;
      }

      _usePrimaryExec = false;
      _emulator = ShellExecEmulator(
        _TelnetShellBackend(
          (bytes) {
            final sock = _execSocket;
            if (sock == null) return;
            sock.add(TelnetNegotiator.escapeIac(bytes));
          },
          outCtrl,
        ),
        encoding: _codec,
      );
      _lastExecError = null;
      return true;
    } catch (e) {
      _lastExecError = 'Telnet 副连接失败，改用主会话：$e';
      await _closeSecondarySocket();
      return false;
    }
  }

  void _attachPrimaryEmulator() {
    if (_emulator != null) return;
    if (_socket == null || !_connected || _dropped) return;
    _usePrimaryExec = true;
    _emulator = ShellExecEmulator(
      _TelnetShellBackend(
        (bytes) {
          final sock = _socket;
          if (sock == null) return;
          sock.add(TelnetNegotiator.escapeIac(bytes));
        },
        _primaryExecFanout,
      ),
      encoding: _codec,
    );
    _lastExecError = null;
    debugPrint('telnet exec: using primary session fallback');
  }

  Future<void> _onSecondaryExecLost() async {
    if (_usePrimaryExec) {
      await _closeSecondarySocket();
      return;
    }
    await _emulator?.dispose();
    _emulator = null;
    await _closeSecondarySocket();
    if (_connected && !_dropped && !_sessionDisposed) {
      _attachPrimaryEmulator();
    }
  }

  Future<void> _closeSecondarySocket() async {
    await _execSub?.cancel();
    _execSub = null;
    try {
      await _execSocket?.close();
    } catch (_) {}
    try {
      _execSocket?.destroy();
    } catch (_) {}
    _execSocket = null;
  }

  Future<void> _closeExecBackend() async {
    await _emulator?.dispose();
    _emulator = null;
    _usePrimaryExec = false;
    await _closeSecondarySocket();
  }

  @override
  Future<String?> runQueued(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    List<int>? stdinBytes,
    bool allowInteractiveFallback = true,
  }) async {
    if (!_connected || _dropped) return null;
    // Already on primary: refuse when caller forbids interactive injection
    // (tray/metrics/LLM), otherwise probes keep eating the user's console.
    if (!allowInteractiveFallback && _usePrimaryExec) {
      _lastExecError = 'Telnet 正使用主终端 exec；已禁止再次注入以免干扰交互';
      return null;
    }
    try {
      try {
        await _ensureExecBackend(
          allowInteractiveFallback: allowInteractiveFallback,
        ).timeout(const Duration(seconds: 25));
      } on TimeoutException {
        if (allowInteractiveFallback && _emulator == null) {
          _attachPrimaryEmulator();
        }
        if (_emulator == null) {
          _lastExecError = allowInteractiveFallback
              ? 'Telnet exec 后端启动超时'
              : 'Telnet exec 后端启动超时（已禁止主终端 fallback）';
          return null;
        }
      }
      if (!allowInteractiveFallback && _usePrimaryExec) {
        _lastExecError = 'Telnet 无法建立独立 exec 会话；已禁止使用主终端执行以免干扰交互';
        return null;
      }
      final emu = _emulator;
      if (emu == null) {
        _lastExecError ??= allowInteractiveFallback
            ? 'Telnet exec 不可用'
            : 'Telnet 无法建立独立 exec 会话；已禁止使用主终端执行以免干扰交互';
        return null;
      }
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
  Future<String?> runRemoteForStatus(String command) =>
      runQueued(command, allowInteractiveFallback: false);

  @override
  String? get lastRemoteCommandError => _lastExecError ?? _emulator?.lastError;

  @override
  int? get lastRemoteExitCode => _emulator?.lastExitCode;

  @override
  bool get lightweightRemoteExec => true;

  @override
  bool get execSharesInteractiveSession => _usePrimaryExec;

  @override
  Future<RemoteStream> startRemoteStream(
    String command, {
    int maxLines = 5000,
    List<int>? stdinBytes,
  }) async {
    if (!_connected || _dropped) {
      throw StateError('Telnet 未连接');
    }
    await _ensureExecBackend();
    final emu = _emulator;
    if (emu == null) throw StateError('exec 后端不可用');
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
    final out = await runQueued(
      'pwd',
      timeout: const Duration(seconds: 3),
      allowInteractiveFallback: false,
    );
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
    if (!_connected || _dropped || _sessionDisposed) return null;
    final opened = await _openSocket();
    if (_sessionDisposed || !_connected || _dropped) {
      try {
        await opened.socket.close();
      } catch (_) {}
      try {
        opened.socket.destroy();
      } catch (_) {}
      return null;
    }
    final socket = opened.socket;
    final rawCtrl = StreamController<List<int>>();
    final rawSub = socket.listen(
      (data) {
        if (!rawCtrl.isClosed) rawCtrl.add(data);
      },
      onDone: () {
        if (!rawCtrl.isClosed) unawaited(rawCtrl.close());
      },
      onError: (Object e) {
        if (!rawCtrl.isClosed) rawCtrl.addError(e);
      },
    );
    return TelnetRemoteShell.open(
      input: rawCtrl.stream,
      output: (b) {
        try {
          socket.add(b);
        } catch (_) {}
      },
      closeSocket: () async {
        await rawSub.cancel();
        try {
          await socket.close();
        } catch (_) {}
        try {
          socket.destroy();
        } catch (_) {}
        if (!rawCtrl.isClosed) await rawCtrl.close();
      },
      settings: settings,
      encoding: encoding,
      username: username,
      password: _password,
      autoInjectCredentials: autoInjectCredentials,
      pendingBytes: opened.pendingBytes,
      cols: cols,
      rows: rows,
    );
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
    for (final s in List<RemoteStream>.from(_activeStreams)) {
      try {
        await s.stop();
      } catch (_) {}
    }
    _activeStreams.clear();
    await _closeExecBackend();
    await _socketSub?.cancel();
    _socketSub = null;
    _ptyInterceptor.reset();
    _mouseMode = false;
    try {
      await _socket?.close();
    } catch (_) {}
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
    _negotiator = null;
    _loginMatcher?.reset();
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
    if (!_execOutput.isClosed) unawaited(_execOutput.close());
    if (!_primaryExecFanout.isClosed) unawaited(_primaryExecFanout.close());
    super.dispose();
  }
}
