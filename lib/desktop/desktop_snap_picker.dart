import 'package:flutter/material.dart';

import '../theme/workbench_theme.dart';
import 'desktop_window_manager.dart';

/// Windows 11 风格 Snap 布局选择器（顶部中央）。
enum SnapLayout {
  halfLeft,
  halfRight,
  halfTop,
  halfBottom,
  thirdLeft,
  thirdCenter,
  thirdRight,
  twoThirdsLeft,
  oneThirdRight,
  oneThirdLeft,
  twoThirdsRight,
  quarterTopLeft,
  quarterTopRight,
  quarterBottomLeft,
  quarterBottomRight,
}

TileZone? snapLayoutToTileZone(SnapLayout layout) {
  return switch (layout) {
    SnapLayout.halfLeft => TileZone.left,
    SnapLayout.halfRight => TileZone.right,
    SnapLayout.halfTop => TileZone.top,
    SnapLayout.halfBottom => TileZone.bottom,
    SnapLayout.quarterTopLeft => TileZone.topLeft,
    SnapLayout.quarterTopRight => TileZone.topRight,
    SnapLayout.quarterBottomLeft => TileZone.bottomLeft,
    SnapLayout.quarterBottomRight => TileZone.bottomRight,
    // 三分布局暂映射到半屏，由 rectForSnapLayout 精确计算。
    _ => null,
  };
}

class DesktopSnapPicker extends StatefulWidget {
  const DesktopSnapPicker({
    super.key,
    required this.wm,
    required this.windowId,
    required this.onClose,
  });

  final DesktopWindowManager wm;
  final String windowId;
  final VoidCallback onClose;

  @override
  State<DesktopSnapPicker> createState() => _DesktopSnapPickerState();
}

class _DesktopSnapPickerState extends State<DesktopSnapPicker> {
  SnapLayout? _hover;

  void _apply(SnapLayout layout) {
    final zone = snapLayoutToTileZone(layout);
    if (zone != null) {
      widget.wm.tile(widget.windowId, zone);
    } else {
      final rect = rectForSnapLayout(widget.wm, layout);
      if (rect != null) {
        widget.wm.setWindowRect(widget.windowId, rect);
      }
    }
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Material(
      color: Colors.transparent,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: wb.panel.withValues(alpha: 0.96),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: wb.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '贴靠布局',
                    style: TextStyle(
                      color: wb.primaryText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _layoutPreview(
                        [
                          SnapLayout.halfLeft,
                          SnapLayout.halfRight,
                        ],
                        cols: 2,
                      ),
                      _layoutPreview(
                        [
                          SnapLayout.thirdLeft,
                          SnapLayout.thirdCenter,
                          SnapLayout.thirdRight,
                        ],
                        cols: 3,
                      ),
                      _layoutPreview(
                        [
                          SnapLayout.twoThirdsLeft,
                          SnapLayout.oneThirdRight,
                        ],
                        cols: 2,
                        flex: const [2, 1],
                      ),
                      _layoutPreview(
                        [
                          SnapLayout.oneThirdLeft,
                          SnapLayout.twoThirdsRight,
                        ],
                        cols: 2,
                        flex: const [1, 2],
                      ),
                      _layoutPreview(
                        [
                          SnapLayout.quarterTopLeft,
                          SnapLayout.quarterTopRight,
                          SnapLayout.quarterBottomLeft,
                          SnapLayout.quarterBottomRight,
                        ],
                        cols: 2,
                        rows: 2,
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
  }

  Widget _layoutPreview(
    List<SnapLayout> cells, {
    required int cols,
    int rows = 1,
    List<int>? flex,
  }) {
    final wb = context.wb;
    return SizedBox(
      width: 88,
      height: 56,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: wb.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: rows == 2
            ? Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        for (final c in cells.take(2))
                          Expanded(child: _cell(c)),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        for (final c in cells.skip(2).take(2))
                          Expanded(child: _cell(c)),
                      ],
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  for (var i = 0; i < cells.length; i++)
                    Expanded(
                      flex: flex != null && i < flex.length ? flex[i] : 1,
                      child: _cell(cells[i]),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _cell(SnapLayout layout) {
    final wb = context.wb;
    final hot = _hover == layout;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = layout),
      onExit: (_) => setState(() => _hover = null),
      child: GestureDetector(
        onTap: () => _apply(layout),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: hot
                ? wb.accentBlue.withValues(alpha: 0.55)
                : wb.accentBlue.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

/// 三分等非 TileZone 布局的矩形计算。
Rect? rectForSnapLayout(DesktopWindowManager wm, SnapLayout layout) {
  final desk = wm.desktopSize;
  if (desk == Size.zero) return null;
  final h = desk.height - DesktopWindowManager.taskbarH;
  final w = desk.width;
  final third = w / 3;
  return switch (layout) {
    SnapLayout.thirdLeft => Rect.fromLTWH(0, 0, third, h),
    SnapLayout.thirdCenter => Rect.fromLTWH(third, 0, third, h),
    SnapLayout.thirdRight => Rect.fromLTWH(2 * third, 0, third, h),
    SnapLayout.twoThirdsLeft => Rect.fromLTWH(0, 0, 2 * third, h),
    SnapLayout.oneThirdRight => Rect.fromLTWH(2 * third, 0, third, h),
    SnapLayout.oneThirdLeft => Rect.fromLTWH(0, 0, third, h),
    SnapLayout.twoThirdsRight => Rect.fromLTWH(third, 0, 2 * third, h),
    _ => null,
  };
}
