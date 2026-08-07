import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../services/remote_process_list.dart';
import '../../services/remote_shell.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../services/workbench_settings_store.dart';
import '../../theme/workbench_theme.dart';
import '../../util/desktop_drop_paths.dart';
import '../../util/remote_shell_cd.dart';
import '../../widgets/terminal_surface.dart';
import '../desktop_window_manager.dart';

/// 桌面终端窗口内容。
///
/// - `args['usePrimary'] == true`：复用 [SshWorkspaceController.terminal]
/// - 否则：经 [RemoteShell.open] 开独立 PTY（关闭窗口时 dispose）
/// - `args['cwd']`：独立 shell 就绪后 `cd` 到该路径（文件管理器「打开终端」）
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
  final GlobalKey<TerminalSurfaceState> _surfaceKey =
      GlobalKey<TerminalSurfaceState>();
  RemoteShell? _shell;
  Object? _openError;
  bool _opening = false;
  bool _wasConnected = false;
  bool _wasFocused = false;
  int _seenFocusGeneration = -1;

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
    widget.wm.addListener(_onWm);
    widget.settings.addListener(_onSettings);
    if (!_usePrimary) {
      unawaited(_openShell());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncKeyboardFocus());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    widget.wm.removeListener(_onWm);
    widget.settings.removeListener(_onSettings);
    final shell = _shell;
    _shell = null;
    if (shell != null) {
      unawaited(shell.close());
    }
    super.dispose();
  }

  void _onSettings() {
    if (mounted) setState(() {});
  }

  Future<void> _bumpFont(double delta) async {
    final s = widget.settings;
    final next = (s.terminalFontSize + delta).clamp(6.0, 48.0);
    if (next == s.terminalFontSize) return;
    s.terminalFontSize = next;
    await s.persist();
  }

  Future<void> _resetFont() async {
    final s = widget.settings;
    if (s.terminalFontSize == 14) return;
    s.terminalFontSize = 14;
    await s.persist();
  }

  Future<void> _openInFiles() async {
    final fallback = () {
      final cwd = widget.window.args['cwd']?.toString().trim();
      if (cwd != null && cwd.isNotEmpty) return cwd;
      return widget.controller.remoteCwd;
    }();

    var path = fallback;
    if (widget.controller.connected && !widget.controller.dropped) {
      try {
        final raw = await widget.controller.runQueued(
          r'pwd 2>/dev/null || echo "$PWD"',
          timeout: const Duration(seconds: 2),
        );
        final line = raw
            ?.split(RegExp(r'[\r\n]+'))
            .map((s) => s.trim())
            .firstWhere((s) => s.isNotEmpty, orElse: () => '');
        if (line != null && line.startsWith('/')) {
          path = line;
        }
      } catch (_) {
        // best-effort; fall back to args / remoteCwd
      }
    }
    if (!mounted) return;
    widget.wm.open(DesktopAppType.files, args: {'cwd': path});
  }

  void _onWm() {
    if (!mounted) return;
    _syncKeyboardFocus();
  }

  void _syncKeyboardFocus() {
    final focused = widget.window.focused;
    final gen = widget.wm.focusGeneration;
    final gained = focused && !_wasFocused;
    final lost = !focused && _wasFocused;
    final reclaimed = focused && gen != _seenFocusGeneration;
    _wasFocused = focused;
    if (lost) {
      _surfaceKey.currentState?.releaseKeyboardFocus();
      return;
    }
    if (!gained && !reclaimed) return;
    _seenFocusGeneration = gen;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.window.focused) return;
      _surfaceKey.currentState?.requestKeyboardFocus();
    });
  }

  void _claimKeyboard() {
    _seenFocusGeneration = -1;
    _wasFocused = false;
    _syncKeyboardFocus();
  }

  void _onController() {
    if (!mounted) return;
    final c = widget.controller;
    final nowConnected = c.connected && !c.dropped;
    final wasConnected = _wasConnected;
    final hadTerm = _terminal != null;

    if (!_usePrimary) {
      // 掉线：关掉旧 PTY，避免重连后假在线
      if (!nowConnected && _shell != null) {
        final dead = _shell;
        _shell = null;
        unawaited(dead?.close());
      }
      // 重连成功或首次连上：自动重开独立 shell
      if (nowConnected && !wasConnected && _shell == null && !_opening) {
        unawaited(_openShell());
      }
    }

    _wasConnected = nowConnected;
    setState(() {});

    // 仅在 surface 首次出现或重连成功时夺回键盘，避免 SFTP 等通知反复抢焦点。
    if (!widget.window.focused || !nowConnected) return;
    if (hadTerm && wasConnected) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.window.focused || _terminal == null) return;
      _claimKeyboard();
    });
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
      unawaited(_cdToInitialCwd(shell));
      unawaited(_injectInitialCommand(shell));
      if (widget.window.focused) {
        _claimKeyboard();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _openError = e;
        _opening = false;
      });
    }
  }

  /// 短暂等待 shell 就绪后再 `cd`（stdout 已被 [RemoteShell] 订阅，不宜再听）。
  Future<void> _cdToInitialCwd(RemoteShell shell) async {
    final raw = widget.window.args['cwd']?.toString().trim();
    if (raw == null || raw.isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted || !identical(_shell, shell)) return;
    var os = RemoteOsKind.unknown;
    try {
      os = await detectRemoteOs(widget.controller);
    } catch (_) {}
    if (!mounted || !identical(_shell, shell)) return;
    // 路径形态兜底：检测失败时仍按盘符走 Windows 命令。
    if (os == RemoteOsKind.unknown &&
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw)) {
      os = RemoteOsKind.windows;
    }
    final cmd = remoteShellCdCommand(raw, os);
    shell.terminal.textInput('$cmd\r');
  }

  /// 包管理器 / 防火墙等：打开终端后注入待执行命令（不自动回车，避免误跑 sudo）。
  Future<void> _injectInitialCommand(RemoteShell shell) async {
    final raw = widget.window.args['inject']?.toString();
    if (raw == null || raw.isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted || !identical(_shell, shell)) return;
    shell.paste(raw);
  }

  Widget _buildSurface(Terminal term, {required bool connected}) {
    final c = widget.controller;
    final settings = widget.settings;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.equal, meta: true): () =>
            unawaited(_bumpFont(1)),
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () =>
            unawaited(_bumpFont(1)),
        const SingleActivator(LogicalKeyboardKey.add, meta: true): () =>
            unawaited(_bumpFont(1)),
        const SingleActivator(LogicalKeyboardKey.add, control: true): () =>
            unawaited(_bumpFont(1)),
        const SingleActivator(LogicalKeyboardKey.minus, meta: true): () =>
            unawaited(_bumpFont(-1)),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () =>
            unawaited(_bumpFont(-1)),
        const SingleActivator(LogicalKeyboardKey.digit0, meta: true): () =>
            unawaited(_resetFont()),
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): () =>
            unawaited(_resetFont()),
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: context.wb.panel,
            child: SizedBox(
              height: 32,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Text(
                    '字号 ${settings.terminalFontSize.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.wb.textMuted,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => unawaited(_openInFiles()),
                    child: const Text('在文件管理器打开'),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
          Expanded(
            child: DropTarget(
              onDragDone: (detail) {
                final paths = resolveDesktopDropPaths(detail);
                if (paths.isEmpty) return;
                final text = paths.join(' ');
                if (_usePrimary) {
                  c.pasteRemoteInput(text);
                } else {
                  _shell?.paste(text);
                }
              },
              child: TerminalSurface(
                key: _surfaceKey,
                terminal: term,
                connected: connected,
                connecting: c.connecting,
                autofocus: widget.window.focused,
                onReconnect:
                    c.dropped ? () => unawaited(c.reconnect()) : null,
                errorText: c.error,
                themeBg: context.wb.terminalBg,
                fontSize: settings.terminalFontSize,
                fontFamily: settings.terminalFontFamily,
                selectToCopy: settings.selectToCopy,
                showLeftBorder: false,
                tapRegionGroupId: widget.window.id,
                releaseFocusOnTapOutside: false,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final term = _terminal;

    if (_usePrimary) {
      if (term == null) {
        return _CenteredHint(text: c.connecting ? '正在连接…' : '终端尚未就绪');
      }
      return _buildSurface(term, connected: c.connected);
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

    return _buildSurface(term, connected: c.connected && !c.dropped);
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
