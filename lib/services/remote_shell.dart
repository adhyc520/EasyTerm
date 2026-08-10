import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart'
    show
        ChangeNotifier,
        TargetPlatform,
        defaultTargetPlatform,
        kIsWeb,
        kDebugMode,
        debugPrint;
import 'package:xterm/xterm.dart';

import 'pty_interceptor.dart';
import 'workbench_settings_store.dart';

/// 一条独立 PTY + xterm [Terminal] + I/O 接线，供桌面多终端窗口使用。
class RemoteShell extends ChangeNotifier {
  RemoteShell._(this.session, this.terminal, this._interceptor);

  final SSHSession session;
  final Terminal terminal;
  final PtyInterceptor _interceptor;

  StreamSubscription<List<int>>? _out;
  StreamSubscription<List<int>>? _err;

  bool _mouseMode = false;
  String _terminalCwd = '';
  bool _sawOsc7 = false;

  bool get mouseModeActive => _mouseMode;
  String get terminalCwd => _terminalCwd;
  bool get sawOsc7 => _sawOsc7;

  static Future<RemoteShell> open(
    SSHClient client, {
    required WorkbenchSettingsStore settings,
    int? cols,
    int? rows,
  }) async {
    final session = await client.shell(
      pty: SSHPtyConfig(
        type: settings.terminalTermType,
        width: cols ?? settings.ptyDefaultColumns,
        height: rows ?? settings.ptyDefaultRows,
      ),
    );
    final terminal = Terminal(
      maxLines: settings.terminalMaxLines,
      platform: _xtermPlatform(),
      onOutput: (d) => session.write(Uint8List.fromList(utf8.encode(d))),
      onResize: (w, h, pw, ph) => session.resizeTerminal(w, h, pw, ph),
    );

    late final RemoteShell shell;
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
    shell = RemoteShell._(session, terminal, interceptor);

    void feed(List<int> d) {
      final decoded = utf8.decode(d, allowMalformed: true);
      terminal.write(interceptor.process(decoded));
    }

    shell._out = session.stdout.listen(feed);
    shell._err = session.stderr.listen(feed);
    debugAliveShells++;
    if (kDebugMode) {
      debugPrint('RemoteShell+ alive=$debugAliveShells');
    }
    return shell;
  }

  /// debug：当前未 close 的桌面 PTY 数。
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

  void resize(int w, int h, int pw, int ph) =>
      session.resizeTerminal(w, h, pw, ph);

  void paste(String s) => terminal.paste(s);

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _out?.cancel();
    await _err?.cancel();
    _out = null;
    _err = null;
    _interceptor.reset();
    _mouseMode = false;
    try {
      session.close();
    } catch (_) {}
    if (debugAliveShells > 0) {
      debugAliveShells--;
      if (kDebugMode) {
        debugPrint('RemoteShell- alive=$debugAliveShells');
      }
    }
    dispose();
  }
}
