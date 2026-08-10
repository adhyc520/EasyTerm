import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show kPrimaryButton, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../l10n/app_localizations.dart';
import '../services/workbench_desktop_shortcuts.dart';
import '../services/workbench_settings_store.dart';
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
    this.fontFamily,
    this.uiScale = 1.0,
    this.selectToCopy = false,
    this.mouseModeActive = false,
    this.smartRightClick = false,
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
  final String? fontFamily;

  /// Multiplier applied to [fontSize] (UI scale factor).
  final double uiScale;

  final bool selectToCopy;

  /// When true (app enabled mouse reporting), only Shift+drag selects locally.
  final bool mouseModeActive;

  /// Windows-style: secondary click copies+clears selection, or pastes.
  final bool smartRightClick;

  final bool showLeftBorder;

  /// 与桌面窗口外框共用，避免点标题栏时丢掉键盘焦点。
  final Object? tapRegionGroupId;

  /// 点击终端区域外时是否释放键盘焦点（桌面窗口内通常关闭）。
  final bool releaseFocusOnTapOutside;

  @override
  State<TerminalSurface> createState() => TerminalSurfaceState();
}

class TerminalSurfaceState extends State<TerminalSurface>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
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

  double? _lastDpr;

  /// 用户滚离底部时显示「跳最新」。
  bool _awayFromBottom = false;
  late final AnimationController _jumpPulse;
  static const double _kBottomSlack = 24;

  // --- Find (Cmd/Ctrl+F); xterm 4.0 has no search API — scan getText + select. ---
  bool _findOpen = false;
  final TextEditingController _findCtrl = TextEditingController();
  final FocusNode _findFocus = FocusNode(debugLabel: 'terminalFind');
  List<int> _findHits = const [];
  int _findIndex = -1;

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
    WidgetsBinding.instance.addObserver(this);
    _jumpPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _termScroll.addListener(_onTermScrolled);
    widget.terminal.addListener(_onTerminalBufferChanged);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) requestKeyboardFocus();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lastDpr ??= MediaQuery.devicePixelRatioOf(context);
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (_lastDpr != null && dpr != _lastDpr) {
      _lastDpr = dpr;
      // Force a layout pass so TerminalView autoResize recalculates cols/rows.
      setState(() {});
    } else {
      _lastDpr = dpr;
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
    WidgetsBinding.instance.removeObserver(this);
    _selectCopyDebounce?.cancel();
    _autoScrollTimer?.cancel();
    _jumpPulse.dispose();
    _termScroll.removeListener(_onTermScrolled);
    _termScroll.dispose();
    _termFocus.dispose();
    _findCtrl.dispose();
    _findFocus.dispose();
    widget.terminal.removeListener(_onTerminalBufferChanged);
    _viewController.dispose();
    super.dispose();
  }

  /// Opens the find bar and focuses the query field.
  void openFind() {
    setState(() => _findOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _findFocus.requestFocus();
      _findCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _findCtrl.text.length,
      );
    });
  }

  void _closeFind() {
    if (!_findOpen) return;
    setState(() => _findOpen = false);
    _viewController.clearSelection();
    requestKeyboardFocus();
  }

  void _rebuildFindHits() {
    final q = _findCtrl.text;
    if (q.isEmpty) {
      _findHits = const [];
      _findIndex = -1;
      return;
    }
    final text = widget.terminal.buffer.getText();
    final lower = text.toLowerCase();
    final needle = q.toLowerCase();
    final hits = <int>[];
    var from = 0;
    while (true) {
      final i = lower.indexOf(needle, from);
      if (i < 0) break;
      hits.add(i);
      from = i + 1;
    }
    _findHits = hits;
    _findIndex = hits.isEmpty ? -1 : 0;
  }

  /// Walks buffer the same way [Buffer.getText] emits chars; maps a char
  /// index range to cell anchors for selection highlight.
  (CellOffset?, CellOffset?) _cellsForCharRange(int start, int length) {
    if (length <= 0) return (null, null);
    final buf = widget.terminal.buffer;
    if (buf.height <= 0 || buf.viewWidth <= 0) return (null, null);
    final range = BufferRangeLine(
      CellOffset(0, 0),
      CellOffset(buf.viewWidth - 1, buf.height - 1),
    );
    CellOffset? begin;
    CellOffset? end;
    var index = 0;
    final endExclusive = start + length;

    for (final segment in range.toSegments()) {
      if (segment.line < 0 || segment.line >= buf.height) continue;
      final line = buf.lines[segment.line];
      if (!(segment.line == range.begin.y ||
          segment.line == 0 ||
          line.isWrapped)) {
        index++; // getText inserts '\n'
      }
      final from = segment.start ?? 0;
      var to = segment.end;
      if (to == null || to > line.length) to = line.length;
      for (var x = from; x < to; x++) {
        final codePoint = line.getCodePoint(x);
        final width = line.getWidth(x);
        if (codePoint == 0 || x + width > to) continue;
        if (index == start) begin = CellOffset(x, segment.line);
        if (index == endExclusive - 1) {
          end = CellOffset(x + width, segment.line);
        }
        index++;
        if (begin != null && end != null && index >= endExclusive) {
          return (begin, end);
        }
      }
    }
    return (begin, end);
  }

  void _selectFindHit() {
    if (_findIndex < 0 || _findIndex >= _findHits.length) {
      _viewController.clearSelection();
      return;
    }
    final start = _findHits[_findIndex];
    final len = _findCtrl.text.length;
    final (begin, end) = _cellsForCharRange(start, len);
    if (begin == null || end == null) {
      // Fallback: approximate line from flat offset / cols.
      final cols = widget.terminal.viewWidth;
      if (cols <= 0) return;
      final line = (start ~/ cols).clamp(0, widget.terminal.buffer.height - 1);
      final col = start % cols;
      final endCol = (col + len).clamp(0, cols);
      final term = widget.terminal;
      _viewController.setSelection(
        term.buffer.createAnchor(col, line),
        term.buffer.createAnchor(endCol, line),
      );
      _scrollToBufferLine(line);
      return;
    }
    final term = widget.terminal;
    _viewController.setSelection(
      term.buffer.createAnchorFromOffset(begin),
      term.buffer.createAnchorFromOffset(end),
    );
    _scrollToBufferLine(begin.y);
  }

  void _scrollToBufferLine(int line) {
    if (!_termScroll.hasClients) return;
    final rt = _renderTerminal;
    final lineHeight = (rt?.lineHeight as double?) ?? 0;
    if (lineHeight <= 0) return;
    final pos = _termScroll.position;
    final targetTop = line * lineHeight;
    final viewH = pos.viewportDimension;
    final lo = pos.pixels;
    final hi = pos.pixels + viewH;
    if (targetTop >= lo && targetTop + lineHeight <= hi) return;
    final jump = (targetTop - viewH * 0.3).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    pos.jumpTo(jump);
  }

  void _findNext({bool reverse = false}) {
    final wasEmpty = _findHits.isEmpty;
    if (wasEmpty) _rebuildFindHits();
    if (_findHits.isEmpty) {
      setState(() {});
      _viewController.clearSelection();
      return;
    }
    setState(() {
      if (wasEmpty) {
        // Keep index 0 from rebuild.
      } else if (reverse) {
        _findIndex = (_findIndex - 1 + _findHits.length) % _findHits.length;
      } else {
        _findIndex = (_findIndex + 1) % _findHits.length;
      }
    });
    _selectFindHit();
  }

  void _onFindQueryChanged(String _) {
    _rebuildFindHits();
    setState(() {});
    _selectFindHit();
  }

  void _onTerminalBufferChanged() {
    if (_awayFromBottom && mounted) {
      _jumpPulse.forward(from: 0);
    }
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
    _updateAwayFromBottom();
    if (_selStartCell == null || !_selDidDrag) return;
    _snapScrollToLineHeight();
    _scheduleApplySelection();
  }

  void _updateAwayFromBottom() {
    if (!_termScroll.hasClients) return;
    final pos = _termScroll.position;
    final away = pos.maxScrollExtent > 0 &&
        pos.pixels < pos.maxScrollExtent - _kBottomSlack;
    if (away != _awayFromBottom && mounted) {
      setState(() => _awayFromBottom = away);
      if (!away) _jumpPulse.value = 0;
    }
  }

  void _jumpToLatest() {
    if (!_termScroll.hasClients) return;
    final pos = _termScroll.position;
    pos.jumpTo(pos.maxScrollExtent);
    if (_awayFromBottom) {
      setState(() => _awayFromBottom = false);
    }
    _jumpPulse.value = 0;
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

  void _copySelectionNow() {
    final sel = _viewController.selection;
    if (sel == null) return;
    final text = widget.terminal.buffer.getText(sel);
    if (text.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
  }

  void _onTerminalPointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    if ((e.buttons & kPrimaryButton) == 0) return;

    final shift = HardwareKeyboard.instance.isShiftPressed;
    final mouseMode = widget.mouseModeActive;

    // In mouse-reporting mode, only Shift starts a local selection.
    // (_LiveShiftAbsorbPointer already keeps TerminalView out of the hit path
    // while Shift is held, so this down is local-only.)
    if (mouseMode && !shift) {
      _selStartCell = null;
      _selDidDrag = false;
      return;
    }

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
      if (widget.selectToCopy) {
        _copySelectionNow();
      }
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

  Future<void> _smartSecondaryAction(Terminal term) async {
    final sel = _viewController.selection;
    if (sel != null) {
      final text = term.buffer.getText(sel);
      if (text.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: text));
      }
      _viewController.clearSelection();
      if (mounted) setState(() {});
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    term.paste(text);
  }

  void _showTerminalContextMenu(
    BuildContext context,
    Offset globalPosition,
    Terminal term,
  ) {
    if (widget.smartRightClick) {
      unawaited(_smartSecondaryAction(term));
      return;
    }
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
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'clearBuffer',
          child: Text(
            '清空缓冲区',
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
      } else if (v == 'clearBuffer') {
        term.eraseScrollbackOnly();
        term.eraseDisplay();
        _viewController.clearSelection();
      }
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final bg = widget.themeBg ?? context.wb.terminalBg;
    final effectiveFontSize = widget.fontSize * widget.uiScale;
    final textStyle = TerminalStyle(
      fontSize: effectiveFontSize,
      fontFamily:
          widget.fontFamily ?? WorkbenchSettingsStore.platformDefaultFontFamily,
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
          child: _LiveShiftAbsorbPointer(
            mouseModeActive: widget.mouseModeActive,
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
      ),
    );

    final withJump = Stack(
      children: [
        Positioned.fill(child: base),
        if (_awayFromBottom)
          Positioned(
            right: 12,
            bottom: 12,
            child: AnimatedBuilder(
              animation: _jumpPulse,
              builder: (context, child) {
                final t = Curves.easeOut.transform(_jumpPulse.value);
                final glow = Color.lerp(
                  context.wb.accentBlue,
                  const Color(0xFF60A5FA),
                  t,
                )!;
                return Material(
                  color: Color.lerp(
                    context.wb.panelElevated,
                    glow.withValues(alpha: 0.35),
                    t * 0.55,
                  ),
                  elevation: 2 + t * 2,
                  borderRadius: BorderRadius.circular(20),
                  child: child,
                );
              },
              child: InkWell(
                onTap: _jumpToLatest,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.arrow_downward_rounded,
                        size: 16,
                        color: context.wb.accentBlue,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '跳最新',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: context.wb.primaryText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    final withFind = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_findOpen) _buildFindBar(context),
        Expanded(child: withJump),
      ],
    );

    final shortcuts = <ShortcutActivator, VoidCallback>{
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyF),
        openFind,
      ),
      if (_findOpen)
        const SingleActivator(LogicalKeyboardKey.escape): _closeFind,
    };

    Widget body = CallbackShortcuts(
      bindings: shortcuts,
      child: withFind,
    );

    if (widget.connected) return SizedBox.expand(child: body);

    final reconnecting = widget.connecting;
    return SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(child: AbsorbPointer(child: body)),
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

  Widget _buildFindBar(BuildContext context) {
    final wb = context.wb;
    return Material(
      color: wb.panelElevated,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(
                    LogicalKeyboardKey.enter,
                    shift: true,
                  ): () => _findNext(reverse: true),
                  const SingleActivator(
                    LogicalKeyboardKey.numpadEnter,
                    shift: true,
                  ): () => _findNext(reverse: true),
                },
                child: TextField(
                  controller: _findCtrl,
                  focusNode: _findFocus,
                  autofocus: true,
                  style: TextStyle(fontSize: 13, color: wb.primaryText),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '查找',
                    hintStyle: TextStyle(color: wb.textMuted),
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  onChanged: _onFindQueryChanged,
                  onSubmitted: (_) => _findNext(),
                ),
              ),
            ),
            IconButton(
              tooltip: '上一个',
              iconSize: 18,
              onPressed: () => _findNext(reverse: true),
              icon: Icon(Icons.keyboard_arrow_up, color: wb.textMuted),
            ),
            IconButton(
              tooltip: '下一个',
              iconSize: 18,
              onPressed: () => _findNext(),
              icon: Icon(Icons.keyboard_arrow_down, color: wb.textMuted),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                _findHits.isEmpty
                    ? (_findCtrl.text.isEmpty ? '' : '无匹配')
                    : '${_findIndex + 1}/${_findHits.length}',
                style: TextStyle(fontSize: 11, color: wb.textMuted),
              ),
            ),
            IconButton(
              iconSize: 18,
              onPressed: _closeFind,
              icon: Icon(Icons.close, color: wb.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Like [AbsorbPointer], but decides absorbing at hit-test time from live
/// Shift + [mouseModeActive] so the first Shift+click never reaches the PTY.
class _LiveShiftAbsorbPointer extends SingleChildRenderObjectWidget {
  const _LiveShiftAbsorbPointer({
    required this.mouseModeActive,
    required super.child,
  });

  final bool mouseModeActive;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderLiveShiftAbsorb(mouseModeActive: mouseModeActive);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLiveShiftAbsorb renderObject,
  ) {
    renderObject.mouseModeActive = mouseModeActive;
  }
}

class _RenderLiveShiftAbsorb extends RenderProxyBox {
  _RenderLiveShiftAbsorb({required bool mouseModeActive})
      : _mouseModeActive = mouseModeActive;

  bool _mouseModeActive;
  set mouseModeActive(bool value) {
    if (_mouseModeActive == value) return;
    _mouseModeActive = value;
  }

  bool get _absorbing =>
      _mouseModeActive && HardwareKeyboard.instance.isShiftPressed;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Match [RenderAbsorbPointer]: when absorbing, claim the hit without
    // testing children so TerminalView never sees the pointer.
    return _absorbing
        ? size.contains(position)
        : super.hitTest(result, position: position);
  }
}
