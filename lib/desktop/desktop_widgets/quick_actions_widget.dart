import 'package:flutter/material.dart';

import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';
import 'desktop_widget.dart';

class QuickActionsDesktopWidget extends DesktopWidgetKind {
  QuickActionsDesktopWidget(this.wm);

  final DesktopWindowManager wm;

  @override
  String get id => 'quick_actions';

  @override
  String get name => '快捷操作';

  @override
  IconData get icon => Icons.flash_on_rounded;

  @override
  DesktopWidgetConfig defaultConfig() => DesktopWidgetConfig(
        position: const Offset(32, 300),
        size: const Size(200, 120),
      );

  @override
  Widget build(BuildContext context, DesktopWidgetConfig config) {
    final wb = context.wb;
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _chip(wb, Icons.terminal_rounded, '终端', () {
            wm.openTerminal(preferPrimary: false);
          }),
          if (wm.canOpen(DesktopAppType.files))
            _chip(wb, Icons.folder_rounded, '文件', () {
              wm.open(DesktopAppType.files);
            }),
          if (wm.canOpen(DesktopAppType.monitor))
            _chip(wb, Icons.monitor_heart_rounded, '监控', () {
              wm.open(DesktopAppType.monitor);
            }),
          if (wm.canOpen(DesktopAppType.logs))
            _chip(wb, Icons.article_rounded, '日志', () {
              wm.open(DesktopAppType.logs);
            }),
        ],
      ),
    );
  }

  Widget _chip(
    WorkbenchColors wb,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: wb.panel.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: wb.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: wb.accentBlue),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: wb.primaryText, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
