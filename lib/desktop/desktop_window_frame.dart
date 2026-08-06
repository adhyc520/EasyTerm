import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/workbench_theme.dart';
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
  static const double handle = 6;

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

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => wm.focus(window.id),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: wb.panel,
          borderRadius: BorderRadius.circular(isMax ? 0 : 8),
          border: Border.all(color: borderColor, width: focused ? 1.5 : 1),
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
          borderRadius: BorderRadius.circular(isMax ? 0 : 8),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TitleBar(
                    height: titleBarH,
                    icon: _iconFor(window.type),
                    title: window.title,
                    focused: focused,
                    maximized: isMax,
                    onPanUpdate: (d) {
                      wm.focus(window.id);
                      wm.dragBy(window.id, d);
                    },
                    onPanEnd: () => wm.snapDragEnd(window.id),
                    onDoubleTap: () => wm.toggleMaximize(window.id),
                    onMinimize: () => wm.minimize(window.id),
                    onMaximize: () => wm.toggleMaximize(window.id),
                    onClose: () => wm.close(window.id),
                    onFocus: () => wm.focus(window.id),
                    onTile: (zone) => wm.tile(window.id, zone),
                  ),
                  Expanded(
                    child: ColoredBox(
                      color: wb.bg,
                      child: child,
                    ),
                  ),
                ],
              ),
              if (!isMax) ..._resizeHandles(context),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _resizeHandles(BuildContext context) {
    Widget edge({
      required ResizeEdge e,
      required MouseCursor cursor,
      required Alignment alignment,
      double? width,
      double? height,
    }) {
      return Align(
        alignment: alignment,
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => wm.focus(window.id),
            onPanUpdate: (d) => wm.resizeBy(window.id, e, d.delta),
            child: SizedBox(width: width, height: height),
          ),
        ),
      );
    }

    const t = handle;
    return [
      // edges
      edge(
        e: ResizeEdge.left,
        cursor: SystemMouseCursors.resizeLeftRight,
        alignment: Alignment.centerLeft,
        width: t,
        height: double.infinity,
      ),
      edge(
        e: ResizeEdge.right,
        cursor: SystemMouseCursors.resizeLeftRight,
        alignment: Alignment.centerRight,
        width: t,
        height: double.infinity,
      ),
      edge(
        e: ResizeEdge.top,
        cursor: SystemMouseCursors.resizeUpDown,
        alignment: Alignment.topCenter,
        width: double.infinity,
        height: t,
      ),
      edge(
        e: ResizeEdge.bottom,
        cursor: SystemMouseCursors.resizeUpDown,
        alignment: Alignment.bottomCenter,
        width: double.infinity,
        height: t,
      ),
      // corners
      edge(
        e: ResizeEdge.topLeft,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        alignment: Alignment.topLeft,
        width: t + 4,
        height: t + 4,
      ),
      edge(
        e: ResizeEdge.topRight,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
        alignment: Alignment.topRight,
        width: t + 4,
        height: t + 4,
      ),
      edge(
        e: ResizeEdge.bottomLeft,
        cursor: SystemMouseCursors.resizeUpRightDownLeft,
        alignment: Alignment.bottomLeft,
        width: t + 4,
        height: t + 4,
      ),
      edge(
        e: ResizeEdge.bottomRight,
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        alignment: Alignment.bottomRight,
        width: t + 4,
        height: t + 4,
      ),
    ];
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.height,
    required this.icon,
    required this.title,
    required this.focused,
    required this.maximized,
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
  final void Function(Offset delta) onPanUpdate;
  final VoidCallback onPanEnd;
  final VoidCallback onDoubleTap;
  final VoidCallback onMinimize;
  final VoidCallback onMaximize;
  final VoidCallback onClose;
  final VoidCallback onFocus;
  final void Function(TileZone zone) onTile;

  Future<void> _showTileMenu(BuildContext context, Offset global) async {
    final box = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero);
    final rel = RelativeRect.fromLTRB(
      global.dx - topLeft.dx,
      global.dy - topLeft.dy,
      global.dx - topLeft.dx + 1,
      global.dy - topLeft.dy + 1,
    );
    final wb = context.wb;
    final zone = await showMenu<TileZone>(
      context: context,
      position: rel,
      color: wb.panelElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: wb.border),
      ),
      items: const [
        PopupMenuItem(value: TileZone.left, child: Text('左侧半屏')),
        PopupMenuItem(value: TileZone.right, child: Text('右侧半屏')),
        PopupMenuItem(value: TileZone.top, child: Text('上侧半屏')),
        PopupMenuItem(value: TileZone.bottom, child: Text('下侧半屏')),
        PopupMenuDivider(),
        PopupMenuItem(value: TileZone.topLeft, child: Text('左上四分')),
        PopupMenuItem(value: TileZone.topRight, child: Text('右上四分')),
        PopupMenuItem(value: TileZone.bottomLeft, child: Text('左下四分')),
        PopupMenuItem(value: TileZone.bottomRight, child: Text('右下四分')),
      ],
    );
    if (zone != null) onTile(zone);
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onFocus,
      onDoubleTap: onDoubleTap,
      onPanUpdate: (d) => onPanUpdate(d.delta),
      onPanEnd: (_) => onPanEnd(),
      onSecondaryTapUp: (d) => unawaited(_showTileMenu(context, d.globalPosition)),
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
              icon: Icons.grid_view_rounded,
              tooltip: '贴边分屏',
              onPressed: () {
                final box = context.findRenderObject() as RenderBox?;
                final pos = box?.localToGlobal(Offset(box.size.width - 80, height)) ??
                    Offset.zero;
                unawaited(_showTileMenu(context, pos));
              },
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
