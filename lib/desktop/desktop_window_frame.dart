import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/workbench_theme.dart';
import '../util/desktop_resize_cursors.dart';
import 'desktop_app_registry.dart';
import 'desktop_window_manager.dart';

/// 桌面窗口外框：标题栏拖动 / 双击最大化 / 8 向缩放 / 聚焦高亮。
class DesktopWindowFrame extends StatelessWidget {
  const DesktopWindowFrame({
    super.key,
    required this.window,
    required this.wm,
    required this.child,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final Widget child;

  static const double titleBarH = DesktopWindowManager.titleBarH;

  /// 边/角手柄厚度。内容区按同值内缩，避免与 Scrollable / 终端 / WebView 叠层抢命中。
  /// （父级 Positioned 外溢区域无法命中，故手柄必须落在窗口矩形内。）
  static const double handle = 10;

  IconData _iconFor(DesktopAppType type) => iconForApp(type);

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final focused = window.focused;
    final borderColor = focused ? wb.accentBlue : wb.border;
    final isMax = window.state == WindowState.maximized;

    final radius = BorderRadius.circular(isMax ? 0 : 8);

    // 手柄在 ClipRRect 外；内容按 handle 内缩，手柄落在边框带上。
    // 缩放用 Listener 而非 Pan，避免与终端选择/列表滚动抢手势。
    // TapRegion groupId 与窗口内容（如终端）共用，避免点标题栏丢掉键盘焦点。
    // 用 Listener.onPointerDown 置顶：不参与手势竞技场，点选文件行 / 开始拖拽
    // 时子 InkWell 抢到手势也能抬起窗口（GestureDetector.onTap 会被子控件吃掉）。
    return TapRegion(
      groupId: window.id,
      child: FocusScope(
        node: window.focusScope,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            // 延迟抬层，避免与当前指针事件的 mouse_tracker 重叠。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              wm.focus(window.id, reclaimKeyboard: !window.focused);
            });
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: wb.panel,
                  borderRadius: radius,
                  border: Border.all(
                    color: borderColor,
                    width: focused ? 1.5 : 1,
                  ),
                  boxShadow: focused
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.22),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                ),
                child: ClipRRect(
                  borderRadius: radius,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TitleBar(
                        height: titleBarH,
                        icon: _iconFor(window.type),
                        title: window.title,
                        focused: focused,
                        maximized: isMax,
                        alwaysOnTop: window.alwaysOnTop,
                        workspaceCount: wm.workspaces.length,
                        onPanStart: () {
                          // 勿在指针回调里同步抬 z：Stack 重排会销毁/重建 MouseRegion。
                          wm.beginDrag(window.id);
                        },
                        onPanUpdate: (d) {
                          wm.dragBy(window.id, d);
                        },
                        onPanEnd: () => wm.endDrag(window.id),
                        onDoubleTap: () => wm.toggleMaximize(window.id),
                        onMinimize: () => wm.minimize(window.id),
                        onMaximize: () => wm.toggleMaximize(window.id),
                        onClose: () => unawaited(wm.requestClose(window.id)),
                        onFocus: () => wm.focus(window.id),
                        onTile: (zone) => wm.tile(window.id, zone),
                        onToggleAlwaysOnTop: () =>
                            wm.toggleAlwaysOnTop(window.id),
                        onMoveToWorkspace: (i) =>
                            wm.moveWindowToWorkspace(window.id, i),
                        onSnapLayout: (zone) => wm.tile(window.id, zone),
                      ),
                      Expanded(
                        child: ColoredBox(
                          color: wb.bg,
                          // 与手柄同宽的内边距：手柄落在空白边框带上，不与内容抢指针。
                          child: isMax
                              ? child
                              : Padding(
                                  padding: const EdgeInsets.only(
                                    left: handle,
                                    right: handle,
                                    bottom: handle,
                                  ),
                                  child: child,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!isMax) ..._resizeHandles(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _resizeHandles() {
    Widget grip({
      required ResizeEdge e,
      required MouseCursor cursor,
      double? left,
      double? right,
      double? top,
      double? bottom,
      double? width,
      double? height,
    }) {
      return Positioned(
        left: left,
        right: right,
        top: top,
        bottom: bottom,
        width: width,
        height: height,
        child: _ResizeGrip(
          cursor: cursor,
          enableCursor: !wm.pointerGeometryActive,
          onStart: () {
            wm.beginResize(window.id);
          },
          onUpdate: (delta) => wm.resizeBy(window.id, e, delta),
          onEnd: () => wm.endResize(window.id),
        ),
      );
    }

    const t = handle;
    return [
      grip(
        e: ResizeEdge.left,
        cursor: SystemMouseCursors.resizeLeftRight,
        left: 0,
        top: t,
        bottom: t,
        width: t,
      ),
      grip(
        e: ResizeEdge.right,
        cursor: SystemMouseCursors.resizeLeftRight,
        right: 0,
        top: t,
        bottom: t,
        width: t,
      ),
      grip(
        e: ResizeEdge.top,
        cursor: SystemMouseCursors.resizeUpDown,
        top: 0,
        left: t,
        right: t,
        height: t,
      ),
      grip(
        e: ResizeEdge.bottom,
        cursor: SystemMouseCursors.resizeUpDown,
        bottom: 0,
        left: t,
        right: t,
        height: t,
      ),
      grip(
        e: ResizeEdge.topLeft,
        cursor: DesktopResizeCursors.upLeftDownRight,
        left: 0,
        top: 0,
        width: t,
        height: t,
      ),
      grip(
        e: ResizeEdge.topRight,
        cursor: DesktopResizeCursors.upRightDownLeft,
        right: 0,
        top: 0,
        width: t,
        height: t,
      ),
      grip(
        e: ResizeEdge.bottomLeft,
        cursor: DesktopResizeCursors.upRightDownLeft,
        left: 0,
        bottom: 0,
        width: t,
        height: t,
      ),
      grip(
        e: ResizeEdge.bottomRight,
        cursor: DesktopResizeCursors.upLeftDownRight,
        right: 0,
        bottom: 0,
        width: t,
        height: t,
      ),
    ];
  }
}

/// 用 [Listener] 直接吃指针事件，避开与内容区 Scrollable / 选择拖拽的手势竞技场。
class _ResizeGrip extends StatefulWidget {
  const _ResizeGrip({
    required this.cursor,
    required this.enableCursor,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final MouseCursor cursor;
  final bool enableCursor;
  final VoidCallback onStart;
  final void Function(Offset delta) onUpdate;
  final VoidCallback onEnd;

  @override
  State<_ResizeGrip> createState() => _ResizeGripState();
}

class _ResizeGripState extends State<_ResizeGrip> {
  int? _activePointer;
  Offset? _lastGlobal;

  void _end(int pointer) {
    if (_activePointer != pointer) return;
    _activePointer = null;
    _lastGlobal = null;
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final listener = Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if ((e.buttons & kPrimaryButton) == 0) return;
        _activePointer = e.pointer;
        _lastGlobal = e.position;
        // 先去掉本握点的 MouseRegion，再通知父级进入缩放，减少 annotation 抖动。
        setState(() {});
        widget.onStart();
      },
      onPointerMove: (e) {
        if (_activePointer != e.pointer || _lastGlobal == null) return;
        final delta = e.position - _lastGlobal!;
        _lastGlobal = e.position;
        if (delta != Offset.zero) widget.onUpdate(delta);
      },
      onPointerUp: (e) => _end(e.pointer),
      onPointerCancel: (e) => _end(e.pointer),
      child: const ColoredBox(color: Color(0x00000000)),
    );

    // 拖动/缩放进行中：不挂 MouseRegion，避免窗口几何变化时 cursor annotation 重入。
    if (!widget.enableCursor || _activePointer != null) {
      return listener;
    }
    return MouseRegion(
      cursor: widget.cursor,
      child: listener,
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.height,
    required this.icon,
    required this.title,
    required this.focused,
    required this.maximized,
    required this.alwaysOnTop,
    required this.workspaceCount,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onDoubleTap,
    required this.onMinimize,
    required this.onMaximize,
    required this.onClose,
    required this.onFocus,
    required this.onTile,
    required this.onToggleAlwaysOnTop,
    required this.onMoveToWorkspace,
    required this.onSnapLayout,
  });

  final double height;
  final IconData icon;
  final String title;
  final bool focused;
  final bool maximized;
  final bool alwaysOnTop;
  final int workspaceCount;
  final VoidCallback onPanStart;
  final void Function(Offset delta) onPanUpdate;
  final VoidCallback onPanEnd;
  final VoidCallback onDoubleTap;
  final VoidCallback onMinimize;
  final VoidCallback onMaximize;
  final VoidCallback onClose;
  final VoidCallback onFocus;
  final void Function(TileZone zone) onTile;
  final VoidCallback onToggleAlwaysOnTop;
  final void Function(int index) onMoveToWorkspace;
  final void Function(TileZone zone) onSnapLayout;

  Future<void> _showTileMenu(BuildContext context, Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(global.dx, global.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'pin',
          child: Text(alwaysOnTop ? '取消置顶' : '置顶'),
        ),
        const PopupMenuItem(value: 'maximize', child: Text('最大化')),
        const PopupMenuItem(value: 'minimize', child: Text('最小化')),
        const PopupMenuItem(value: 'restore', child: Text('还原')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: TileZone.left, child: Text('左半屏')),
        const PopupMenuItem(value: TileZone.right, child: Text('右半屏')),
        const PopupMenuItem(value: TileZone.top, child: Text('上半屏')),
        const PopupMenuItem(value: TileZone.bottom, child: Text('下半屏')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: TileZone.topLeft, child: Text('左上')),
        const PopupMenuItem(value: TileZone.topRight, child: Text('右上')),
        const PopupMenuItem(value: TileZone.bottomLeft, child: Text('左下')),
        const PopupMenuItem(value: TileZone.bottomRight, child: Text('右下')),
        if (workspaceCount > 1) ...[
          const PopupMenuDivider(),
          for (var i = 0; i < workspaceCount; i++)
            PopupMenuItem(value: 'ws:$i', child: Text('移到桌面 ${i + 1}')),
        ],
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'close', child: Text('关闭')),
      ],
    );
    if (selected == null) return;
    if (selected == 'pin') {
      onToggleAlwaysOnTop();
      return;
    }
    if (selected == 'maximize') {
      onMaximize();
      return;
    }
    if (selected == 'minimize') {
      onMinimize();
      return;
    }
    if (selected == 'restore') {
      if (maximized) onMaximize();
      return;
    }
    if (selected == 'close') {
      onClose();
      return;
    }
    if (selected is String && selected.startsWith('ws:')) {
      final i = int.tryParse(selected.substring(3));
      if (i != null) onMoveToWorkspace(i);
      return;
    }
    if (selected is TileZone) onTile(selected);
  }

  Future<void> _showSnapPicker(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final origin = box.localToGlobal(Offset(box.size.width - 90, box.size.height));
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(origin.dx, origin.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: TileZone.left, child: Text('左半 · 1×2')),
        PopupMenuItem(value: TileZone.right, child: Text('右半 · 1×2')),
        PopupMenuItem(value: TileZone.top, child: Text('上半 · 2×1')),
        PopupMenuItem(value: TileZone.bottom, child: Text('下半 · 2×1')),
        PopupMenuDivider(),
        PopupMenuItem(value: TileZone.topLeft, child: Text('左上 · 2×2')),
        PopupMenuItem(value: TileZone.topRight, child: Text('右上 · 2×2')),
        PopupMenuItem(value: TileZone.bottomLeft, child: Text('左下 · 2×2')),
        PopupMenuItem(value: TileZone.bottomRight, child: Text('右下 · 2×2')),
      ],
    );
    if (selected is TileZone) onSnapLayout(selected);
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onFocus,
      onDoubleTap: onDoubleTap,
      onSecondaryTapUp: (d) => unawaited(_showTileMenu(context, d.globalPosition)),
      onPanStart: (_) => onPanStart(),
      onPanUpdate: (d) => onPanUpdate(d.delta),
      onPanEnd: (_) => onPanEnd(),
      onPanCancel: onPanEnd,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: focused ? wb.panelElevated : wb.panel,
          border: Border(bottom: BorderSide(color: wb.border)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: focused ? wb.accentBlue : wb.textMuted),
            if (alwaysOnTop) ...[
              const SizedBox(width: 4),
              Icon(Icons.push_pin, size: 12, color: wb.accentBlue),
            ],
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: focused ? wb.primaryText : wb.secondaryText,
                ),
              ),
            ),
            _TitleBtn(
              icon: Icons.remove_rounded,
              tooltip: '最小化',
              onPressed: onMinimize,
            ),
            _SnapMaximizeBtn(
              maximized: maximized,
              onMaximize: onMaximize,
              onShowLayouts: () => unawaited(_showSnapPicker(context)),
              onSnapLayout: onSnapLayout,
            ),
            _TitleBtn(
              icon: Icons.close_rounded,
              tooltip: '关闭',
              danger: true,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _SnapMaximizeBtn extends StatefulWidget {
  const _SnapMaximizeBtn({
    required this.maximized,
    required this.onMaximize,
    required this.onShowLayouts,
    required this.onSnapLayout,
  });

  final bool maximized;
  final VoidCallback onMaximize;
  final VoidCallback onShowLayouts;
  final void Function(TileZone zone) onSnapLayout;

  @override
  State<_SnapMaximizeBtn> createState() => _SnapMaximizeBtnState();
}

class _SnapMaximizeBtnState extends State<_SnapMaximizeBtn> {
  final _layer = OverlayPortalController();
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 280), () {
      if (mounted) _layer.hide();
    });
  }

  void _cancelHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _showGrid() {
    if (widget.maximized) return;
    _cancelHide();
    _layer.show();
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return OverlayPortal(
      controller: _layer,
      overlayChildBuilder: (ctx) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return const SizedBox.shrink();
        final origin = box.localToGlobal(Offset.zero);
        return Positioned(
          left: origin.dx - 72,
          top: origin.dy + box.size.height + 4,
          child: MouseRegion(
            onEnter: (_) => _cancelHide(),
            onExit: (_) => _scheduleHide(),
            child: Material(
              elevation: 8,
              color: wb.panelElevated,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  width: 148,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '贴边布局',
                        style: TextStyle(
                          fontSize: 11,
                          color: wb.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // 2×2 quarters
                      SizedBox(
                        height: 56,
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                children: [
                                  Expanded(
                                    child: _SnapCell(
                                      onTap: () {
                                        _layer.hide();
                                        widget.onSnapLayout(TileZone.topLeft);
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Expanded(
                                    child: _SnapCell(
                                      onTap: () {
                                        _layer.hide();
                                        widget.onSnapLayout(
                                          TileZone.bottomLeft,
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 2),
                            Expanded(
                              child: Column(
                                children: [
                                  Expanded(
                                    child: _SnapCell(
                                      onTap: () {
                                        _layer.hide();
                                        widget.onSnapLayout(TileZone.topRight);
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Expanded(
                                    child: _SnapCell(
                                      onTap: () {
                                        _layer.hide();
                                        widget.onSnapLayout(
                                          TileZone.bottomRight,
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: _SnapCell(
                              height: 22,
                              label: '左',
                              onTap: () {
                                _layer.hide();
                                widget.onSnapLayout(TileZone.left);
                              },
                            ),
                          ),
                          const SizedBox(width: 2),
                          Expanded(
                            child: _SnapCell(
                              height: 22,
                              label: '右',
                              onTap: () {
                                _layer.hide();
                                widget.onSnapLayout(TileZone.right);
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: Tooltip(
        message: widget.maximized ? '还原' : '最大化 · 悬停选布局',
        waitDuration: const Duration(milliseconds: 400),
        child: MouseRegion(
          onEnter: (_) => _showGrid(),
          onExit: (_) => _scheduleHide(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: widget.onMaximize,
                onSecondaryTap: widget.onShowLayouts,
                onLongPress: widget.onShowLayouts,
                canRequestFocus: false,
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 28,
                  height: 24,
                  child: Icon(
                    widget.maximized
                        ? Icons.filter_none_rounded
                        : Icons.crop_square_rounded,
                    size: 15,
                    color: wb.textMuted,
                  ),
                ),
              ),
              if (!widget.maximized)
                InkWell(
                  onTap: widget.onShowLayouts,
                  onSecondaryTap: widget.onShowLayouts,
                  canRequestFocus: false,
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 14,
                    height: 24,
                    child: Icon(
                      Icons.arrow_drop_down_rounded,
                      size: 14,
                      color: wb.textMuted.withValues(alpha: 0.85),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SnapCell extends StatelessWidget {
  const _SnapCell({
    required this.onTap,
    this.height,
    this.label,
  });

  final VoidCallback onTap;
  final double? height;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Material(
      color: wb.panel,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: label == null
              ? const SizedBox.expand()
              : Center(
                  child: Text(
                    label!,
                    style: TextStyle(fontSize: 10, color: wb.textMuted),
                  ),
                ),
        ),
      ),
    );
  }
}

class _TitleBtn extends StatelessWidget {
  const _TitleBtn({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onPressed,
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 28,
          height: 24,
          child: Icon(
            icon,
            size: 15,
            color: danger ? const Color(0xFFEF4444) : wb.textMuted,
          ),
        ),
      ),
    );
  }
}
