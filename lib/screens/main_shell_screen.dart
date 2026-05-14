import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/app_localizations.dart';
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
import '../widgets/workbench_interface_settings_dialog.dart';
import '../widgets/workbench_terminal_settings_dialog.dart';
import '../widgets/workbench_window_controls.dart';

Color _sessionStatusDot(BuildContext context, SshWorkspaceController c) {
  final w = context.wb;
  if (c.connected) return w.online;
  if (c.connecting) return const Color(0xFFEAB308);
  if (c.error != null && c.error!.isNotEmpty) return const Color(0xFFEF4444);
  return w.offline;
}

class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key, required this.settings});

  final WorkbenchSettingsStore settings;

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

enum _SidebarView { savedHosts, fileBrowser }

class _MainShellScreenState extends State<MainShellScreen> {
  late final SessionTabsController _tabs;
  final HostProfilesStore _profiles = HostProfilesStore();

  /// 侧栏在「已保存连接」与「文件浏览器」之间切换，避免与终端并排占两列宽度。
  _SidebarView _sidebarView = _SidebarView.savedHosts;

  /// 与 [_syncSidebarToFileOnConnect] 配合：仅在当前选中标签「刚连上」时自动切到文件页。
  int? _sidebarSyncTabId;
  bool _sidebarSyncWasConnected = false;

  void _onRepaint() {
    _syncSidebarToFileOnConnect();
    setState(() {});
  }

  void _syncSidebarToFileOnConnect() {
    final tab = _tabs.selectedTab;
    if (tab == null) {
      _sidebarSyncTabId = null;
      _sidebarSyncWasConnected = false;
      return;
    }
    final now = tab.controller.connected;
    if (tab.id != _sidebarSyncTabId) {
      _sidebarSyncTabId = tab.id;
      _sidebarSyncWasConnected = now;
      return;
    }
    if (now && !_sidebarSyncWasConnected) {
      _sidebarView = _SidebarView.fileBrowser;
    }
    _sidebarSyncWasConnected = now;
  }

  @override
  void initState() {
    super.initState();
    _tabs = SessionTabsController(settings: widget.settings);
    _tabs.addListener(_onRepaint);
    _profiles.addListener(_onRepaint);
    _profiles.ensureLoaded();
  }

  @override
  void dispose() {
    _tabs.removeListener(_onRepaint);
    _profiles.removeListener(_onRepaint);
    _tabs.dispose();
    super.dispose();
  }

  void _openNewHostShortcut() {
    unawaited(_openNewHostSheet());
  }

  Future<void> _openNewHostSheet() async {
    final launch = await showNewHostSheet(context);
    if (!mounted || launch == null) return;
    await _persistLaunchAndConnect(launch);
  }

  Future<void> _editSavedProfile(SavedHostProfile profile) async {
    final launch = await showNewHostSheet(context, editingProfile: profile);
    if (!mounted || launch == null) return;
    await _persistLaunchAndConnect(launch);
  }

  Future<void> _persistLaunchAndConnect(ConnectionLaunch launch) async {
    final label = launch.deviceLabel ?? '${launch.username}@${launch.host}';
    final updateId = launch.existingProfileId;
    if (updateId != null) {
      await _profiles.updateById(
        id: updateId,
        label: label,
        host: launch.host,
        port: launch.port,
        username: launch.username,
        keyPath: launch.keyPath,
        password: launch.password.trim().isEmpty ? null : launch.password.trim(),
      );
    } else {
      await _profiles.add(
        label: label,
        host: launch.host,
        port: launch.port,
        username: launch.username,
        keyPath: launch.keyPath,
        password: launch.password.trim().isNotEmpty ? launch.password.trim() : null,
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
    if (message.contains('认证失败')) return true;
    final m = message.toLowerCase();
    return m.contains('authentication') ||
        m.contains('sshauthfail') ||
        m.contains('password') ||
        m.contains('keyboard-interactive') ||
        m.contains('all configured authentication methods failed') ||
        m.contains('all authentication methods failed') ||
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
      await _profiles.updateById(
        id: profile.id,
        label: profile.label,
        host: profile.host,
        port: profile.port,
        username: profile.username,
        keyPath: profile.keyPath,
        password: cred.password.trim(),
      );
    }
  }

  Future<void> _connectFromSaved(SavedHostProfile profile) async {
    String? pem;
    Object? keyReadFailure;
    try {
      pem = await loadPrivateKeyFromPath(profile.keyPath);
    } catch (e) {
      keyReadFailure = e;
    }
    if (!mounted) return;

    var password = profile.password ?? '';
    final hasKey = profile.keyPath != null && profile.keyPath!.trim().isNotEmpty;

    if (hasKey && pem == null && keyReadFailure != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.snackbarPrivateKeyReadFailed('$keyReadFailure'),
          ),
        ),
      );
    }

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

  void _openSettingsMenu() {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: Text(l10n.menuInterfaceSettings),
              onTap: () {
                Navigator.pop(ctx);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!context.mounted) return;
                  showDialog<void>(
                    context: context,
                    builder: (_) => WorkbenchInterfaceSettingsDialog(settings: widget.settings),
                  );
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_input_component_outlined),
              title: Text(l10n.menuTerminalAndConnection),
              onTap: () {
                Navigator.pop(ctx);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!context.mounted) return;
                  showDialog<void>(
                    context: context,
                    builder: (_) => WorkbenchTerminalSettingsDialog(settings: widget.settings),
                  );
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.layers_clear_outlined),
              title: Text(l10n.menuCloseAllSessions),
              onTap: () {
                Navigator.pop(ctx);
                _tabs.closeAll();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.menuAbout),
              onTap: () {
                Navigator.pop(ctx);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!context.mounted) return;
                  final about = AppLocalizations.of(context)!;
                  showAboutDialog(
                    context: context,
                    applicationName: about.appTitle,
                    applicationVersion: '1.0',
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(about.aboutDescription),
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
        backgroundColor: context.wb.bg,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
                _WorkbenchTopBar(
                  onNewHost: _openNewHostSheet,
                  onSettings: _openSettingsMenu,
                ),
              Expanded(
                child: _ResizableSidebarAndTerminal(
                  sidebar: _WorkbenchSidebarPane(
                    view: _sidebarView,
                    onViewChanged: (v) => setState(() => _sidebarView = v),
                    savedHosts: _ConnectionsRail(
                      profiles: _profiles,
                      tabs: _tabs,
                      onTapProfile: _connectFromSaved,
                      onEditProfile: _editSavedProfile,
                      onDeleteProfile: (id) => _profiles.remove(id),
                    ),
                    fileBrowser: _middlePane(),
                  ),
                  terminal: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_tabs.tabs.isNotEmpty)
                        _WorkspaceSessionTabBar(
                          tabs: _tabs,
                          onSelect: (i) => _tabs.selectTab(i),
                          onClose: (i) => _tabs.closeTab(i),
                        ),
                      Expanded(child: _rightPane()),
                      WorkbenchStatusBar(controller: _tabs.selectedTab?.controller),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _middlePane() {
    final tab = _tabs.selectedTab;
    final c = tab?.controller;
    final l10n = AppLocalizations.of(context)!;
    if (c == null || !c.connected) {
      return _WorkbenchPlaceholder(
        icon: Icons.folder_open_outlined,
        title: l10n.placeholderFileBrowserTitle,
        subtitle: l10n.placeholderFileBrowserSubtitle,
      );
    }
    return SftpSidePanel(controller: c);
  }

  Widget _rightPane() {
    final tab = _tabs.selectedTab;
    if (tab == null) {
      final l10n = AppLocalizations.of(context)!;
      return _WorkbenchPlaceholder(
        icon: Icons.terminal_rounded,
        title: l10n.placeholderTerminalTitle,
        subtitle: l10n.placeholderTerminalSubtitle,
      );
    }
    return SessionWorkspace(
      key: ValueKey<Object>(tab.id),
      controller: tab.controller,
      workbenchSettings: widget.settings,
      autofocusTerminal: true,
    );
  }
}

/// 侧栏（已保存 / 文件 切换）与终端两列，一条竖向分隔条可拖拽调整宽度。
class _ResizableSidebarAndTerminal extends StatefulWidget {
  const _ResizableSidebarAndTerminal({
    required this.sidebar,
    required this.terminal,
  });

  final Widget sidebar;
  final Widget terminal;

  @override
  State<_ResizableSidebarAndTerminal> createState() => _ResizableSidebarAndTerminalState();
}

class _ResizableSidebarAndTerminalState extends State<_ResizableSidebarAndTerminal> {
  static const double _splitterW = 5;
  static const double _minSidebar = 200;
  static const double _minTerminal = 280;
  static const double _maxSidebar = 520;

  /// 合并原左栏与中栏后，默认略宽以便文件列表可读；终端仍占剩余空间。
  double _sidebarW = 300;

  double? _lastTotalWidth;

  void _syncToLayout(double total) {
    final maxSidebar = (total - _splitterW - _minTerminal).clamp(_minSidebar, _maxSidebar);
    final w = _sidebarW.clamp(_minSidebar, maxSidebar);
    if (w != _sidebarW) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _sidebarW = w);
      });
    }
  }

  void _dragSplit(double dx) {
    final total = _lastTotalWidth;
    if (total == null) return;
    setState(() {
      final maxSidebar = (total - _splitterW - _minTerminal).clamp(_minSidebar, _maxSidebar);
      _sidebarW = (_sidebarW + dx).clamp(_minSidebar, maxSidebar);
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
            SizedBox(width: _sidebarW, child: widget.sidebar),
            _WorkbenchColumnSplitter(width: _splitterW, onDrag: _dragSplit),
            Expanded(child: widget.terminal),
          ],
        );
      },
    );
  }
}

class _WorkbenchSidebarPane extends StatelessWidget {
  const _WorkbenchSidebarPane({
    required this.view,
    required this.onViewChanged,
    required this.savedHosts,
    required this.fileBrowser,
  });

  final _SidebarView view;
  final ValueChanged<_SidebarView> onViewChanged;
  final Widget savedHosts;
  final Widget fileBrowser;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.wb.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: context.wb.border)),
            ),
            child: SegmentedButton<_SidebarView>(
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
                minimumSize: const WidgetStatePropertyAll(Size(44, 40)),
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return context.wb.accentBlue.withValues(alpha: 0.28);
                  }
                  return context.wb.panelElevated;
                }),
                foregroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) return context.wb.primaryText;
                  return context.wb.textMuted;
                }),
                side: WidgetStatePropertyAll(BorderSide(color: context.wb.border)),
              ),
              segments: <ButtonSegment<_SidebarView>>[
                ButtonSegment(
                  value: _SidebarView.savedHosts,
                  tooltip: AppLocalizations.of(context)!.sidebarSavedHostsTooltip,
                  icon: const Icon(Icons.dns_outlined, size: 20),
                ),
                ButtonSegment(
                  value: _SidebarView.fileBrowser,
                  tooltip: AppLocalizations.of(context)!.sidebarFilesTooltip,
                  icon: const Icon(Icons.folder_open_outlined, size: 20),
                ),
              ],
              selected: <_SidebarView>{view},
              onSelectionChanged: (s) {
                if (s.isEmpty) return;
                onViewChanged(s.first);
              },
            ),
          ),
          Expanded(child: view == _SidebarView.savedHosts ? savedHosts : fileBrowser),
        ],
      ),
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
            child: Container(width: 1, color: context.wb.border),
          ),
        ),
      ),
    );
  }
}

class _WorkbenchTopBar extends StatelessWidget {
  const _WorkbenchTopBar({
    required this.onNewHost,
    required this.onSettings,
  });

  final VoidCallback onNewHost;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final capLeft = !kIsWeb && Platform.isMacOS ? MediaQuery.viewPaddingOf(context).left : 0.0;
    final chrome = workbenchUsesCustomWindowChrome();
    final macChrome = chrome && Platform.isMacOS;
    final leftPad = macChrome ? 8.0 + capLeft : 12.0 + capLeft;

    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: context.wb.topBar,
      elevation: 0,
      child: Container(
        height: 52,
        padding: EdgeInsets.fromLTRB(leftPad, 0, 12, 0),
        decoration: BoxDecoration(
          color: context.wb.topBar,
          border: Border(
            bottom: BorderSide(color: context.wb.topBarDivider),
          ),
        ),
        child: Row(
          children: [
            if (macChrome) ...[
              WorkbenchWindowControls(
                side: WorkbenchWindowControlsSide.leadingMac,
                brightness: Theme.of(context).brightness,
              ),
              const SizedBox(width: 12),
            ],
            Icon(Icons.terminal, color: context.wb.accentBlue, size: 26),
            const SizedBox(width: 10),
            Text(
              l10n.appBarTitle,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: context.wb.primaryText,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
            ),
            const SizedBox(width: 8),
            if (chrome)
              Expanded(
                child: DragToMoveArea(
                  child: const SizedBox(height: 52),
                ),
              )
            else
              const Spacer(),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: context.wb.accentBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                // M3 默认 labelLarge 多为 w500 + 正字距，中文在蓝底上易显「细」；略加粗并收紧字距。
                textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                      height: 1.15,
                    ),
              ),
              onPressed: onNewHost,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: Text(l10n.newConnection),
            ),
            const SizedBox(width: 10),
            IconButton(
              tooltip: l10n.settingsTooltip,
              onPressed: onSettings,
              icon: Icon(Icons.settings_outlined, color: context.wb.textMuted),
            ),
            if (chrome && !Platform.isMacOS) ...[
              const SizedBox(width: 4),
              WorkbenchWindowControls(
                side: WorkbenchWindowControlsSide.trailingWindows,
                brightness: Theme.of(context).brightness,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkbenchPlaceholder extends StatelessWidget {
  const _WorkbenchPlaceholder({
    required this.icon,
    this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String? title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.wb.panel,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: context.wb.textMuted.withValues(alpha: 0.6)),
              if (title != null && title!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(title!, style: TextStyle(color: context.wb.primaryText, fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
              ] else
                const SizedBox(height: 14),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.wb.textMuted, fontSize: 13, height: 1.35),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceSessionTabBar extends StatefulWidget {
  const _WorkspaceSessionTabBar({
    required this.tabs,
    required this.onSelect,
    required this.onClose,
  });

  final SessionTabsController tabs;
  final void Function(int index) onSelect;
  final void Function(int index) onClose;

  @override
  State<_WorkspaceSessionTabBar> createState() => _WorkspaceSessionTabBarState();
}

class _WorkspaceSessionTabBarState extends State<_WorkspaceSessionTabBar> {
  final ScrollController _scrollController = ScrollController();
  List<GlobalKey> _itemKeys = [];
  int _lastSelectionForScroll = -1;
  int _lastTabCount = -1;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _syncKeys(int n) {
    if (_itemKeys.length != n) {
      _itemKeys = List<GlobalKey>.generate(n, (_) => GlobalKey());
    }
  }

  void _scrollSelectedIntoView() {
    final tabs = widget.tabs;
    final i = tabs.selectedIndex;
    if (i < 0 || i >= _itemKeys.length) return;
    final ctx = _itemKeys[i].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs;
    return Material(
      color: context.wb.panelElevated,
      child: SizedBox(
        height: 36,
        child: ListenableBuilder(
          listenable: tabs,
          builder: (context, _) {
            _syncKeys(tabs.tabs.length);
            final sel = tabs.selectedIndex;
            final n = tabs.tabs.length;
            if (sel != _lastSelectionForScroll || n != _lastTabCount) {
              _lastSelectionForScroll = sel;
              _lastTabCount = n;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _scrollSelectedIntoView();
              });
            }
            return Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              trackVisibility: true,
              thickness: 4,
              radius: const Radius.circular(3),
              child: ListView.separated(
                controller: _scrollController,
                primary: false,
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                itemCount: tabs.tabs.length,
                separatorBuilder: (context, index) => const SizedBox(width: 2),
                itemBuilder: (context, i) {
                  final t = tabs.tabs[i];
                  final selected = i == tabs.selectedIndex;
                  return KeyedSubtree(
                    key: _itemKeys[i],
                    child: Material(
                      color: selected
                          ? context.wb.accentBlue.withValues(alpha: 0.22)
                          : context.wb.panel,
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        onTap: () => widget.onSelect(i),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.circle, size: 7, color: _sessionStatusDot(context, t.controller)),
                              const SizedBox(width: 6),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 180),
                                child: Text(
                                  t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected ? context.wb.primaryText : context.wb.secondaryText,
                                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: () => widget.onClose(i),
                                customBorder: const CircleBorder(),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(Icons.close_rounded, size: 15, color: context.wb.textMuted),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
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
    required this.onEditProfile,
    required this.onDeleteProfile,
  });

  final HostProfilesStore profiles;
  final SessionTabsController tabs;
  final Future<void> Function(SavedHostProfile profile) onTapProfile;
  final Future<void> Function(SavedHostProfile profile) onEditProfile;
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
      color: context.wb.panel,
      child: ListenableBuilder(
        listenable: Listenable.merge([profiles, tabs]),
        builder: (context, _) {
          final l10n = AppLocalizations.of(context)!;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 12, 6),
                  child: Text(
                    l10n.savedConnectionsHeader,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: context.wb.textMuted,
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
                      l10n.savedConnectionsEmpty,
                      style: TextStyle(color: context.wb.textMuted.withValues(alpha: 0.85), fontSize: 12, height: 1.4),
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
                        onEdit: () => onEditProfile(p),
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
    required this.onEdit,
    required this.onDelete,
  });

  final SavedHostProfile profile;
  final bool online;
  final Future<void> Function() onTap;
  final Future<void> Function() onEdit;
  final VoidCallback onDelete;

  static void _showContextMenu(BuildContext context, Offset globalPosition, _RailSavedTile tile) {
    final l10n = AppLocalizations.of(context)!;
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
        PopupMenuItem(value: 'open', child: Text(l10n.contextOpenSession)),
        PopupMenuItem(value: 'edit', child: Text(l10n.contextEdit)),
        PopupMenuItem(
          value: 'del',
          child: Text(l10n.contextDelete, style: TextStyle(color: Colors.red.shade300)),
        ),
      ],
    ).then((v) {
      if (v == 'open') unawaited(tile.onTap());
      if (v == 'edit') unawaited(tile.onEdit());
      if (v == 'del') tile.onDelete();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dot = online ? context.wb.online : context.wb.offline;

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
                      style: TextStyle(color: context.wb.primaryText, fontSize: 13, fontWeight: FontWeight.w600, height: 1.2),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      profile.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.wb.textMuted,
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
