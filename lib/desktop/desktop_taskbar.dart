import 'dart:async';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/remote_host_metrics.dart';
import '../services/terminal_session_controller.dart';
import '../services/remote_exec_capable.dart';
import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';
import '../widgets/desktop_settings_dialog.dart';
import '../widgets/desktop_shortcuts_cheatsheet.dart';
import 'desktop_app_registry.dart';
import 'desktop_window_manager.dart';
import 'widgets/desktop_ui.dart';

/// 底部 Dock：浮动毛玻璃条 + 启动器 / 窗口图标 / 工作区 / 托盘。
///
/// Dock 固定占满托盘左侧区域（宽度不随窗口数量变化）；托盘贴右。
/// 极窄时托盘进入紧凑模式，再窄则 Dock+托盘合成一条。
class DesktopTaskbar extends StatelessWidget {
  const DesktopTaskbar({
    super.key,
    required this.wm,
    required this.controller,
  });

  final DesktopWindowManager wm;
  final TerminalSessionController controller;

  static const _gap = 8.0;
  static const _compactTrayBelow = 560.0;
  static const _mergeBelow = 420.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: DesktopWindowManager.taskbarH,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final compactTray = w < _compactTrayBelow;
            final merge = w < _mergeBelow;

            final tray = DesktopGlass(
              elevated: true,
              opacity: 0.38,
              sigma: 36,
              borderRadius: BorderRadius.circular(14),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: _TrayArea(
                wm: wm,
                controller: controller,
                compact: compactTray,
              ),
            );

            // 极窄：合成一条，避免两块玻璃争宽度
            if (merge) {
              return Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  width: w,
                  child: DesktopGlass(
                    elevated: true,
                    opacity: 0.38,
                    sigma: 36,
                    borderRadius: BorderRadius.circular(16),
                    padding: const EdgeInsets.fromLTRB(5, 3, 5, 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: _DockStrip(wm: wm, showWorkspaces: false),
                        ),
                        const SizedBox(width: 4),
                        _DockDivider(),
                        const SizedBox(width: 4),
                        _TrayArea(
                          wm: wm,
                          controller: controller,
                          compact: true,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            // 常规：Dock 固定占满左侧，托盘贴右
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: DesktopGlass(
                    elevated: true,
                    opacity: 0.38,
                    sigma: 36,
                    borderRadius: BorderRadius.circular(16),
                    padding: const EdgeInsets.fromLTRB(5, 3, 5, 3),
                    child: _DockStrip(
                      wm: wm,
                      showWorkspaces: true,
                    ),
                  ),
                ),
                const SizedBox(width: _gap),
                tray,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DockStrip extends StatelessWidget {
  const _DockStrip({
    required this.wm,
    this.showWorkspaces = true,
  });

  final DesktopWindowManager wm;
  final bool showWorkspaces;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: wm,
      builder: (context, _) {
        final groups = _groupTaskbarWindows(wm.windows);
        return Row(
          children: [
            _LauncherButton(wm: wm),
            const SizedBox(width: 2),
            _DockDivider(),
            const SizedBox(width: 2),
            Expanded(
              child: groups.isEmpty
                  ? const SizedBox(height: 32)
                  : _TaskbarWindowStrip(
                      itemCount: groups.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 1),
                      itemBuilder: (context, i) {
                        final g = groups[i];
                        return _TaskbarWindowButton(group: g, wm: wm);
                      },
                    ),
            ),
            if (showWorkspaces) ...[
              const SizedBox(width: 2),
              _DockDivider(),
              const SizedBox(width: 2),
              _WorkspaceIndicator(wm: wm),
            ],
          ],
        );
      },
    );
  }
}

class _DockDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: wb.border.withValues(alpha: 0.7),
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
  const _TrayArea({
    required this.wm,
    required this.controller,
    this.compact = false,
  });
  final DesktopWindowManager wm;
  final TerminalSessionController controller;
  final bool compact;

  @override
  State<_TrayArea> createState() => _TrayAreaState();
}

class _TrayAreaState extends State<_TrayArea> {
  RemoteExecCapable? get _exec =>
      widget.controller is RemoteExecCapable
          ? widget.controller as RemoteExecCapable
          : null;
  SshWorkspaceController? get _ssh =>
      widget.controller is SshWorkspaceController
          ? widget.controller as SshWorkspaceController
          : null;

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
      final exec = _exec;
      // Never inject tray probes into Telnet/Serial interactive consoles.
      final shareInteractive = exec?.execSharesInteractiveSession == true;
      final light = exec?.lightweightRemoteExec == true;
      RemoteHostSnapshot? snap = _snap;
      if (ds.trayShowMetrics && !shareInteractive) {
        snap = await exec?.snapshot();
      }
      if (!mounted) return;
      String clock = _clock;
      if (ds.trayShowClock) {
        // Prefer local clock when remote exec would hit the user's PTY.
        if (shareInteractive || light) {
          final now = DateTime.now();
          clock =
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
        } else {
          final raw = await exec?.runQueued(
            r"date '+%H:%M'",
            allowInteractiveFallback: false,
          );
          if (raw != null && raw.isNotEmpty) {
            clock = raw.split(RegExp(r'\s')).first;
          } else {
            final now = DateTime.now();
            clock =
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          }
        }
      }
      setState(() {
        _snap = snap;
        _clock = clock;
      });
    } catch (_) {}
  }

  bool get _recentCmdError {
    final err = _exec?.lastRemoteCommandError;
    final at = _ssh?.lastRemoteCommandErrorAt;
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
        return '命令失败：${_exec?.lastRemoteCommandError}';
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
        if (!widget.compact &&
            ds.trayShowMetrics &&
            (cpu != null || mem != null))
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
        if (ds.trayShowClock && (!widget.compact || !ds.trayShowMetrics))
          Padding(
            padding: EdgeInsets.only(left: widget.compact ? 4 : 8),
            child: Text(
              _clock,
              style: TextStyle(
                fontSize: widget.compact ? 11.0 : 12.0,
                color: wb.secondaryText,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        if (widget.compact &&
            ds.trayShowMetrics &&
            (cpu != null || mem != null))
          Tooltip(
            message: [
              if (cpu != null) 'CPU ${(cpu * 100).round()}%',
              if (mem != null) 'MEM ${(mem * 100).round()}%',
              if (ds.trayShowClock) _clock,
            ].join(' · '),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Icon(Icons.speed_rounded, size: 14, color: wb.textMuted),
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
                _ssh?.lockSudoPassword();
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

/// Windows 风格启动菜单：贴任务栏上方的紧凑网格，避免纵向长列表过高。
class _LauncherButton extends StatelessWidget {
  const _LauncherButton({required this.wm});

  final DesktopWindowManager wm;

  static const double _menuWidth = 360;
  static const double _gapAboveButton = 10;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return _DockIconButton(
      onTap: () => unawaited(_openStartMenu(context)),
      child: _DockIconShell(
        tooltip: '启动器',
        child: Icon(Icons.grid_view_rounded, size: 18, color: wb.primaryText),
      ),
    );
  }

  Future<void> _openStartMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;

    final buttonTopLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final buttonRect = buttonTopLeft & box.size;
    final screen = overlayBox.size;

    final apps = appsForCapabilities(wm.controller.capabilities)
        .where((a) => a.id != DesktopAppType.editor)
        .toList();

    final selected = await showGeneralDialog<_StartMenuResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭启动菜单',
      barrierColor: Colors.black.withValues(alpha: 0.18),
      transitionDuration: DesktopUi.fast,
      pageBuilder: (ctx, anim, _) {
        final maxLeft = math.max(8.0, screen.width - _menuWidth - 8);
        // 左对齐启动按钮，超出右缘时回拉。
        final left = buttonRect.left.clamp(8.0, maxLeft);
        final bottom = screen.height - buttonRect.top + _gapAboveButton;

        return Stack(
          children: [
            Positioned(
              left: left,
              bottom: bottom,
              width: _menuWidth,
              child: FadeTransition(
                opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.96, end: 1).animate(
                    CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                  ),
                  alignment: Alignment.bottomLeft,
                  child: _StartMenuPanel(
                    apps: apps,
                    onOpenApp: (id) =>
                        Navigator.of(ctx).pop(_StartMenuResult.app(id)),
                    onOpenSettings: () =>
                        Navigator.of(ctx).pop(const _StartMenuResult.settings()),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      transitionBuilder: (ctx, anim, _, child) => child,
    );

    if (!context.mounted || selected == null) return;
    if (selected.isSettings) {
      showDesktopSettingsDialog(context, wm: wm);
      return;
    }
    final id = selected.appId;
    if (id == null) return;
    if (id == DesktopAppType.terminal) {
      wm.openTerminal();
    } else {
      wm.open(id);
    }
  }
}

class _StartMenuResult {
  const _StartMenuResult._({this.appId, this.isSettings = false});
  const _StartMenuResult.settings() : this._(isSettings: true);
  const _StartMenuResult.app(DesktopAppType id) : this._(appId: id);

  final DesktopAppType? appId;
  final bool isSettings;
}

class _StartMenuPanel extends StatefulWidget {
  const _StartMenuPanel({
    required this.apps,
    required this.onOpenApp,
    required this.onOpenSettings,
  });

  final List<AppMeta> apps;
  final ValueChanged<DesktopAppType> onOpenApp;
  final VoidCallback onOpenSettings;

  @override
  State<_StartMenuPanel> createState() => _StartMenuPanelState();
}

class _StartMenuPanelState extends State<_StartMenuPanel> {
  final _query = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<AppMeta> get _filtered {
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return widget.apps;
    return widget.apps.where((a) {
      if (a.label.toLowerCase().contains(q)) return true;
      return a.keywords.any((k) => k.toLowerCase().contains(q));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final apps = _filtered;

    return Material(
      type: MaterialType.transparency,
      child: DesktopGlass(
        elevated: true,
        opacity: 0.88,
        sigma: 36,
        borderRadius: DesktopUi.rLg,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StartMenuSearch(
              controller: _query,
              onChanged: (v) => setState(() => _filter = v),
            ),
            const SizedBox(height: 10),
            Text(
              '应用',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: wb.textMuted,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 268),
              child: apps.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(
                          '无匹配应用',
                          style: TextStyle(fontSize: 13, color: wb.textMuted),
                        ),
                      ),
                    )
                  : GridView.builder(
                      shrinkWrap: true,
                      physics: const ClampingScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: 4,
                        crossAxisSpacing: 4,
                        childAspectRatio: 0.92,
                      ),
                      itemCount: apps.length,
                      itemBuilder: (context, i) {
                        final app = apps[i];
                        return _StartMenuTile(
                          icon: app.icon,
                          label: app.label,
                          onTap: () => widget.onOpenApp(app.id),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: wb.border.withValues(alpha: 0.7)),
            const SizedBox(height: 6),
            _StartMenuFooterButton(
              icon: Icons.settings_rounded,
              label: '桌面设置',
              onTap: widget.onOpenSettings,
            ),
          ],
        ),
      ),
    );
  }
}

class _StartMenuSearch extends StatelessWidget {
  const _StartMenuSearch({
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autofocus: true,
      style: TextStyle(fontSize: 13, color: wb.primaryText),
      decoration: InputDecoration(
        isDense: true,
        hintText: '搜索应用',
        hintStyle: TextStyle(fontSize: 13, color: wb.textMuted),
        prefixIcon: Icon(Icons.search_rounded, size: 18, color: wb.textMuted),
        prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        filled: true,
        fillColor: wb.panel.withValues(alpha: 0.85),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: DesktopUi.rSm,
          borderSide: BorderSide(color: wb.border.withValues(alpha: 0.7)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: DesktopUi.rSm,
          borderSide: BorderSide(color: wb.border.withValues(alpha: 0.7)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: DesktopUi.rSm,
          borderSide: BorderSide(color: wb.accentBlue.withValues(alpha: 0.7)),
        ),
      ),
    );
  }
}

class _StartMenuTile extends StatefulWidget {
  const _StartMenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_StartMenuTile> createState() => _StartMenuTileState();
}

class _StartMenuTileState extends State<_StartMenuTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DesktopUi.fast,
          decoration: BoxDecoration(
            color: _hover
                ? wb.primaryText.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: DesktopUi.rSm,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: 22, color: wb.primaryText),
              const SizedBox(height: 6),
              Text(
                widget.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.15,
                  fontWeight: FontWeight.w500,
                  color: wb.primaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StartMenuFooterButton extends StatefulWidget {
  const _StartMenuFooterButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_StartMenuFooterButton> createState() => _StartMenuFooterButtonState();
}

class _StartMenuFooterButtonState extends State<_StartMenuFooterButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DesktopUi.fast,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: _hover
                ? wb.primaryText.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: DesktopUi.rSm,
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 18, color: wb.primaryText),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: wb.primaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
        child: _DockIconButton(
          active: active,
          dimmed: allMinimized,
          badge: count > 1 ? '$count' : (pinned ? '•' : null),
          onTap: _onPrimaryTap,
          onSecondaryTapUp: (d) =>
              unawaited(_showContextMenu(context, d.globalPosition)),
          onLongPress: () {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            final global = box.localToGlobal(Offset(box.size.width / 2, 0));
            unawaited(_showContextMenu(context, global));
          },
          child: Icon(
            _icon(),
            size: 18,
            color: active
                ? wb.accentBlue
                : allMinimized
                    ? wb.textMuted.withValues(alpha: 0.55)
                    : wb.primaryText,
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
                      Colors.black.withValues(alpha: 0.18),
                      Colors.transparent,
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
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.18),
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

class _DockIconShell extends StatelessWidget {
  const _DockIconShell({required this.child, this.tooltip});

  final Widget child;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final body = SizedBox(
      width: DesktopUi.dockIcon,
      height: DesktopUi.dockIcon,
      child: Center(child: child),
    );
    if (tooltip == null) return body;
    return Tooltip(message: tooltip!, child: body);
  }
}

class _DockIconButton extends StatefulWidget {
  const _DockIconButton({
    required this.child,
    required this.onTap,
    this.onSecondaryTapUp,
    this.onLongPress,
    this.active = false,
    this.dimmed = false,
    this.badge,
  });

  final Widget child;
  final VoidCallback onTap;
  final void Function(TapUpDetails)? onSecondaryTapUp;
  final VoidCallback? onLongPress;
  final bool active;
  final bool dimmed;
  final String? badge;

  @override
  State<_DockIconButton> createState() => _DockIconButtonState();
}

class _DockIconButtonState extends State<_DockIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapUp: widget.onSecondaryTapUp,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _hover ? 1.12 : 1.0,
          duration: DesktopUi.fast,
          curve: Curves.easeOutCubic,
          child: SizedBox(
            width: DesktopUi.dockIcon,
            height: DesktopUi.dockIcon + 4,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: DesktopUi.fast,
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: widget.active || _hover
                        ? wb.primaryText.withValues(alpha: 0.08)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(child: widget.child),
                ),
                if (widget.badge != null)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      height: 14,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: wb.accentBlue,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        widget.badge!,
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  bottom: 0,
                  child: AnimatedContainer(
                    duration: DesktopUi.fast,
                    width: widget.active ? 6 : (widget.dimmed ? 0 : 4),
                    height: 4,
                    decoration: BoxDecoration(
                      color: widget.active
                          ? wb.primaryText
                          : wb.textMuted.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(2),
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
