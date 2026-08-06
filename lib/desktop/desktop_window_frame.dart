import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/workbench_theme.dart';
import '../util/desktop_resize_cursors.dart';
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

  IconData _iconFor(DesktopAppType type) {
    switch (type) {
      case DesktopAppType.terminal:
        return Icons.terminal_rounded;
      case DesktopAppType.files:
        return Icons.folder_rounded;
      case DesktopAppType.browser:
        return Icons.language_rounded;
      case DesktopAppType.monitor:
        return Icons.monitor_heart_rounded;
      case DesktopAppType.tasks:
        return Icons.memory_rounded;
      case DesktopAppType.logs:
        return Icons.article_rounded;
      case DesktopAppType.containers:
        return Icons.view_in_ar_rounded;
      case DesktopAppType.diskUsage:
        return Icons.pie_chart_rounded;
      case DesktopAppType.transfers:
        return Icons.swap_vert_rounded;
      case DesktopAppType.editor:
        return Icons.edit_note_rounded;
    }
  }

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
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onDoubleTap,
    required this.onMinimize,
    required this.onMaximize,
    required this.onClose,
    required this.onFocus,
    required this.onTile,
  });

  final double height;
  final IconData icon;
  final String title;
  final bool focused;
  final bool maximized;
  final VoidCallback onPanStart;
  final void Function(Offset delta) onPanUpdate;
  final VoidCallback onPanEnd;
  final VoidCallback onDoubleTap;
  final VoidCallback onMinimize;
  final VoidCallback onMaximize;
  final VoidCallback onClose;
  final VoidCallback onFocus;
  final void Function(TileZone zone) onTile;

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
        const PopupMenuItem(value: 'maximize', child: Text('最大化')),
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
      ],
    );
    if (selected == null) return;
    if (selected == 'maximize') {
      onMaximize();
      return;
    }
    if (selected is TileZone) onTile(selected);
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
            _TitleBtn(
              icon: maximized
                  ? Icons.filter_none_rounded
                  : Icons.crop_square_rounded,
              tooltip: maximized ? '还原' : '最大化',
              onPressed: onMaximize,
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
