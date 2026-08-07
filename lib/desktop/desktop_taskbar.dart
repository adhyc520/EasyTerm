import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/remote_host_metrics.dart';
import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';
import '../widgets/desktop_settings_dialog.dart';
import '../widgets/desktop_shortcuts_cheatsheet.dart';
import 'desktop_app_registry.dart';
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
                  final groups = _groupTaskbarWindows(wm.windows);
                  return _TaskbarWindowStrip(
                    itemCount: groups.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 4),
                    itemBuilder: (context, i) {
                      final g = groups[i];
                      return _TaskbarWindowButton(group: g, wm: wm);
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
                Tooltip(
                  message:
                      '桌面 ${i + 1} · ${wm.workspaces[i].windows.length} 窗口',
                  child: InkWell(
                    onTap: () => wm.switchWorkspace(i),
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: Center(
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
        ListenableBuilder(
          listenable: widget.wm,
          builder: (context, _) {
            final showing = widget.wm.showingDesktop;
            return Tooltip(
              message: showing ? '还原窗口' : '显示桌面',
              child: IconButton(
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                onPressed: () => widget.wm.toggleShowDesktop(),
                icon: Icon(
                  showing
                      ? Icons.desktop_access_disabled_rounded
                      : Icons.desktop_windows_rounded,
                  color: showing ? wb.accentBlue : wb.textMuted,
                ),
              ),
            );
          },
        ),
        PopupMenuButton<_TrayAction>(
          tooltip: '快速设置',
          offset: const Offset(0, -8),
          position: PopupMenuPosition.over,
          color: wb.panelElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: wb.border),
          ),
          onSelected: (action) {
            switch (action) {
              case _TrayAction.settings:
                showDesktopSettingsDialog(context, wm: widget.wm);
              case _TrayAction.shortcuts:
                showDesktopShortcutsCheatsheet(context);
              case _TrayAction.lockSudo:
                widget.controller.lockSudoPassword();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      AppLocalizations.of(context)?.sudoLockedSnack ??
                          '已锁定 sudo 密码',
                    ),
                    duration: const Duration(seconds: 2),
                  ),
                );
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _TrayAction.settings,
              child: Row(
                children: [
                  Icon(Icons.settings_rounded, size: 16, color: wb.textMuted),
                  const SizedBox(width: 10),
                  Text('桌面设置', style: TextStyle(color: wb.primaryText)),
                ],
              ),
            ),
            PopupMenuItem(
              value: _TrayAction.shortcuts,
              child: Row(
                children: [
                  Icon(Icons.keyboard_rounded, size: 16, color: wb.textMuted),
                  const SizedBox(width: 10),
                  Text('键盘快捷键', style: TextStyle(color: wb.primaryText)),
                ],
              ),
            ),
            PopupMenuItem(
              value: _TrayAction.lockSudo,
              child: Row(
                children: [
                  Icon(Icons.lock_outline_rounded, size: 16, color: wb.textMuted),
                  const SizedBox(width: 10),
                  Text('锁定 sudo', style: TextStyle(color: wb.primaryText)),
                ],
              ),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Icon(Icons.settings_outlined, size: 16, color: wb.textMuted),
          ),
        ),
      ],
    );
  }
}

enum _TrayAction { settings, shortcuts, lockSudo }

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
        for (final app in kAllApps)
          if (app.id != DesktopAppType.editor)
            _item(
              context,
              value: _launchActionFor(app.id),
              icon: app.icon,
              label: app.label,
            ),
        _item(
          context,
          value: _LaunchAction.editor,
          icon: Icons.folder_open_rounded,
          label: '打开文件…',
        ),
        const PopupMenuDivider(),
        _item(
          context,
          value: _LaunchAction.settings,
          icon: Icons.settings_rounded,
          label: '桌面设置',
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

  static _LaunchAction _launchActionFor(DesktopAppType id) => switch (id) {
        DesktopAppType.terminal => _LaunchAction.terminal,
        DesktopAppType.files => _LaunchAction.files,
        DesktopAppType.browser => _LaunchAction.browser,
        DesktopAppType.monitor => _LaunchAction.monitor,
        DesktopAppType.tasks => _LaunchAction.tasks,
        DesktopAppType.logs => _LaunchAction.logs,
        DesktopAppType.containers => _LaunchAction.containers,
        DesktopAppType.diskUsage => _LaunchAction.diskUsage,
        DesktopAppType.transfers => _LaunchAction.transfers,
        DesktopAppType.editor => _LaunchAction.editor,
        DesktopAppType.forwards => _LaunchAction.forwards,
        DesktopAppType.runCommand => _LaunchAction.runCommand,
        DesktopAppType.cron => _LaunchAction.cron,
        DesktopAppType.users => _LaunchAction.users,
        DesktopAppType.packages => _LaunchAction.packages,
        DesktopAppType.firewall => _LaunchAction.firewall,
      };
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

/// 按 [DesktopAppType] 分组：保留首次出现顺序。
List<_TaskbarGroup> _groupTaskbarWindows(List<DesktopWindow> wins) {
  final order = <DesktopAppType>[];
  final map = <DesktopAppType, List<DesktopWindow>>{};
  for (final w in wins) {
    map.putIfAbsent(w.type, () {
      order.add(w.type);
      return <DesktopWindow>[];
    }).add(w);
  }
  return [
    for (final t in order) _TaskbarGroup(type: t, windows: map[t]!),
  ];
}

class _TaskbarGroup {
  const _TaskbarGroup({required this.type, required this.windows});

  final DesktopAppType type;
  final List<DesktopWindow> windows;

  DesktopWindow get mostRecent {
    var best = windows.first;
    for (var i = 1; i < windows.length; i++) {
      if (windows[i].z > best.z) best = windows[i];
    }
    return best;
  }

  bool get anyFocused =>
      windows.any((w) => w.focused && w.state != WindowState.minimized);
}

class _TaskbarWindowButton extends StatefulWidget {
  const _TaskbarWindowButton({required this.group, required this.wm});

  final _TaskbarGroup group;
  final DesktopWindowManager wm;

  @override
  State<_TaskbarWindowButton> createState() => _TaskbarWindowButtonState();
}

class _TaskbarWindowButtonState extends State<_TaskbarWindowButton> {
  Timer? _hoverFocus;

  IconData _icon() => iconForApp(widget.group.type);

  String get _label {
    final g = widget.group;
    if (g.windows.length == 1) return g.windows.first.title;
    return metaFor(g.type).label;
  }

  @override
  void dispose() {
    _hoverFocus?.cancel();
    super.dispose();
  }

  void _onPrimaryTap() {
    final g = widget.group;
    final target = g.mostRecent;
    widget.wm.taskbarActivate(target.id);
  }

  Future<void> _showContextMenu(BuildContext context, Offset global) async {
    final g = widget.group;
    if (g.windows.length > 1) {
      await _showInstanceMenu(context, global);
    } else {
      await _showWindowMenu(context, global, g.windows.first);
    }
  }

  Future<void> _showInstanceMenu(BuildContext context, Offset global) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final wm = widget.wm;
    final items = <PopupMenuEntry<String>>[
      for (final w in widget.group.windows)
        PopupMenuItem(
          value: w.id,
          child: Text(
            w.title,
            style: TextStyle(
              fontWeight: w.focused ? FontWeight.w600 : FontWeight.normal,
              decoration: w.state == WindowState.minimized
                  ? TextDecoration.lineThrough
                  : null,
            ),
          ),
        ),
    ];
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(global.dx, global.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    if (selected == null) return;
    wm.restore(selected);
  }

  Future<void> _showWindowMenu(
    BuildContext context,
    Offset global,
    DesktopWindow window,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
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
    final g = widget.group;
    final wm = widget.wm;
    final active = g.anyFocused;
    final count = g.windows.length;
    final pinned = g.windows.any((w) => w.alwaysOnTop);
    final allMinimized =
        g.windows.every((w) => w.state == WindowState.minimized);
    return Tooltip(
      message: count > 1
          ? '${metaFor(g.type).label} · $count 个窗口'
          : g.windows.first.title,
      waitDuration: const Duration(milliseconds: 400),
      child: DropTarget(
        onDragEntered: (_) {
          _hoverFocus?.cancel();
          _hoverFocus = Timer(const Duration(milliseconds: 300), () {
            wm.focus(g.mostRecent.id);
          });
        },
        onDragExited: (_) => _hoverFocus?.cancel(),
        onDragDone: (_) => _hoverFocus?.cancel(),
        child: InkWell(
          onTap: _onPrimaryTap,
          onSecondaryTapUp: (d) =>
              unawaited(_showContextMenu(context, d.globalPosition)),
          onLongPress: () {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            final global = box.localToGlobal(Offset(box.size.width / 2, 0));
            unawaited(_showContextMenu(context, global));
          },
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
                if (pinned)
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
                    _label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: active ? wb.primaryText : wb.secondaryText,
                      decoration: allMinimized
                          ? TextDecoration.lineThrough
                          : null,
                      decorationColor: wb.textMuted,
                    ),
                  ),
                ),
                if (count > 1) ...[
                  const SizedBox(width: 6),
                  Container(
                    constraints: const BoxConstraints(minWidth: 16),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    height: 16,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: wb.accentBlue.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: wb.accentBlue,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 任务栏窗口按钮横条：可横滚，两端软渐隐提示溢出。
class _TaskbarWindowStrip extends StatefulWidget {
  const _TaskbarWindowStrip({
    required this.itemCount,
    required this.itemBuilder,
    required this.separatorBuilder,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final IndexedWidgetBuilder separatorBuilder;

  @override
  State<_TaskbarWindowStrip> createState() => _TaskbarWindowStripState();
}

class _TaskbarWindowStripState extends State<_TaskbarWindowStrip> {
  final _scroll = ScrollController();
  var _showLeft = false;
  var _showRight = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateFades);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateFades());
  }

  @override
  void didUpdateWidget(covariant _TaskbarWindowStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateFades());
  }

  @override
  void dispose() {
    _scroll.removeListener(_updateFades);
    _scroll.dispose();
    super.dispose();
  }

  void _updateFades() {
    if (!mounted || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final left = pos.pixels > 2;
    final right = pos.pixels < pos.maxScrollExtent - 2;
    if (left != _showLeft || right != _showRight) {
      setState(() {
        _showLeft = left;
        _showRight = right;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Stack(
      children: [
        ListView.separated(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          itemCount: widget.itemCount,
          separatorBuilder: widget.separatorBuilder,
          itemBuilder: widget.itemBuilder,
        ),
        if (_showLeft)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 16,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      wb.topBar,
                      wb.topBar.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (_showRight)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 16,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      wb.topBar.withValues(alpha: 0),
                      wb.topBar,
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
