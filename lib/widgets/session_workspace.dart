import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../l10n/app_localizations.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';

/// 仅终端区域（右侧大面板），连接状态与 [SshWorkspaceController] 同步。
class SessionTerminalPane extends StatefulWidget {
  const SessionTerminalPane({
    super.key,
    required this.controller,
    required this.workbenchSettings,
    required this.autofocusTerminal,
  });

  final SshWorkspaceController controller;
  final WorkbenchSettingsStore workbenchSettings;
  final bool autofocusTerminal;

  @override
  State<SessionTerminalPane> createState() => _SessionTerminalPaneState();
}

class _SessionTerminalPaneState extends State<SessionTerminalPane> {
  late final TerminalController _viewController = TerminalController();
  Terminal? _terminalBound;
  Timer? _selectCopyDebounce;

  /// 终端视图句柄：用于读取 [RenderTerminal] 做选区延伸与坐标换算。
  final GlobalKey<TerminalViewState> _termViewKey = GlobalKey();

  /// 终端滚动控制器：传入 [TerminalView] 后可读取/编程滚动，配合边缘自动滚动。
  final ScrollController _termScroll = ScrollController();

  /// 鼠标主键拖选：起点（RenderTerminal 局部坐标）与起点时刻的滚动像素。
  /// 起点以像素保存，每次延伸时按「当前滚动 − 起点滚动」对 dy 反向补偿，
  /// 使 [RenderTerminal.getCellOffset] 始终落在原始缓冲区行，消除滚动漂移。
  Offset? _selDragStart;
  double _selDragStartScroll = 0;
  Offset _selLastLocal = Offset.zero;
  Timer? _autoScrollTimer;

  @override
  void initState() {
    super.initState();
    widget.workbenchSettings.addListener(_onWorkbenchSettingsChanged);
    widget.controller.addListener(_onControllerChanged);
    _syncTerminalBufferListener();
  }

  @override
  void dispose() {
    _selectCopyDebounce?.cancel();
    _autoScrollTimer?.cancel();
    _termScroll.dispose();
    _terminalBound?.removeListener(_onTerminalBufferChanged);
    widget.workbenchSettings.removeListener(_onWorkbenchSettingsChanged);
    widget.controller.removeListener(_onControllerChanged);
    _viewController.dispose();
    super.dispose();
  }

  void _onWorkbenchSettingsChanged() {
    if (mounted) setState(() {});
  }

  void _onControllerChanged() {
    _syncTerminalBufferListener();
    if (mounted) setState(() {});
  }

  void _syncTerminalBufferListener() {
    final t = widget.controller.terminal;
    if (identical(t, _terminalBound)) return;
    _terminalBound?.removeListener(_onTerminalBufferChanged);
    _terminalBound = t;
    _terminalBound?.addListener(_onTerminalBufferChanged);
  }

  void _onTerminalBufferChanged() {
    if (!widget.workbenchSettings.selectToCopy) return;
    final term = widget.controller.terminal;
    if (term == null) return;
    if (_viewController.selection == null) return;
    _selectCopyDebounce?.cancel();
    _selectCopyDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      final sel = _viewController.selection;
      if (sel == null) return;
      final text = term.buffer.getText(sel);
      if (text.isEmpty) return;
      unawaited(Clipboard.setData(ClipboardData(text: text)));
    });
  }

  // --- 鼠标拖选：起点锚定 + 边缘自动滚动，使选区可跨越滚动缓冲区 ---

  // RenderTerminal 未由 xterm 公开导出，这里以 dynamic 持有；调用方做空守卫。
  dynamic get _renderTerminal => _termViewKey.currentState?.renderTerminal;

  double _scrollPixels() =>
      _termScroll.hasClients ? _termScroll.position.pixels : 0.0;

  void _extendSelection() {
    final rt = _renderTerminal;
    final start = _selDragStart;
    if (rt == null || start == null) return;
    // 反向补偿：滚动后仍把起点映射回原始缓冲区行。
    final delta = _scrollPixels() - _selDragStartScroll;
    final adjustedFrom = Offset(start.dx, start.dy - delta);
    rt.selectCharacters(adjustedFrom, _selLastLocal);
  }

  static const double _kAutoScrollBand = 30.0;
  static const double _kAutoScrollMaxSpeed = 22.0; // px / tick

  /// 指针位于上下边缘带内时持续滚动并延伸选区；离开则停止。
  void _ensureAutoScroll() {
    final rt = _renderTerminal;
    if (rt == null) {
      _stopAutoScroll();
      return;
    }
    final h = rt.size.height;
    final dy = _selLastLocal.dy;
    if (dy >= _kAutoScrollBand && dy <= h - _kAutoScrollBand) {
      _stopAutoScroll();
      return;
    }
    if (_autoScrollTimer != null) return;
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _autoScrollTick();
    });
  }

  void _autoScrollTick() {
    final rt = _renderTerminal;
    if (rt == null || _selDragStart == null) {
      _stopAutoScroll();
      return;
    }
    final h = rt.size.height;
    final dy = _selLastLocal.dy;
    double dir;
    double depth;
    if (dy < _kAutoScrollBand) {
      dir = -1; // 向上滚动，回看历史
      depth = _kAutoScrollBand - dy;
    } else if (dy > h - _kAutoScrollBand) {
      dir = 1; // 向下滚动，回到实时
      depth = dy - (h - _kAutoScrollBand);
    } else {
      _stopAutoScroll();
      return;
    }
    final speed =
        (depth / _kAutoScrollBand).clamp(0.0, 1.0) * _kAutoScrollMaxSpeed;
    if (_termScroll.hasClients) {
      final pos = _termScroll.position;
      final next = (pos.pixels + dir * speed)
          .clamp(pos.minScrollExtent, pos.maxScrollExtent);
      if ((next - pos.pixels).abs() > 0) {
        pos.jumpTo(next);
      }
    }
    _extendSelection();
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  void _onTerminalPointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    if ((e.buttons & kPrimaryButton) == 0) return;
    final rt = _renderTerminal;
    if (rt == null) return;
    _selDragStart = rt.globalToLocal(e.position);
    _selDragStartScroll = _scrollPixels();
    _selLastLocal = _selDragStart!;
  }

  void _onTerminalPointerMove(PointerMoveEvent e) {
    final start = _selDragStart;
    if (start == null) return;
    if (e.kind != PointerDeviceKind.mouse) return;
    if ((e.buttons & kPrimaryButton) == 0) return;
    final rt = _renderTerminal;
    if (rt == null) return;
    _selLastLocal = rt.globalToLocal(e.position);
    _extendSelection();
    _ensureAutoScroll();
  }

  void _endDrag() {
    _selDragStart = null;
    _stopAutoScroll();
  }

  void _showTerminalContextMenu(BuildContext context, Offset globalPosition, Terminal term) {
    final l = AppLocalizations.of(context)!;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final topLeft = overlay.localToGlobal(Offset.zero);
    final rel = RelativeRect.fromLTRB(
      globalPosition.dx - topLeft.dx,
      globalPosition.dy - topLeft.dy,
      globalPosition.dx - topLeft.dx + 1,
      globalPosition.dy - topLeft.dy + 1,
    );
    final hasSelection = _viewController.selection != null;
    showMenu<String>(
      context: context,
      position: rel,
      color: context.wb.panelElevated,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: context.wb.border),
        borderRadius: BorderRadius.circular(8),
      ),
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: hasSelection,
          child: Text(l.terminalMenuCopy, style: TextStyle(color: context.wb.primaryText)),
        ),
        PopupMenuItem(
          value: 'paste',
          child: Text(l.terminalMenuPaste, style: TextStyle(color: context.wb.primaryText)),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'selectAll',
          child: Text(l.terminalMenuSelectAll, style: TextStyle(color: context.wb.primaryText)),
        ),
        PopupMenuItem(
          value: 'clearSelection',
          enabled: hasSelection,
          child: Text(l.terminalMenuClearSelection, style: TextStyle(color: context.wb.primaryText)),
        ),
      ],
    ).then((v) async {
      if (!mounted || v == null) return;
      if (v == 'copy') {
        final sel = _viewController.selection;
        if (sel == null) return;
        final text = term.buffer.getText(sel);
        if (text.isEmpty) return;
        await Clipboard.setData(ClipboardData(text: text));
      } else if (v == 'paste') {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text;
        if (text == null || text.isEmpty) return;
        term.paste(text);
        _viewController.clearSelection();
      } else if (v == 'selectAll') {
        _viewController.setSelection(
          term.buffer.createAnchor(0, term.buffer.height - term.viewHeight),
          term.buffer.createAnchor(term.viewWidth, term.buffer.height - 1),
          mode: SelectionMode.line,
        );
      } else if (v == 'clearSelection') {
        _viewController.clearSelection();
      }
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          final ws = widget.workbenchSettings;
          final l = AppLocalizations.of(context)!;
          final term = c.terminal;

          // 首次连接阶段（从未建起过终端）：沿用全屏占位。
          if (term == null) {
            if (c.connecting && !c.connected) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: context.wb.accentBlue),
                    const SizedBox(height: 16),
                    Text(
                      l.terminalConnecting,
                      style: TextStyle(color: context.wb.textMuted),
                    ),
                  ],
                ),
              );
            }
            if (!c.connected && (c.error != null && c.error!.isNotEmpty)) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Icon(Icons.error_outline_rounded, size: 40, color: Color(0xFFEF4444)),
                        const SizedBox(height: 12),
                        Text(l.terminalConnectionFailed, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: context.wb.primaryText)),
                        const SizedBox(height: 8),
                        SelectableText(
                          c.error!,
                          style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: context.wb.textMuted),
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: context.wb.accentBlue),
                          onPressed: () async {
                            await c.disconnect();
                            await c.connect();
                          },
                          child: Text(l.terminalRetry),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            return Center(
              child: Text(
                l.terminalWaiting,
                style: TextStyle(color: context.wb.textMuted),
              ),
            );
          }

          // 已有终端：以 TerminalView 为底座，未连接时叠加状态层。
          final textStyle = TerminalStyle(
            fontSize: ws.terminalFontSize,
            fontFamily: ws.terminalFontFamily,
          );

          final base = DecoratedBox(
            decoration: BoxDecoration(
              color: context.wb.terminalBg,
              border: Border(left: BorderSide(color: context.wb.border)),
            ),
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onTerminalPointerDown,
              onPointerMove: _onTerminalPointerMove,
              onPointerUp: (_) => _endDrag(),
              onPointerCancel: (_) => _endDrag(),
              child: TerminalView(
                term,
                key: _termViewKey,
                controller: _viewController,
                scrollController: _termScroll,
                theme: TerminalThemes.defaultTheme,
                textStyle: textStyle,
                autofocus: widget.autofocusTerminal,
                // macOS/desktop: TextInput + hardware keys can duplicate KeyDown and
                // trip HardwareKeyboard assertions; IME path is for mobile keyboards.
                hardwareKeyboardOnly: !kIsWeb,
                // 断开/重连中冻结输入，避免向已关闭的 shell 写入。
                readOnly: !c.connected,
                autoResize: true,
                onSecondaryTapDown: (_, _) {},
                onSecondaryTapUp: (details, _) =>
                    _showTerminalContextMenu(context, details.globalPosition, term),
              ),
            ),
          );

          if (c.connected) return base;

          // 未连接且持有终端：重连中 或 掉线等待恢复。
          //
          // AbsorbPointer 包住「终端底座」而非遮罩：遮罩自身（DecoratedBox）不可点，
          // 落在空白处的指针会穿透到 AbsorbPointer 被吸收，从而冻结已断开的终端；
          // 而遮罩里的「重新连接」按钮可正常接收点击。若反过来包遮罩，按钮会被吸收。
          final reconnecting = c.connecting;
          return Stack(
            children: [
              Positioned.fill(child: AbsorbPointer(child: base)),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.wb.terminalBg.withValues(alpha: 0.72),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (reconnecting) ...[
                              CircularProgressIndicator(color: context.wb.accentBlue),
                              const SizedBox(height: 12),
                              Text(
                                l.terminalReconnecting,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: context.wb.textMuted),
                              ),
                            ] else ...[
                              const Icon(
                                Icons.cloud_off_rounded,
                                size: 40,
                                color: Color(0xFFEF4444),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                l.terminalDisconnected,
                                textAlign: TextAlign.center,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(color: context.wb.primaryText),
                              ),
                              if (c.error != null && c.error!.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                SelectableText(
                                  c.error!,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: context.wb.textMuted,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 20),
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: context.wb.accentBlue,
                                ),
                                onPressed: () => unawaited(c.reconnect()),
                                icon: const Icon(Icons.refresh_rounded),
                                label: Text(l.terminalReconnect),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 兼容旧引用：与 [SessionTerminalPane] 相同。
typedef SessionWorkspace = SessionTerminalPane;
