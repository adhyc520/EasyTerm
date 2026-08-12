import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../services/remote_exec_capable.dart';
import '../../services/remote_process_list.dart';
import '../../services/terminal_session_controller.dart';
import '../../services/workbench_settings_store.dart';
import '../../theme/workbench_theme.dart';
import '../../util/desktop_drop_paths.dart';
import '../../util/remote_shell_cd.dart';
import '../../widgets/terminal_surface.dart';
import '../desktop_window_manager.dart';

/// 桌面终端窗口内容。
///
/// - `args['usePrimary'] == true`：复用主会话 [TerminalSessionController.terminal]
/// - 否则：经 [TerminalSessionController.openSecondaryShell] 开独立会话
/// - Serial 无副终端时强制主终端
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
  final TerminalSessionController controller;
  final WorkbenchSettingsStore settings;

  @override
  State<TerminalApp> createState() => _TerminalAppState();
}

class _TerminalAppState extends State<TerminalApp> {

  final GlobalKey<TerminalSurfaceState> _surfaceKey =
      GlobalKey<TerminalSurfaceState>();
  SecondaryShell? _shell;
  Object? _openError;
  bool _opening = false;
  bool _wasConnected = false;
  bool _wasFocused = false;
  int _seenFocusGeneration = -1;
  bool _forcePrimary = false;

  bool get _usePrimary =>
      _forcePrimary || widget.window.args['usePrimary'] == true;

  RemoteExecCapable? get _exec =>
      widget.controller is RemoteExecCapable
          ? widget.controller as RemoteExecCapable
          : null;

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
      shell.removeListener(_onShell);
      unawaited(shell.close());
    }
    super.dispose();
  }

  void _onSettings() {
    if (mounted) setState(() {});
  }

  void _onShell() {
    if (mounted) setState(() {});
  }

  bool get _mouseModeActive => _usePrimary
      ? widget.controller.mouseModeActive
      : (_shell?.mouseModeActive ?? false);

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
        dead?.removeListener(_onShell);
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
    if (!widget.controller.connected || widget.controller.dropped) {
      setState(() => _openError = '未连接');
      return;
    }
    if (force && _shell != null) {
      final old = _shell;
      _shell = null;
      old?.removeListener(_onShell);
      unawaited(old?.close());
    }
    setState(() {
      _opening = true;
      _openError = null;
    });
    try {
      final shell = await widget.controller.openSecondaryShell();
      if (!mounted) {
        await shell?.close();
        return;
      }
      if (shell == null) {
        // Serial / unsupported secondary shell → fall back to primary.
        setState(() {
          _forcePrimary = true;
          _opening = false;
          _openError = null;
        });
        unawaited(_applyArgsToPrimary());
        if (widget.window.focused) {
          _claimKeyboard();
        }
        return;
      }
      shell.addListener(_onShell);
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

  /// 短暂等待 shell 就绪后再 `cd`。
  Future<void> _cdToInitialCwd(SecondaryShell shell) async {
    final raw = widget.window.args['cwd']?.toString().trim();
    if (raw == null || raw.isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted || !identical(_shell, shell)) return;
    var os = RemoteOsKind.unknown;
    final exec = _exec;
    if (exec != null) {
      try {
        os = await detectRemoteOs(exec);
      } catch (_) {}
    }
    if (!mounted || !identical(_shell, shell)) return;
    // 路径形态兜底：检测失败时仍按盘符走 Windows 命令。
    if (os == RemoteOsKind.unknown &&
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw)) {
      os = RemoteOsKind.windows;
    }
    final cmd = remoteShellCdCommand(raw, os);
    shell.terminal.textInput('$cmd\r');
  }

  /// Serial 主终端回退：同样应用 cwd / inject（副终端不可用时）。
  Future<void> _applyArgsToPrimary() async {
    final cwd = widget.window.args['cwd']?.toString().trim();
    final inject = widget.window.args['inject']?.toString();
    if ((cwd == null || cwd.isEmpty) && (inject == null || inject.isEmpty)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted || !_forcePrimary) return;
    if (cwd != null && cwd.isNotEmpty) {
      var os = RemoteOsKind.unknown;
      final exec = _exec;
      if (exec != null) {
        try {
          os = await detectRemoteOs(exec);
        } catch (_) {}
      }
      if (!mounted || !_forcePrimary) return;
      if (os == RemoteOsKind.unknown &&
          RegExp(r'^[A-Za-z]:[\\/]').hasMatch(cwd)) {
        os = RemoteOsKind.windows;
      }
      widget.controller.pasteRemoteInputWithLineSubmit(
        remoteShellCdCommand(cwd, os),
      );
    }
    if (inject != null && inject.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!mounted || !_forcePrimary) return;
      widget.controller.pasteRemoteInput(inject);
    }
  }

  /// 包管理器 / 防火墙等：打开终端后注入待执行命令（不自动回车，避免误跑 sudo）。
  Future<void> _injectInitialCommand(SecondaryShell shell) async {
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
          uiScale: settings.uiScaleFactor,
          selectToCopy: settings.selectToCopy,
          mouseModeActive: _mouseModeActive,
          smartRightClick: settings.smartRightClick,
          showLeftBorder: false,
          tapRegionGroupId: widget.window.id,
          releaseFocusOnTapOutside: false,
          sessionRecorder: _usePrimary ? c.sessionRecorder : null,
          onToggleRecording:
              _usePrimary ? c.toggleSessionRecording : null,
          hostLabel: c.host,
        ),
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
