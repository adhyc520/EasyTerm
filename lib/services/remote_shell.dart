import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:xterm/xterm.dart';

import 'workbench_settings_store.dart';

/// 一条独立 PTY + xterm [Terminal] + I/O 接线，供桌面多终端窗口使用。
class RemoteShell {
  RemoteShell._(this.session, this.terminal);

  final SSHSession session;
  final Terminal terminal;

  StreamSubscription<List<int>>? _out;
  StreamSubscription<List<int>>? _err;

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
    final shell = RemoteShell._(session, terminal);
    shell._out = session.stdout.listen(
      (d) => terminal.write(utf8.decode(d, allowMalformed: true)),
    );
    shell._err = session.stderr.listen(
      (d) => terminal.write(utf8.decode(d, allowMalformed: true)),
    );
    return shell;
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

  void resize(int w, int h, int pw, int ph) =>
      session.resizeTerminal(w, h, pw, ph);

  void paste(String s) => terminal.paste(s);

  Future<void> close() async {
    await _out?.cancel();
    await _err?.cancel();
    _out = null;
    _err = null;
    try {
      session.close();
    } catch (_) {}
  }
}
