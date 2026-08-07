import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../services/remote_host_metrics.dart';
import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';
import '../widgets/desktop_settings_dialog.dart';
import 'desktop_window_manager.dart';

/// 底部任务栏：启动器 + 窗口按钮 + 工作区 + 系统托盘。
class DesktopTaskbar extends StatelessWidget {
  const DesktopTaskbar({
    super.key,
    required this.wm,
    required this.controller,
  });

  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

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
            const SizedBox(width: 8),
            _WorkspaceIndicator(wm: wm),
            const SizedBox(width: 8),
            _TrayArea(wm: wm, controller: controller),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceIndicator extends StatelessWidget {
  const _WorkspaceIndicator({required this.wm});
  final DesktopWindowManager wm;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return ListenableBuilder(
      listenable: wm,
      builder: (context, _) {
        return GestureDetector(
          onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < wm.workspaces.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: InkWell(
                    onTap: () => wm.switchWorkspace(i),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == wm.activeWorkspaceIndex
                            ? wb.accentBlue
                            : wb.textMuted.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _menu(BuildContext context, Offset global) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(global.dx, global.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'add', child: Text('新建工作区')),
        PopupMenuItem(value: 'remove', child: Text('删除当前工作区')),
      ],
    );
    if (selected == 'add') wm.addWorkspace();
    if (selected == 'remove') wm.removeWorkspace(wm.activeWorkspaceIndex);
  }
}

class _TrayArea extends StatefulWidget {
  const _TrayArea({required this.wm, required this.controller});
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<_TrayArea> createState() => _TrayAreaState();
}

class _TrayAreaState extends State<_TrayArea> {
  Timer? _timer;
  RemoteHostSnapshot? _snap;
  String _clock = '--:--';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onCtrl);
    _arm();
    unawaited(_tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_onCtrl);
    super.dispose();
  }

  void _onCtrl() {
    if (mounted) setState(() {});
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_tick());
    });
  }

  Future<void> _tick() async {
    if (!mounted) return;
    final c = widget.controller;
    if (!c.connected || c.dropped) return;
    final ds = widget.wm.desktopSettings;
    if (!ds.trayShowClock && !ds.trayShowMetrics) return;
    try {
      final snap = await c.snapshot();
      if (!mounted) return;
      String clock = _clock;
      if (ds.trayShowClock) {
        final raw = await c.runQueued(r"date '+%H:%M'");
        if (raw != null && raw.isNotEmpty) {
          clock = raw.split(RegExp(r'\s')).first;
        }
      }
      setState(() {
        _snap = snap;
        _clock = clock;
      });
    } catch (_) {}
  }

  bool get _recentCmdError {
    final err = widget.controller.lastRemoteCommandError;
    final at = widget.controller.lastRemoteCommandErrorAt;
    if (err == null || at == null) return false;
    return DateTime.now().difference(at) < const Duration(seconds: 30);
  }

  Color _statusColor(WorkbenchColors wb) {
    final c = widget.controller;
    if (c.connecting) return const Color(0xFFFBBF24);
    if (c.connected && !c.dropped) {
      if (_recentCmdError) return const Color(0xFFFB923C);
      return const Color(0xFF34D399);
    }
    return const Color(0xFFEF4444);
  }

  String get _statusTooltip {
    final c = widget.controller;
    if (c.connecting) return '连接中…';
    if (c.connected && !c.dropped) {
      if (_recentCmdError) {
        return '命令失败：${c.lastRemoteCommandError}';
      }
      return '已连接';
    }
    return '已断开 · 点击重连';
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final ds = widget.wm.desktopSettings;
    final cpu = _snap?.cpuUsed01;
    final mem = _snap?.memUsed01;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: _statusTooltip,
          child: InkWell(
            onTap: () {
              if (!widget.controller.connected || widget.controller.dropped) {
                unawaited(widget.controller.reconnect());
              }
            },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _statusColor(wb),
                ),
              ),
            ),
          ),
        ),
        if (ds.trayShowMetrics && (cpu != null || mem != null))
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              [
                if (cpu != null) 'CPU ${(cpu * 100).round()}%',
                if (mem != null) 'MEM ${(mem * 100).round()}%',
              ].join('  '),
              style: TextStyle(fontSize: 11, color: wb.textMuted),
            ),
          ),
        if (ds.trayShowClock)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              _clock,
              style: TextStyle(
                fontSize: 12,
                color: wb.secondaryText,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        Tooltip(
          message: widget.wm.showingDesktop ? '还原窗口' : '显示桌面',
          child: IconButton(
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: () => widget.wm.toggleShowDesktop(),
            icon: Icon(Icons.desktop_windows_rounded, color: wb.textMuted),
          ),
        ),
        Tooltip(
          message: '桌面设置',
          child: IconButton(
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                showDesktopSettingsDialog(context, wm: widget.wm),
            icon: Icon(Icons.settings_outlined, color: wb.textMuted),
          ),
        ),
      ],
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
          case _LaunchAction.logs:
            wm.open(DesktopAppType.logs);
          case _LaunchAction.containers:
            wm.open(DesktopAppType.containers);
          case _LaunchAction.diskUsage:
            wm.open(DesktopAppType.diskUsage);
          case _LaunchAction.transfers:
            wm.open(DesktopAppType.transfers);
          case _LaunchAction.editor:
            wm.open(DesktopAppType.files);
          case _LaunchAction.forwards:
            wm.open(DesktopAppType.forwards);
          case _LaunchAction.runCommand:
            wm.open(DesktopAppType.runCommand);
          case _LaunchAction.cron:
            wm.open(DesktopAppType.cron);
          case _LaunchAction.users:
            wm.open(DesktopAppType.users);
          case _LaunchAction.packages:
            wm.open(DesktopAppType.packages);
          case _LaunchAction.firewall:
            wm.open(DesktopAppType.firewall);
          case _LaunchAction.settings:
            showDesktopSettingsDialog(context, wm: wm);
        }
      },
      itemBuilder: (context) => [
        _item(context, value: _LaunchAction.terminal, icon: Icons.terminal_rounded, label: '终端'),
        _item(context, value: _LaunchAction.files, icon: Icons.folder_rounded, label: '文件'),
        _item(context, value: _LaunchAction.browser, icon: Icons.language_rounded, label: '浏览器'),
        _item(context, value: _LaunchAction.monitor, icon: Icons.monitor_heart_rounded, label: '监控'),
        _item(context, value: _LaunchAction.tasks, icon: Icons.memory_rounded, label: '任务管理器'),
        _item(context, value: _LaunchAction.logs, icon: Icons.article_rounded, label: '日志'),
        _item(context, value: _LaunchAction.containers, icon: Icons.view_in_ar_rounded, label: '容器'),
        _item(context, value: _LaunchAction.diskUsage, icon: Icons.pie_chart_rounded, label: '磁盘占用'),
        _item(context, value: _LaunchAction.transfers, icon: Icons.swap_vert_rounded, label: '传输'),
        _item(context, value: _LaunchAction.forwards, icon: Icons.alt_route_rounded, label: '端口转发'),
        _item(context, value: _LaunchAction.runCommand, icon: Icons.play_circle_outline_rounded, label: '运行命令'),
        _item(context, value: _LaunchAction.cron, icon: Icons.schedule_rounded, label: '计划任务'),
        _item(context, value: _LaunchAction.users, icon: Icons.groups_rounded, label: '用户与组'),
        _item(context, value: _LaunchAction.packages, icon: Icons.inventory_2_rounded, label: '包管理器'),
        _item(context, value: _LaunchAction.firewall, icon: Icons.security_rounded, label: '防火墙'),
        _item(context, value: _LaunchAction.editor, icon: Icons.folder_open_rounded, label: '打开文件…'),
        const PopupMenuDivider(),
        _item(context, value: _LaunchAction.settings, icon: Icons.settings_rounded, label: '桌面设置'),
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
  }) {
    final wb = context.wb;
    return PopupMenuItem<_LaunchAction>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: wb.primaryText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: TextStyle(color: wb.primaryText)),
          ),
        ],
      ),
    );
  }
}

enum _LaunchAction {
  terminal,
  files,
  browser,
  monitor,
  tasks,
  logs,
  containers,
  diskUsage,
  transfers,
  editor,
  forwards,
  runCommand,
  cron,
  users,
  packages,
  firewall,
  settings,
}

class _TaskbarWindowButton extends StatefulWidget {
  const _TaskbarWindowButton({required this.window, required this.wm});

  final DesktopWindow window;
  final DesktopWindowManager wm;

  @override
  State<_TaskbarWindowButton> createState() => _TaskbarWindowButtonState();
}

class _TaskbarWindowButtonState extends State<_TaskbarWindowButton> {
  Timer? _hoverFocus;

  IconData _icon() {
    switch (widget.window.type) {
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
      case DesktopAppType.forwards:
        return Icons.alt_route_rounded;
      case DesktopAppType.runCommand:
        return Icons.play_circle_outline_rounded;
      case DesktopAppType.cron:
        return Icons.schedule_rounded;
      case DesktopAppType.users:
        return Icons.groups_rounded;
      case DesktopAppType.packages:
        return Icons.inventory_2_rounded;
      case DesktopAppType.firewall:
        return Icons.security_rounded;
    }
  }

  @override
  void dispose() {
    _hoverFocus?.cancel();
    super.dispose();
  }

  Future<void> _showMenu(BuildContext context, Offset global) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final window = widget.window;
    final wm = widget.wm;
    final items = <PopupMenuEntry<Object>>[
      PopupMenuItem(
        value: 'pin',
        child: Text(window.alwaysOnTop ? '取消置顶' : '置顶'),
      ),
      const PopupMenuItem(value: 'maximize', child: Text('最大化')),
      const PopupMenuItem(value: 'minimize', child: Text('最小化')),
      const PopupMenuItem(value: 'restore', child: Text('还原')),
      const PopupMenuDivider(),
      const PopupMenuItem(value: TileZone.left, child: Text('左半屏')),
      const PopupMenuItem(value: TileZone.right, child: Text('右半屏')),
      if (wm.workspaces.length > 1) ...[
        const PopupMenuDivider(),
        for (var i = 0; i < wm.workspaces.length; i++)
          PopupMenuItem(
            value: 'ws:$i',
            child: Text('移到 ${wm.workspaces[i].name}'),
          ),
      ],
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'close', child: Text('关闭')),
    ];
    final selected = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(global.dx, global.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    if (selected == null) return;
    final id = window.id;
    if (selected == 'pin') wm.toggleAlwaysOnTop(id);
    if (selected == 'maximize') wm.toggleMaximize(id);
    if (selected == 'minimize') wm.minimize(id);
    if (selected == 'restore') wm.restore(id);
    if (selected == 'close') unawaited(wm.requestClose(id));
    if (selected is TileZone) wm.tile(id, selected);
    if (selected is String && selected.startsWith('ws:')) {
      final i = int.tryParse(selected.substring(3));
      if (i != null) wm.moveWindowToWorkspace(id, i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final window = widget.window;
    final wm = widget.wm;
    final active = window.focused && window.state != WindowState.minimized;
    return Tooltip(
      message: window.title,
      waitDuration: const Duration(milliseconds: 400),
      child: DropTarget(
        onDragEntered: (_) {
          _hoverFocus?.cancel();
          _hoverFocus = Timer(const Duration(milliseconds: 300), () {
            wm.focus(window.id);
          });
        },
        onDragExited: (_) => _hoverFocus?.cancel(),
        onDragDone: (_) => _hoverFocus?.cancel(),
        child: InkWell(
          onTap: () => wm.taskbarActivate(window.id),
          onSecondaryTapUp: (d) =>
              unawaited(_showMenu(context, d.globalPosition)),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            constraints: const BoxConstraints(minWidth: 96, maxWidth: 160),
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: active ? wb.panelElevated : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color:
                    active ? wb.accentBlue.withValues(alpha: 0.55) : wb.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (window.alwaysOnTop)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child:
                        Icon(Icons.push_pin, size: 10, color: wb.accentBlue),
                  ),
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
      ),
    );
  }
}
