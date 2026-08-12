import 'dart:async';

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        defaultTargetPlatform,
        kIsWeb,
        kDebugMode,
        debugPrint;
import 'package:xterm/xterm.dart';

import '../terminal_charset.dart';
import '../terminal_session_controller.dart';
import '../pty_interceptor.dart';
import '../workbench_settings_store.dart';
import 'telnet_login_matcher.dart';
import 'telnet_negotiator.dart';

/// Telnet secondary shell for desktop multi-terminal windows.
class TelnetRemoteShell extends SecondaryShell {
  TelnetRemoteShell._(
    this._socketDone,
    this.terminal,
    this._negotiator,
    this._interceptor,
  );

  final Future<void> Function() _socketDone;
  @override
  final Terminal terminal;
  final TelnetNegotiator _negotiator;
  final PtyInterceptor _interceptor;

  StreamSubscription<List<int>>? _out;
  bool _mouseMode = false;
  String _terminalCwd = '';
  bool _sawOsc7 = false;
  bool _closed = false;

  @override
  bool get mouseModeActive => _mouseMode;
  @override
  String get terminalCwd => _terminalCwd;
  @override
  bool get sawOsc7 => _sawOsc7;

  static Future<TelnetRemoteShell> open({
    required Stream<List<int>> input,
    required void Function(List<int> bytes) output,
    required Future<void> Function() closeSocket,
    required WorkbenchSettingsStore settings,
    TerminalEncoding encoding = TerminalEncoding.utf8,
    String username = '',
    String password = '',
    bool autoInjectCredentials = true,
    List<int> pendingBytes = const [],
    int? cols,
    int? rows,
  }) async {
    late final TelnetNegotiator negotiator;
    negotiator = TelnetNegotiator(
      send: (b) => output(b),
      terminalType: settings.terminalTermType,
    );

    final codec = encoding.codec;
    final login = TelnetLoginMatcher(
      username: username,
      password: password,
      enabled: autoInjectCredentials,
      encoding: codec,
    );
    late final TelnetRemoteShell shell;
    final interceptor = PtyInterceptor(
      onCwd: (cwd) {
        if (shell._terminalCwd == cwd && shell._sawOsc7) return;
        shell._terminalCwd = cwd;
        shell._sawOsc7 = true;
        shell.notifyListeners();
      },
      onMouseMode: (active) {
        if (shell._mouseMode == active) return;
        shell._mouseMode = active;
        shell.notifyListeners();
      },
    );

    final terminal = Terminal(
      maxLines: settings.terminalMaxLines,
      platform: _xtermPlatform(),
      onOutput: (d) {
        final raw = codec.encode(d);
        output(TelnetNegotiator.escapeIac(raw));
      },
      onResize: (w, h, pw, ph) => negotiator.sendNaws(w, h),
    );

    shell = TelnetRemoteShell._(
      closeSocket,
      terminal,
      negotiator,
      interceptor,
    );

    negotiator.startLocalOffers();
    if (cols != null && rows != null) {
      negotiator.sendNaws(cols, rows);
    }

    var shellReady = false;
    void handle(List<int> data) {
      final payload = negotiator.feed(data);
      if (payload.isEmpty) return;
      final decoded = codec.decode(payload);
      final inject = login.feedText(decoded);
      if (inject.isNotEmpty) {
        output(TelnetNegotiator.escapeIac(inject));
      }
      if (TelnetLoginMatcher.looksLikeShellPrompt(decoded)) {
        shellReady = true;
      }
      terminal.write(interceptor.process(decoded));
    }

    if (pendingBytes.isNotEmpty) {
      handle(pendingBytes);
    }
    shell._out = input.listen(
      handle,
      onError: (Object e) {
        if (kDebugMode) {
          debugPrint('TelnetRemoteShell error: $e');
        }
        unawaited(shell.close());
      },
      onDone: () {
        unawaited(shell.close());
      },
    );

    final ready = await waitForTelnetReady(
      login: login,
      isAlive: () => !shell._closed,
      sawShellPrompt: () => shellReady,
    );
    if (!ready || shell._closed) {
      await shell.close();
      throw StateError('Telnet 副终端登录超时');
    }

    debugAliveShells++;
    if (kDebugMode) {
      debugPrint('TelnetRemoteShell+ alive=$debugAliveShells');
    }
    return shell;
  }

  static int debugAliveShells = 0;

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
  void resize(int w, int h, int pw, int ph) => _negotiator.sendNaws(w, h);

  @override
  void paste(String s) => terminal.paste(s);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _out?.cancel();
    _out = null;
    _interceptor.reset();
    _mouseMode = false;
    try {
      await _socketDone();
    } catch (_) {}
    if (debugAliveShells > 0) {
      debugAliveShells--;
      if (kDebugMode) {
        debugPrint('TelnetRemoteShell- alive=$debugAliveShells');
      }
    }
    dispose();
  }
}
