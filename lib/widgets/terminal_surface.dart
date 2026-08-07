import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show kPrimaryButton, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../l10n/app_localizations.dart';
import '../services/workbench_desktop_shortcuts.dart';
import '../theme/workbench_theme.dart';

/// 纯终端渲染 / 输入 / 选择 / 菜单 / 断线浮层，不依赖 [SshWorkspaceController]。
class TerminalSurface extends StatefulWidget {
  const TerminalSurface({
    super.key,
    required this.terminal,
    this.connected = true,
    this.connecting = false,
    this.autofocus = false,
    this.onReconnect,
    this.errorText,
    this.themeBg,
    this.fontSize = 13,
    this.fontFamily = 'Menlo',
    this.selectToCopy = false,
    this.showLeftBorder = true,
    this.tapRegionGroupId,
    this.releaseFocusOnTapOutside = true,
  });

  final Terminal terminal;
  final bool connected;
  final bool connecting;
  final bool autofocus;
  final VoidCallback? onReconnect;
  final String? errorText;
  final Color? themeBg;
  final double fontSize;
  final String fontFamily;
  final bool selectToCopy;
  final bool showLeftBorder;

  /// 与桌面窗口外框共用，避免点标题栏时丢掉键盘焦点。
  final Object? tapRegionGroupId;

  /// 点击终端区域外时是否释放键盘焦点（桌面窗口内通常关闭）。
  final bool releaseFocusOnTapOutside;

  @override
  State<TerminalSurface> createState() => TerminalSurfaceState();
}

class TerminalSurfaceState extends State<TerminalSurface> {
  late final TerminalController _viewController = TerminalController();
  Timer? _selectCopyDebounce;

  final GlobalKey<TerminalViewState> _termViewKey = GlobalKey();
  final FocusNode _termFocus = FocusNode(debugLabel: 'terminalSurface');
  final ScrollController _termScroll = ScrollController();

  CellOffset? _selStartCell;
  Offset _selLastLocal = Offset.zero;
  Timer? _autoScrollTimer;
  bool _selectionApplyScheduled = false;
  bool _selDidDrag = false;

  static TerminalTheme _workbenchTerminalTheme(Color terminalBg) {
    const base = TerminalThemes.defaultTheme;
    return TerminalTheme(
      cursor: base.cursor,
      selection: const Color(0xAA264F78),
      foreground: base.foreground,
      background: terminalBg,
      black: base.black,
      red: base.red,
      green: base.green,
      yellow: base.yellow,
      blue: base.blue,
      magenta: base.magenta,
      cyan: base.cyan,
      white: base.white,
      brightBlack: base.brightBlack,
      brightRed: base.brightRed,
      brightGreen: base.brightGreen,
      brightYellow: base.brightYellow,
      brightBlue: base.brightBlue,
      brightMagenta: base.brightMagenta,
      brightCyan: base.brightCyan,
      brightWhite: base.brightWhite,
      searchHitBackground: base.searchHitBackground,
      searchHitBackgroundCurrent: base.searchHitBackgroundCurrent,
      searchHitForeground: base.searchHitForeground,
    );
  }

  @override
  void initState() {
    super.initState();
    _termScroll.addListener(_onTermScrolled);
    widget.terminal.addListener(_onTerminalBufferChanged);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) requestKeyboardFocus();
      });
    }
  }

  /// 请求硬件键盘焦点（桌面窗口激活时调用）。
  void requestKeyboardFocus() {
    if (!mounted) return;
    // 始终 requestFocus：即便 hasFocus 为 true，也可能不是 primary focus。
    _termFocus.requestFocus();
  }

  /// 窗口失焦时释放硬件键盘，避免按键仍进 PTY 而桌面 TextField 无法输入。
  void releaseKeyboardFocus() {
    if (!mounted) return;
    _releaseKeyboardFocus();
  }

  @override
  void didUpdateWidget(covariant TerminalSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autofocus && !oldWidget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) requestKeyboardFocus();
      });
    }
    // xterm 在 readOnly 时不挂 Focus；连上后需重新夺取键盘。
    if (widget.connected && !oldWidget.connected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.connected) requestKeyboardFocus();
      });
    }
    if (!identical(oldWidget.terminal, widget.terminal)) {
      oldWidget.terminal.removeListener(_onTerminalBufferChanged);
      widget.terminal.addListener(_onTerminalBufferChanged);
    }
  }

  @override
  void dispose() {
    _selectCopyDebounce?.cancel();
    _autoScrollTimer?.cancel();
    _termScroll.removeListener(_onTermScrolled);
    _termScroll.dispose();
    _termFocus.dispose();
    widget.terminal.removeListener(_onTerminalBufferChanged);
    _viewController.dispose();
    super.dispose();
  }

  void _onTerminalBufferChanged() {
    if (!widget.selectToCopy) return;
    if (_viewController.selection == null) return;
    _selectCopyDebounce?.cancel();
    _selectCopyDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      final sel = _viewController.selection;
      if (sel == null) return;
      final text = widget.terminal.buffer.getText(sel);
      if (text.isEmpty) return;
      unawaited(Clipboard.setData(ClipboardData(text: text)));
    });
  }

  dynamic get _renderTerminal => _termViewKey.currentState?.renderTerminal;

  void _snapScrollToLineHeight() {
    if (_selStartCell == null || !_termScroll.hasClients) return;
    final rt = _renderTerminal;
    if (rt == null) return;
    final lineHeight = rt.lineHeight as double;
    if (lineHeight <= 0) return;
    final pos = _termScroll.position;
    final snapped = (pos.pixels / lineHeight).roundToDouble() * lineHeight;
    final clamped = snapped.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((clamped - pos.pixels).abs() > 0.5) {
      pos.jumpTo(clamped);
    }
  }

  void _applySelection() {
    final rt = _renderTerminal;
    final startCell = _selStartCell;
    if (rt == null || startCell == null) return;

    var endCell = rt.getCellOffset(_selLastLocal) as CellOffset;
    if (endCell.x >= startCell.x) {
      endCell = CellOffset(endCell.x + 1, endCell.y);
    }

    final existing = _viewController.selection;
    if (existing != null &&
        existing.begin.x == startCell.x &&
        existing.begin.y == startCell.y &&
        existing.end.x == endCell.x &&
        existing.end.y == endCell.y) {
      return;
    }

    final term = widget.terminal;
    _viewController.setSelection(
      term.buffer.createAnchorFromOffset(startCell),
      term.buffer.createAnchorFromOffset(endCell),
    );
  }

  void _scheduleApplySelection() {
    if (_selStartCell == null || !_selDidDrag || _selectionApplyScheduled) {
      return;
    }
    _selectionApplyScheduled = true;
    scheduleMicrotask(() {
      _selectionApplyScheduled = false;
      if (!mounted || _selStartCell == null || !_selDidDrag) return;
      _applySelection();
    });
  }

  void _onTermScrolled() {
    if (_selStartCell == null || !_selDidDrag) return;
    _snapScrollToLineHeight();
    _scheduleApplySelection();
  }

  static const double _kAutoScrollBand = 30.0;

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
    if (rt == null || _selStartCell == null) {
      _stopAutoScroll();
      return;
    }
    final h = rt.size.height;
    final dy = _selLastLocal.dy;
    final double dir;
    if (dy < _kAutoScrollBand) {
      dir = -1;
    } else if (dy > h - _kAutoScrollBand) {
      dir = 1;
    } else {
      _stopAutoScroll();
      return;
    }
    if (_termScroll.hasClients) {
      final pos = _termScroll.position;
      final lineHeight = rt.lineHeight as double;
      if (lineHeight > 0) {
        final next = (pos.pixels + dir * lineHeight).clamp(
          pos.minScrollExtent,
          pos.maxScrollExtent,
        );
        if ((next - pos.pixels).abs() > 0) {
          pos.jumpTo(next);
        }
      }
    }
    _scheduleApplySelection();
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  void _onTerminalPointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    if ((e.buttons & kPrimaryButton) == 0) return;
    // 任何点击都抢回 primary focus（窗口已聚焦但键盘被壳层/标题栏抢走时）。
    requestKeyboardFocus();
    final rt = _renderTerminal;
    if (rt == null) return;
    final local = rt.globalToLocal(e.position) as Offset;
    _selStartCell = rt.getCellOffset(local) as CellOffset;
    _selLastLocal = local;
    _selDidDrag = false;
  }

  void _onTerminalPointerMove(PointerMoveEvent e) {
    if (_selStartCell == null) return;
    if (e.kind != PointerDeviceKind.mouse) return;
    if ((e.buttons & kPrimaryButton) == 0) return;
    final rt = _renderTerminal;
    if (rt == null) return;
    _selLastLocal = rt.globalToLocal(e.position) as Offset;
    final endCell = rt.getCellOffset(_selLastLocal) as CellOffset;
    if (!_selDidDrag &&
        endCell.x == _selStartCell!.x &&
        endCell.y == _selStartCell!.y) {
      return;
    }
    _selDidDrag = true;
    _scheduleApplySelection();
    _ensureAutoScroll();
  }

  void _onTerminalPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (_selStartCell == null) return;
    _selDidDrag = true;
    _snapScrollToLineHeight();
    _scheduleApplySelection();
  }

  void _onTerminalPointerUp(PointerUpEvent e) {
    if (e.kind == PointerDeviceKind.mouse &&
        _selStartCell != null &&
        _selDidDrag) {
      _selectionApplyScheduled = false;
      _applySelection();
    }
    _endDrag();
  }

  void _endDrag() {
    _selStartCell = null;
    _selDidDrag = false;
    _stopAutoScroll();
  }

  void _releaseKeyboardFocus() {
    if (_termFocus.hasFocus) {
      _termFocus.unfocus();
    }
  }

  Widget _terminalTapRegion({required Widget child}) {
    if (!widget.releaseFocusOnTapOutside && widget.tapRegionGroupId == null) {
      return child;
    }
    return TapRegion(
      groupId: widget.tapRegionGroupId,
      onTapOutside: widget.releaseFocusOnTapOutside
          ? (_) => _releaseKeyboardFocus()
          : null,
      child: child,
    );
  }

  /// Windows/Linux：有选区时 Ctrl+C 复制到本地剪贴板，否则交给 PTY（SIGINT）。
  KeyEventResult _onTerminalKeyEvent(FocusNode node, KeyEvent event) {
    // 保持 Focus 挂载（readOnly:false）时，断线态吞掉按键，避免误发到已死 PTY。
    if (!widget.connected) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (workbenchUsesMetaPrimaryModifier()) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyC) {
      return KeyEventResult.ignored;
    }
    if (!HardwareKeyboard.instance.isControlPressed) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final sel = _viewController.selection;
    if (sel == null) return KeyEventResult.ignored;
    final text = widget.terminal.buffer.getText(sel);
    if (text.isEmpty) return KeyEventResult.ignored;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    return KeyEventResult.handled;
  }

  void _showTerminalContextMenu(
    BuildContext context,
    Offset globalPosition,
    Terminal term,
  ) {
    final l = AppLocalizations.of(context)!;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
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
          child: Text(
            l.terminalMenuCopy,
            style: TextStyle(color: context.wb.primaryText),
          ),
        ),
        PopupMenuItem(
          value: 'paste',
          child: Text(
            l.terminalMenuPaste,
            style: TextStyle(color: context.wb.primaryText),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'selectAll',
          child: Text(
            l.terminalMenuSelectAll,
            style: TextStyle(color: context.wb.primaryText),
          ),
        ),
        PopupMenuItem(
          value: 'clearSelection',
          enabled: hasSelection,
          child: Text(
            l.terminalMenuClearSelection,
            style: TextStyle(color: context.wb.primaryText),
          ),
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
    final l = AppLocalizations.of(context)!;
    final bg = widget.themeBg ?? context.wb.terminalBg;
    final textStyle = TerminalStyle(
      fontSize: widget.fontSize,
      fontFamily: widget.fontFamily,
      height: 1.0,
    );

    final base = _terminalTapRegion(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: bg,
          border: widget.showLeftBorder
              ? Border(left: BorderSide(color: context.wb.border))
              : null,
        ),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onTerminalPointerDown,
          onPointerMove: _onTerminalPointerMove,
          onPointerSignal: _onTerminalPointerSignal,
          onPointerUp: _onTerminalPointerUp,
          onPointerCancel: (_) => _endDrag(),
          child: TerminalView(
            widget.terminal,
            key: _termViewKey,
            controller: _viewController,
            focusNode: _termFocus,
            scrollController: _termScroll,
            theme: _workbenchTerminalTheme(bg),
            textStyle: textStyle,
            autofocus: widget.autofocus,
            hardwareKeyboardOnly: !kIsWeb,
            // 始终 false：xterm 在 readOnly 时不挂 CustomKeyboardListener/Focus，
            // 断线重连后 FocusNode 会游离，导致「点了也输不进去」。
            // 未连接时由 [_onTerminalKeyEvent] 吞键 + 外层 AbsorbPointer 挡指针。
            readOnly: false,
            autoResize: true,
            shortcuts: workbenchTerminalClipboardShortcuts(),
            onKeyEvent: _onTerminalKeyEvent,
            onSecondaryTapDown: (_, _) {},
            onSecondaryTapUp: (details, _) => _showTerminalContextMenu(
              context,
              details.globalPosition,
              widget.terminal,
            ),
          ),
        ),
      ),
    );

    if (widget.connected) return SizedBox.expand(child: base);

    final reconnecting = widget.connecting;
    return SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(child: AbsorbPointer(child: base)),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(color: bg.withValues(alpha: 0.72)),
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
                          CircularProgressIndicator(
                            color: context.wb.accentBlue,
                          ),
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
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: context.wb.primaryText),
                          ),
                          if (widget.errorText != null &&
                              widget.errorText!.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            SelectableText(
                              widget.errorText!,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: context.wb.textMuted,
                              ),
                            ),
                          ],
                          if (widget.onReconnect != null) ...[
                            const SizedBox(height: 20),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: context.wb.accentBlue,
                              ),
                              onPressed: widget.onReconnect,
                              icon: const Icon(Icons.refresh_rounded),
                              label: Text(l.terminalReconnect),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
