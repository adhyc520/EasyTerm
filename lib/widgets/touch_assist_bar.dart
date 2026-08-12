import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/workbench_theme.dart';

/// 触控辅助工具栏：注入特殊键到终端。
class TouchAssistBar extends StatelessWidget {
  const TouchAssistBar({
    super.key,
    required this.onKey,
    this.visible = true,
  });

  /// 收到逻辑键时回调（调用方可写入 PTY / 模拟按键）。
  final void Function(LogicalKeyboardKey key) onKey;
  final bool visible;

  static const _keys = <(LogicalKeyboardKey, String)>[
    (LogicalKeyboardKey.escape, 'Esc'),
    (LogicalKeyboardKey.tab, 'Tab'),
    (LogicalKeyboardKey.controlLeft, 'Ctrl'),
    (LogicalKeyboardKey.arrowUp, '↑'),
    (LogicalKeyboardKey.arrowDown, '↓'),
    (LogicalKeyboardKey.arrowLeft, '←'),
    (LogicalKeyboardKey.arrowRight, '→'),
    (LogicalKeyboardKey.backspace, '⌫'),
  ];

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final wb = context.wb;
    return Material(
      color: wb.topBar,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: wb.border)),
        ),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          itemCount: _keys.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, i) {
            final (key, label) = _keys[i];
            return SizedBox(
              width: 52,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  foregroundColor: wb.primaryText,
                  side: BorderSide(color: wb.border),
                  minimumSize: const Size(44, 32),
                ),
                onPressed: () => onKey(key),
                child: Text(label, style: const TextStyle(fontSize: 12)),
              ),
            );
          },
        ),
      ),
    );
  }
}
