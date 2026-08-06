import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../services/remote_shell.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../services/workbench_settings_store.dart';
import '../../theme/workbench_theme.dart';
import '../../widgets/terminal_surface.dart';
import '../desktop_window_manager.dart';

/// 桌面终端窗口内容。
///
/// - `args['usePrimary'] == true`：复用 [SshWorkspaceController.terminal]
/// - 否则：经 [RemoteShell.open] 开独立 PTY（关闭窗口时 dispose）
class TerminalApp extends StatefulWidget {
  const TerminalApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
    required this.settings,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;
  final WorkbenchSettingsStore settings;

  @override
  State<TerminalApp> createState() => _TerminalAppState();
}

class _TerminalAppState extends State<TerminalApp> {
  RemoteShell? _shell;
  Object? _openError;
  bool _opening = false;
  bool _wasConnected = false;

  bool get _usePrimary => widget.window.args['usePrimary'] == true;

  Terminal? get _terminal {
    if (_usePrimary) return widget.controller.terminal;
    return _shell?.terminal;
  }

  @override
  void initState() {
    super.initState();
    _wasConnected = widget.controller.connected && !widget.controller.dropped;
    widget.controller.addListener(_onController);
    if (!_usePrimary) {
      unawaited(_openShell());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    final shell = _shell;
    _shell = null;
    if (shell != null) {
      unawaited(shell.close());
    }
    super.dispose();
  }

  void _onController() {
    if (!mounted) return;
    final c = widget.controller;
    final nowConnected = c.connected && !c.dropped;

    if (!_usePrimary) {
      // 掉线：关掉旧 PTY，避免重连后假在线
      if (!nowConnected && _shell != null) {
        final dead = _shell;
        _shell = null;
        unawaited(dead?.close());
      }
      // 重连成功或首次连上：自动重开独立 shell
      if (nowConnected && !_wasConnected && _shell == null && !_opening) {
        unawaited(_openShell());
      }
    }

    _wasConnected = nowConnected;
    setState(() {});
  }

  Future<void> _openShell({bool force = false}) async {
    if (_opening) return;
    if (!force && _shell != null) return;
    final client = widget.controller.clientForDesktop;
    if (client == null) {
      setState(() => _openError = '未连接');
      return;
    }
    if (force && _shell != null) {
      final old = _shell;
      _shell = null;
      unawaited(old?.close());
    }
    setState(() {
      _opening = true;
      _openError = null;
    });
    try {
      final shell = await widget.controller.openShell();
      if (!mounted) {
        await shell.close();
        return;
      }
      setState(() {
        _shell = shell;
        _opening = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _openError = e;
        _opening = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final term = _terminal;
    final settings = widget.settings;

    if (_usePrimary) {
      if (term == null) {
        return _CenteredHint(
          text: c.connecting ? '正在连接…' : '终端尚未就绪',
        );
      }
      return TerminalSurface(
        terminal: term,
        connected: c.connected,
        connecting: c.connecting,
        onReconnect: c.dropped ? () => unawaited(c.reconnect()) : null,
        errorText: c.error,
        themeBg: context.wb.terminalBg,
        fontSize: settings.terminalFontSize,
        fontFamily: settings.terminalFontFamily,
        selectToCopy: settings.selectToCopy,
        showLeftBorder: false,
      );
    }

    if (_opening) {
      return const _CenteredHint(text: '正在打开终端…', progress: true);
    }
    if (_openError != null) {
      return _CenteredHint(
        text: '打开终端失败：$_openError',
        actionLabel: '重试',
        onAction: () => unawaited(_openShell(force: true)),
      );
    }
    if (term == null) {
      return _CenteredHint(
        text: c.connected ? '准备中…' : '未连接',
        actionLabel: c.connected ? '打开' : null,
        onAction: c.connected ? () => unawaited(_openShell(force: true)) : null,
      );
    }

    return TerminalSurface(
      terminal: term,
      connected: c.connected && !c.dropped,
      connecting: c.connecting,
      onReconnect: c.dropped ? () => unawaited(c.reconnect()) : null,
      errorText: c.error,
      themeBg: context.wb.terminalBg,
      fontSize: settings.terminalFontSize,
      fontFamily: settings.terminalFontFamily,
      selectToCopy: settings.selectToCopy,
      showLeftBorder: false,
    );
  }
}

class _CenteredHint extends StatelessWidget {
  const _CenteredHint({
    required this.text,
    this.progress = false,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final bool progress;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return ColoredBox(
      color: wb.terminalBg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress) ...[
              CircularProgressIndicator(color: wb.accentBlue),
              const SizedBox(height: 12),
            ],
            Text(text, style: TextStyle(color: wb.textMuted)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
