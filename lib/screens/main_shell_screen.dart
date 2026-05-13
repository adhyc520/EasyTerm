import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../models/saved_host_profile.dart';
import '../services/host_profiles_store.dart';
import '../services/session_tabs_controller.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';
import '../widgets/connection_sheet.dart';
import '../widgets/saved_host_connect_sheet.dart';
import '../widgets/session_workspace.dart';
import '../widgets/sftp_side_panel.dart';
import '../widgets/workbench_status_bar.dart';
import '../widgets/workbench_terminal_settings_dialog.dart';

Color _sessionStatusDot(SshWorkspaceController c) {
  if (c.connected) return WorkbenchPalette.online;
  if (c.connecting) return const Color(0xFFEAB308);
  if (c.error != null && c.error!.isNotEmpty) return const Color(0xFFEF4444);
  return WorkbenchPalette.offline;
}

class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key});

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen> {
  late final WorkbenchSettingsStore _workbenchSettings;
  late final SessionTabsController _tabs;
  final HostProfilesStore _profiles = HostProfilesStore();

  void _onRepaint() => setState(() {});

  @override
  void initState() {
    super.initState();
    _workbenchSettings = WorkbenchSettingsStore();
    _tabs = SessionTabsController(settings: _workbenchSettings);
    unawaited(
      _workbenchSettings.load().then((_) {
        if (mounted) setState(() {});
      }),
    );
    _tabs.addListener(_onRepaint);
    _profiles.addListener(_onRepaint);
    _profiles.ensureLoaded();
  }

  @override
  void dispose() {
    _tabs.removeListener(_onRepaint);
    _profiles.removeListener(_onRepaint);
    _tabs.dispose();
    _workbenchSettings.dispose();
    super.dispose();
  }

  void _openNewHostShortcut() {
    unawaited(_openNewHostSheet());
  }

  Future<void> _openNewHostSheet() async {
    final launch = await showNewHostSheet(context);
    if (!mounted || launch == null) return;

    if (launch.saveAsDevice) {
      await _profiles.upsert(
        label: launch.deviceLabel ?? '${launch.username}@${launch.host}',
        host: launch.host,
        port: launch.port,
        username: launch.username,
        keyPath: launch.keyPath,
        password: launch.password.trim().isNotEmpty ? launch.password : null,
      );
    }

    _tabs.openTab(
      host: launch.host,
      port: launch.port,
      username: launch.username,
      password: launch.password,
      privateKeyPem: launch.privateKeyPem,
    );
  }

  bool _looksAuthFailure(String message) {
    final m = message.toLowerCase();
    return m.contains('authentication') ||
        m.contains('password') ||
        m.contains('keyboard-interactive') ||
        m.contains('all configured authentication methods failed') ||
        m.contains('login incorrect') ||
        m.contains('access denied');
  }

  Future<void> _retrySavedProfileAfterAuthFailure(
    SavedHostProfile profile,
    String? privateKeyPem,
    SshWorkspaceController failed,
  ) async {
    final idx = _tabs.tabs.indexWhere((t) => identical(t.controller, failed));
    if (idx < 0) return;
    _tabs.closeTab(idx);
    if (!mounted) return;
    final cred = await showSavedHostConnectSheet(context, profile);
    if (!mounted || cred == null) return;
    _tabs.openTab(
      host: profile.host,
      port: profile.port,
      username: profile.username,
      password: cred.password,
      privateKeyPem: cred.privateKeyPem ?? privateKeyPem,
    );
    if (cred.password.trim().isNotEmpty) {
      await _profiles.upsert(
        label: profile.label,
        host: profile.host,
        port: profile.port,
        username: profile.username,
        keyPath: profile.keyPath,
        password: cred.password,
      );
    }
  }

  Future<void> _connectFromSaved(SavedHostProfile profile) async {
    String? pem;
    try {
      pem = await loadPrivateKeyFromPath(profile.keyPath);
    } catch (_) {}
    if (!mounted) return;

    var password = profile.password ?? '';
    final hasKey = profile.keyPath != null && profile.keyPath!.trim().isNotEmpty;

    if (password.isEmpty && !hasKey) {
      final cred = await showSavedHostConnectSheet(context, profile);
      if (!mounted || cred == null) return;
      password = cred.password;
      pem = cred.privateKeyPem ?? pem;
    }

    final c = _tabs.openTab(
      host: profile.host,
      port: profile.port,
      username: profile.username,
      password: password,
      privateKeyPem: pem,
    );

    var handledOutcome = false;
    void onCred() {
      if (handledOutcome) return;
      if (c.connected) {
        c.removeListener(onCred);
        handledOutcome = true;
        return;
      }
      if (c.connecting) return;
      final err = c.error;
      if (err == null || err.isEmpty) {
        c.removeListener(onCred);
        handledOutcome = true;
        return;
      }
      handledOutcome = true;
      c.removeListener(onCred);
      if (_looksAuthFailure(err)) {
        unawaited(_retrySavedProfileAfterAuthFailure(profile, pem, c));
      }
    }

    c.addListener(onCred);
  }

  Future<void> _saveCurrentSession() async {
    final tab = _tabs.selectedTab;
    final c = tab?.controller;
    if (c == null || !c.connected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先连接一台主机')));
      }
      return;
    }
    final labelCtrl = TextEditingController(text: '${c.username}@${c.host}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存会话'),
        content: TextField(
          controller: labelCtrl,
          decoration: const InputDecoration(
            labelText: '设备名称',
            hintText: '例如：生产服务器',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _profiles.upsert(
      label: labelCtrl.text.trim().isEmpty ? '${c.username}@${c.host}' : labelCtrl.text.trim(),
      host: c.host,
      port: c.port,
      username: c.username,
      keyPath: null,
      password: c.password.isNotEmpty ? c.password : null,
    );
    labelCtrl.dispose();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存到左侧列表')));
    }
  }

  void _openSettingsMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.settings_input_component_outlined),
              title: const Text('终端与连接设置…'),
              onTap: () {
                Navigator.pop(ctx);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!context.mounted) return;
                  showDialog<void>(
                    context: context,
                    builder: (_) => WorkbenchTerminalSettingsDialog(settings: _workbenchSettings),
                  );
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.layers_clear_outlined),
              title: const Text('关闭全部会话'),
              onTap: () {
                Navigator.pop(ctx);
                _tabs.closeAll();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于 SSH Workbench'),
              onTap: () {
                Navigator.pop(ctx);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!context.mounted) return;
                  showAboutDialog(
                    context: context,
                    applicationName: 'SSH Workbench',
                    applicationVersion: '1.0',
                    children: const [
                      Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text('多会话 SSH 终端与 SFTP 文件浏览。'),
                      ),
                    ],
                  );
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyT, meta: true, shift: true): _openNewHostShortcut,
        const SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true): _openNewHostShortcut,
      },
      child: Scaffold(
        backgroundColor: WorkbenchPalette.bg,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _WorkbenchTopBar(
                onNewHost: _openNewHostSheet,
                onSaveSession: _saveCurrentSession,
                onSettings: _openSettingsMenu,
                showWindowDragStrip: !kIsWeb &&
                    (Platform.isMacOS || Platform.isWindows || Platform.isLinux),
              ),
              if (_tabs.tabs.isNotEmpty)
                _WorkspaceSessionTabBar(
                  tabs: _tabs,
                  onSelect: (i) => _tabs.selectTab(i),
                  onClose: (i) => _tabs.closeTab(i),
                ),
              Expanded(
                child: _ResizableThreeColumns(
                  left: _ConnectionsRail(
                    profiles: _profiles,
                    tabs: _tabs,
                    onTapProfile: _connectFromSaved,
                    onDeleteProfile: (id) => _profiles.remove(id),
                  ),
                  middle: _middlePane(),
                  right: _rightPane(),
                ),
              ),
              WorkbenchStatusBar(controller: _tabs.selectedTab?.controller),
            ],
          ),
        ),
      ),
    );
  }

  Widget _middlePane() {
    final tab = _tabs.selectedTab;
    final c = tab?.controller;
    if (c == null || !c.connected) {
      return const _WorkbenchPlaceholder(
        icon: Icons.folder_open_outlined,
        title: '文件浏览器',
        subtitle: '连接主机后可浏览远程目录',
      );
    }
    return SftpSidePanel(controller: c);
  }

  Widget _rightPane() {
    final tab = _tabs.selectedTab;
    if (tab == null) {
      return const _WorkbenchPlaceholder(
        icon: Icons.terminal_rounded,
        title: '终端',
        subtitle: '从左侧已保存连接打开会话，或使用顶部「新建连接」',
      );
    }
    return SessionWorkspace(
      key: ValueKey<Object>(tab.id),
      controller: tab.controller,
      workbenchSettings: _workbenchSettings,
      autofocusTerminal: true,
    );
  }
}

/// 左栏 / 文件 / 终端 三列，两条竖向分隔条可拖拽调整宽度。
class _ResizableThreeColumns extends StatefulWidget {
  const _ResizableThreeColumns({
    required this.left,
    required this.middle,
    required this.right,
  });

  final Widget left;
  final Widget middle;
  final Widget right;

  @override
  State<_ResizableThreeColumns> createState() => _ResizableThreeColumnsState();
}

class _ResizableThreeColumnsState extends State<_ResizableThreeColumns> {
  static const double _splitterW = 5;
  static const double _minLeft = 200;
  static const double _minMiddle = 200;
  static const double _minRight = 280;
  static const double _maxLeft = 440;

  /// 默认中间文件列较窄，终端占更多空间。
  double _leftW = 256;
  double _middleW = 228;

  double? _lastTotalWidth;

  void _syncToLayout(double total) {
    final maxLeft = (total - _splitterW * 2 - _minMiddle - _minRight).clamp(_minLeft, _maxLeft);
    final left = _leftW.clamp(_minLeft, maxLeft);
    final maxMiddle = (total - _splitterW * 2 - left - _minRight).clamp(_minMiddle, 720.0);
    final mid = _middleW.clamp(_minMiddle, maxMiddle);
    if (left != _leftW || mid != _middleW) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _leftW = left;
          _middleW = mid;
        });
      });
    }
  }

  void _dragLeftSplit(double dx) {
    final total = _lastTotalWidth;
    if (total == null) return;
    setState(() {
      final maxLeft = (total - _splitterW * 2 - _minMiddle - _minRight).clamp(_minLeft, _maxLeft);
      _leftW = (_leftW + dx).clamp(_minLeft, maxLeft);
    });
  }

  void _dragMiddleSplit(double dx) {
    final total = _lastTotalWidth;
    if (total == null) return;
    setState(() {
      final maxMiddle = total - _splitterW * 2 - _leftW - _minRight;
      _middleW = (_middleW + dx).clamp(_minMiddle, maxMiddle.clamp(_minMiddle, 720.0));
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;
        _lastTotalWidth = total;
        _syncToLayout(total);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: _leftW, child: widget.left),
            _WorkbenchColumnSplitter(width: _splitterW, onDrag: _dragLeftSplit),
            SizedBox(width: _middleW, child: widget.middle),
            _WorkbenchColumnSplitter(width: _splitterW, onDrag: _dragMiddleSplit),
            Expanded(child: widget.right),
          ],
        );
      },
    );
  }
}

class _WorkbenchColumnSplitter extends StatelessWidget {
  const _WorkbenchColumnSplitter({
    required this.width,
    required this.onDrag,
  });

  final double width;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: SizedBox(
          width: width,
          child: Center(
            child: Container(width: 1, color: WorkbenchPalette.border),
          ),
        ),
      ),
    );
  }
}

class _WorkbenchTopBar extends StatelessWidget {
  const _WorkbenchTopBar({
    required this.onNewHost,
    required this.onSaveSession,
    required this.onSettings,
    this.showWindowDragStrip = false,
  });

  final VoidCallback onNewHost;
  final VoidCallback onSaveSession;
  final VoidCallback onSettings;
  final bool showWindowDragStrip;

  @override
  Widget build(BuildContext context) {
    final capLeft = !kIsWeb && Platform.isMacOS ? MediaQuery.viewPaddingOf(context).left : 0.0;

    return Material(
      color: WorkbenchPalette.topBar,
      elevation: 0,
      child: Container(
        height: 52,
        padding: EdgeInsets.fromLTRB(12 + capLeft, 0, 12, 0),
        decoration: BoxDecoration(
          color: WorkbenchPalette.topBar,
          border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.terminal, color: WorkbenchPalette.accentBlue, size: 26),
            const SizedBox(width: 10),
            Text(
              'SSH Workbench',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
            ),
            const SizedBox(width: 8),
            if (showWindowDragStrip)
              Expanded(
                child: DragToMoveArea(
                  child: const SizedBox(height: 52),
                ),
              )
            else
              const Spacer(),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: WorkbenchPalette.accentBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              onPressed: onNewHost,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('新建连接'),
            ),
            const SizedBox(width: 10),
            TextButton.icon(
              onPressed: onSaveSession,
              icon: const Icon(Icons.save_outlined, size: 20, color: WorkbenchPalette.textMuted),
              label: const Text('保存会话', style: TextStyle(color: WorkbenchPalette.textMuted)),
            ),
            IconButton(
              tooltip: '设置',
              onPressed: onSettings,
              icon: const Icon(Icons.settings_outlined, color: WorkbenchPalette.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkbenchPlaceholder extends StatelessWidget {
  const _WorkbenchPlaceholder({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: WorkbenchPalette.panel,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: WorkbenchPalette.textMuted.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: WorkbenchPalette.textMuted, fontSize: 13, height: 1.35),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceSessionTabBar extends StatelessWidget {
  const _WorkspaceSessionTabBar({
    required this.tabs,
    required this.onSelect,
    required this.onClose,
  });

  final SessionTabsController tabs;
  final void Function(int index) onSelect;
  final void Function(int index) onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WorkbenchPalette.panelElevated,
      child: SizedBox(
        height: 34,
        child: ListenableBuilder(
          listenable: tabs,
          builder: (context, _) {
            return ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              itemCount: tabs.tabs.length,
              separatorBuilder: (context, index) => const SizedBox(width: 2),
              itemBuilder: (context, i) {
                final t = tabs.tabs[i];
                final sel = i == tabs.selectedIndex;
                return Material(
                  color: sel ? WorkbenchPalette.accentBlue.withValues(alpha: 0.22) : WorkbenchPalette.panel,
                  borderRadius: BorderRadius.circular(6),
                  child: InkWell(
                    onTap: () => onSelect(i),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 7, color: _sessionStatusDot(t.controller)),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 180),
                            child: Text(
                              t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: sel ? Colors.white : Colors.white70,
                                fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => onClose(i),
                            customBorder: const CircleBorder(),
                            child: const Padding(
                              padding: EdgeInsets.all(2),
                              child: Icon(Icons.close_rounded, size: 15, color: WorkbenchPalette.textMuted),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ConnectionsRail extends StatelessWidget {
  const _ConnectionsRail({
    required this.profiles,
    required this.tabs,
    required this.onTapProfile,
    required this.onDeleteProfile,
  });

  final HostProfilesStore profiles;
  final SessionTabsController tabs;
  final Future<void> Function(SavedHostProfile profile) onTapProfile;
  final void Function(String id) onDeleteProfile;

  static bool _anyConnectedTab(SessionTabsController tabs, SavedHostProfile p) {
    for (final t in tabs.tabs) {
      final c = t.controller;
      if (p.matchesEndpoint(host: c.host, port: c.port, username: c.username) && c.connected) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WorkbenchPalette.panel,
      child: ListenableBuilder(
        listenable: Listenable.merge([profiles, tabs]),
        builder: (context, _) {
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 12, 6),
                  child: Text(
                    '已保存连接',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: WorkbenchPalette.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
              if (profiles.profiles.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Text(
                      '暂无条目。使用顶部「新建连接」并勾选保存。',
                      style: TextStyle(color: WorkbenchPalette.textMuted.withValues(alpha: 0.85), fontSize: 12, height: 1.4),
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final p = profiles.profiles[i];
                      return _RailSavedTile(
                        profile: p,
                        online: _anyConnectedTab(tabs, p),
                        onTap: () => onTapProfile(p),
                        onDelete: () => onDeleteProfile(p.id),
                      );
                    },
                    childCount: profiles.profiles.length,
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
            ],
          );
        },
      ),
    );
  }
}

class _RailSavedTile extends StatelessWidget {
  const _RailSavedTile({
    required this.profile,
    required this.online,
    required this.onTap,
    required this.onDelete,
  });

  final SavedHostProfile profile;
  final bool online;
  final Future<void> Function() onTap;
  final VoidCallback onDelete;

  static void _showContextMenu(BuildContext context, Offset globalPosition, _RailSavedTile tile) {
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final topLeft = overlay.localToGlobal(Offset.zero);
    final rel = RelativeRect.fromLTRB(
      globalPosition.dx - topLeft.dx,
      globalPosition.dy - topLeft.dy,
      globalPosition.dx - topLeft.dx + 1,
      globalPosition.dy - topLeft.dy + 1,
    );
    showMenu<String>(
      context: context,
      position: rel,
      items: [
        const PopupMenuItem(value: 'open', child: Text('打开新会话')),
        PopupMenuItem(
          value: 'del',
          child: Text('删除', style: TextStyle(color: Colors.red.shade300)),
        ),
      ],
    ).then((v) {
      if (v == 'open') unawaited(tile.onTap());
      if (v == 'del') tile.onDelete();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dot = online ? WorkbenchPalette.online : WorkbenchPalette.offline;

    return GestureDetector(
      onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition, this),
      child: InkWell(
        onTap: () => onTap(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Icon(Icons.circle, size: 9, color: dot),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, height: 1.2),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      profile.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: WorkbenchPalette.textMuted,
                        fontSize: 11,
                        fontFamily: 'monospace',
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
