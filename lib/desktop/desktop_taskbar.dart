import 'package:flutter/material.dart';

import '../theme/workbench_theme.dart';
import 'desktop_window_manager.dart';

/// 底部任务栏：启动器 + 窗口按钮。
class DesktopTaskbar extends StatelessWidget {
  const DesktopTaskbar({
    super.key,
    required this.wm,
  });

  final DesktopWindowManager wm;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Material(
      color: wb.topBar,
      child: Container(
        height: DesktopWindowManager.taskbarH,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: wb.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            _LauncherButton(wm: wm),
            const SizedBox(width: 8),
            Expanded(
              child: ListenableBuilder(
                listenable: wm,
                builder: (context, _) {
                  final wins = wm.windows;
                  return ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: wins.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 4),
                    itemBuilder: (context, i) {
                      final w = wins[i];
                      return _TaskbarWindowButton(window: w, wm: wm);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LauncherButton extends StatelessWidget {
  const _LauncherButton({required this.wm});

  final DesktopWindowManager wm;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return PopupMenuButton<_LaunchAction>(
      tooltip: '启动器',
      offset: const Offset(0, -8),
      position: PopupMenuPosition.over,
      color: wb.panelElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: wb.border),
      ),
      onSelected: (action) {
        switch (action) {
          case _LaunchAction.terminal:
            wm.openTerminal();
          case _LaunchAction.files:
            wm.open(DesktopAppType.files);
          case _LaunchAction.browser:
            wm.open(DesktopAppType.browser);
          case _LaunchAction.monitor:
            wm.open(DesktopAppType.monitor);
          case _LaunchAction.tasks:
            wm.open(DesktopAppType.tasks);
          case _LaunchAction.editor:
            // 编辑器需从文件管理器打开具体路径
            wm.open(DesktopAppType.files);
        }
      },
      itemBuilder: (context) => [
        _item(
          context,
          value: _LaunchAction.terminal,
          icon: Icons.terminal_rounded,
          label: '终端',
        ),
        _item(
          context,
          value: _LaunchAction.files,
          icon: Icons.folder_rounded,
          label: '文件',
        ),
        _item(
          context,
          value: _LaunchAction.browser,
          icon: Icons.language_rounded,
          label: '浏览器',
        ),
        _item(
          context,
          value: _LaunchAction.monitor,
          icon: Icons.monitor_heart_rounded,
          label: '监控',
        ),
        _item(
          context,
          value: _LaunchAction.tasks,
          icon: Icons.memory_rounded,
          label: '任务管理器',
        ),
        _item(
          context,
          value: _LaunchAction.editor,
          icon: Icons.folder_open_rounded,
          label: '打开文件…',
        ),
      ],
      child: Container(
        width: 36,
        height: 32,
        decoration: BoxDecoration(
          color: wb.panelElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: wb.border),
        ),
        child: Icon(Icons.apps_rounded, size: 18, color: wb.primaryText),
      ),
    );
  }

  PopupMenuItem<_LaunchAction> _item(
    BuildContext context, {
    required _LaunchAction value,
    required IconData icon,
    required String label,
    bool enabled = true,
    String? disabledTooltip,
  }) {
    final wb = context.wb;
    final row = Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: enabled ? wb.primaryText : wb.textMuted.withValues(alpha: 0.45),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: enabled
                  ? wb.primaryText
                  : wb.textMuted.withValues(alpha: 0.45),
            ),
          ),
        ),
      ],
    );
    return PopupMenuItem<_LaunchAction>(
      value: value,
      enabled: enabled,
      child: enabled || disabledTooltip == null
          ? row
          : Tooltip(
              message: disabledTooltip,
              child: row,
            ),
    );
  }
}

enum _LaunchAction { terminal, files, browser, monitor, tasks, editor }

class _TaskbarWindowButton extends StatelessWidget {
  const _TaskbarWindowButton({required this.window, required this.wm});

  final DesktopWindow window;
  final DesktopWindowManager wm;

  IconData _icon() {
    switch (window.type) {
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
    final active = window.focused && window.state != WindowState.minimized;
    return Tooltip(
      message: window.title,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: () => wm.taskbarActivate(window.id),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          constraints: const BoxConstraints(minWidth: 96, maxWidth: 160),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: active ? wb.panelElevated : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? wb.accentBlue.withValues(alpha: 0.55) : wb.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _icon(),
                size: 14,
                color: active ? wb.accentBlue : wb.textMuted,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  window.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: active ? wb.primaryText : wb.secondaryText,
                    decoration: window.state == WindowState.minimized
                        ? TextDecoration.lineThrough
                        : null,
                    decorationColor: wb.textMuted,
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
