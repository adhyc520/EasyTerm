import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/app_localizations.dart';
import '../models/saved_host_profile.dart';
import '../services/code_snippets_store.dart';
import '../services/host_profiles_store.dart';
import '../services/workbench_desktop_shortcuts.dart';
import '../services/session_pane.dart';
import '../services/session_tabs_controller.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/app_update/app_update_service.dart';
import '../services/workbench_settings_store.dart';
import '../widgets/app_update_dialog.dart';
import '../theme/workbench_theme.dart';
import '../widgets/code_snippets_sheet.dart';
import '../widgets/connection_sheet.dart';
import '../widgets/health_board_sheet.dart';
import '../widgets/saved_host_connect_sheet.dart';
import '../widgets/session_pane_layout.dart';
import '../widgets/sftp_side_panel.dart';
import '../widgets/workbench_status_bar.dart';
import '../widgets/assistant_side_panel.dart';
import '../widgets/workbench_interface_settings_dialog.dart';
import '../widgets/workbench_llm_settings_dialog.dart';
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
  final CodeSnippetsStore _snippets = CodeSnippetsStore();
  final AppUpdateService _appUpdate = AppUpdateService();
  String? _versionTagLabel;

  /// 侧栏在「已保存连接」与「文件浏览器」之间切换，避免与终端并排占两列宽度。
  _SidebarView _sidebarView = _SidebarView.savedHosts;

  /// 与 [_syncSidebarToFileOnConnect] 配合：仅在当前选中标签「刚连上」时自动切到文件页。
  int? _sidebarSyncTabId;
  bool _sidebarSyncWasConnected = false;

  /// 防止异步连接流程（读密钥、弹凭据层）未完成时重复触发。
  String? _savedConnectBusyProfileId;
  String? _launchConnectBusyKey;

  /// 代码块多终端：待写入内容；非空时进入「点击窗格运行」模式。
  String? _pendingSnippetBody;

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
    unawaited(
      _appUpdate.currentVersionTagLabel().then((label) {
        if (mounted) setState(() => _versionTagLabel = label);
      }),
    );
    if (AppUpdateService.isUpdateEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_checkForUpdatesOnStartup());
      });
    }
  }

  @override
  void dispose() {
    _appUpdate.dispose();
    _tabs.removeListener(_onRepaint);
    _profiles.removeListener(_onRepaint);
    _tabs.dispose();
    _profiles.dispose();
    _snippets.dispose();
    super.dispose();
  }

  Future<void> _checkForUpdatesOnStartup() async {
    if (!mounted) return;
    final result = await _appUpdate.checkForUpdates();
    if (!mounted || !result.hasUpdate) return;
    await showAppUpdateDialog(
      context,
      service: _appUpdate,
      initialResult: result,
    );
  }

  Future<void> _checkForUpdatesManual() async {
    await showAppUpdateDialog(context, service: _appUpdate, manualCheck: true);
  }

  void _openNewHostShortcut() {
    unawaited(_openNewHostSheet());
  }

  void _closeCurrentTabOrWindow() {
    if (_tabs.tabs.isNotEmpty) {
      _tabs.closeFocusedPaneOrTab();
    } else {
      unawaited(workbenchCloseWindow());
    }
  }

  void _duplicateSelectedTab() {
    _tabs.duplicateSelectedTab();
  }

  void _splitRight() {
    _tabs.splitFocusedPane(axis: SessionPaneAxis.horizontal);
  }

  void _splitLeft() {
    _tabs.splitFocusedPane(
      axis: SessionPaneAxis.horizontal,
      placement: SessionSplitPlacement.before,
    );
  }

  void _splitDown() {
    _tabs.splitFocusedPane(axis: SessionPaneAxis.vertical);
  }

  void _splitUp() {
    _tabs.splitFocusedPane(
      axis: SessionPaneAxis.vertical,
      placement: SessionSplitPlacement.before,
    );
  }

  void _openCodeSnippets() {
    unawaited(
      showCodeSnippetsSheet(
        context,
        store: _snippets,
        tabs: _tabs,
        onRequestClickTarget: (body) {
          if (!mounted) return;
          setState(() => _pendingSnippetBody = body);
        },
      ),
    );
  }

  void _cancelSnippetPick() {
    if (_pendingSnippetBody == null) return;
    setState(() => _pendingSnippetBody = null);
  }

  void _completeSnippetPick(int paneId) {
    final body = _pendingSnippetBody;
    if (body == null) return;
    final tab = _tabs.selectedTab;
    if (tab == null) return;
    final leaf = tab.root.findLeaf(paneId);
    if (leaf == null || !leaf.controller.connected) return;
    _tabs.focusPane(_tabs.selectedIndex, paneId);
    leaf.controller.pasteRemoteInputWithLineSubmit(body);
    setState(() => _pendingSnippetBody = null);
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.codeSnippetRan)));
  }

  void _openHealthBoard() {
    unawaited(showHealthBoardSheet(context, tabs: _tabs));
  }

  void _showAboutDialog() {
    final about = AppLocalizations.of(context)!;
    final dialogContext = context;
    final versionLabel = _versionTagLabel;
    if (versionLabel != null) {
      showAboutDialog(
        context: dialogContext,
        applicationName: about.appTitle,
        applicationVersion: versionLabel,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(about.aboutDescription),
          ),
        ],
      );
      return;
    }
    unawaited(
      _appUpdate.currentVersionTagLabel().then((label) {
        if (!dialogContext.mounted) return;
        setState(() => _versionTagLabel = label);
        showAboutDialog(
          context: dialogContext,
          applicationName: about.appTitle,
          applicationVersion: label,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(about.aboutDescription),
            ),
          ],
        );
      }),
    );
  }

  Map<ShortcutActivator, VoidCallback> _shellShortcutBindings() {
    if (!workbenchDesktopShortcutsEnabled()) return const {};
    return {
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyN),
        _openNewHostShortcut,
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.comma),
        _openSettingsMenu,
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyT, shift: true),
        _openNewHostShortcut,
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyD),
        _duplicateSelectedTab,
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyD, shift: true),
        _splitRight,
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyA, shift: true),
        _splitLeft,
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyE, shift: true),
        _splitDown,
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyW, shift: true, alt: true),
        _splitUp,
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyK, shift: true),
        _openCodeSnippets,
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyW),
        _closeCurrentTabOrWindow,
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyW, shift: true),
        _tabs.closeAll,
      ),
      if (_pendingSnippetBody != null)
        const SingleActivator(LogicalKeyboardKey.escape): _cancelSnippetPick,
    };
  }

  Widget _wrapMacPlatformMenu(Widget child) {
    if (!Platform.isMacOS) return child;
    final l10n = AppLocalizations.of(context)!;
    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: l10n.appTitle,
          menus: [
            if (AppUpdateService.isUpdateEnabled)
              PlatformMenuItem(
                label: l10n.menuCheckForUpdates,
                onSelected: () => unawaited(_checkForUpdatesManual()),
              ),
            PlatformMenuItem(
              label: l10n.menuAbout,
              onSelected: _showAboutDialog,
            ),
            PlatformMenuItem(
              label: l10n.settingsTooltip,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.comma,
                meta: true,
              ),
              onSelected: _openSettingsMenu,
            ),
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: l10n.menuQuit,
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyQ,
                    meta: true,
                  ),
                  onSelected: () => unawaited(workbenchQuitApplication()),
                ),
              ],
            ),
          ],
        ),
        PlatformMenu(
          label: l10n.menuFile,
          menus: [
            PlatformMenuItem(
              label: l10n.newConnection,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                meta: true,
              ),
              onSelected: _openNewHostShortcut,
            ),
            PlatformMenuItem(
              label: l10n.menuTabDuplicate,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyD,
                meta: true,
              ),
              onSelected: _duplicateSelectedTab,
            ),
            PlatformMenuItem(
              label: l10n.menuCloseTab,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyW,
                meta: true,
              ),
              onSelected: _closeCurrentTabOrWindow,
            ),
            PlatformMenuItem(
              label: l10n.menuCloseAllSessions,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyW,
                meta: true,
                shift: true,
              ),
              onSelected: _tabs.closeAll,
            ),
          ],
        ),
        PlatformMenu(
          label: l10n.menuView,
          menus: [
            PlatformMenuItem(
              label: l10n.menuSplitRight,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyD,
                meta: true,
                shift: true,
              ),
              onSelected: _splitRight,
            ),
            PlatformMenuItem(
              label: l10n.menuSplitLeft,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyA,
                meta: true,
                shift: true,
              ),
              onSelected: _splitLeft,
            ),
            PlatformMenuItem(
              label: l10n.menuSplitDown,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyE,
                meta: true,
                shift: true,
              ),
              onSelected: _splitDown,
            ),
            PlatformMenuItem(
              label: l10n.menuSplitUp,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyW,
                meta: true,
                shift: true,
                alt: true,
              ),
              onSelected: _splitUp,
            ),
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: l10n.menuCodeSnippets,
                  onSelected: _openCodeSnippets,
                ),
                PlatformMenuItem(
                  label: l10n.menuHealthBoard,
                  onSelected: _openHealthBoard,
                ),
              ],
            ),
          ],
        ),
      ],
      child: child,
    );
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
    final busyKey = '${launch.username}@${launch.host}:${launch.port}';
    if (_launchConnectBusyKey == busyKey) return;
    _launchConnectBusyKey = busyKey;
    try {
      await _persistLaunchAndConnectImpl(launch);
    } finally {
      if (_launchConnectBusyKey == busyKey) {
        _launchConnectBusyKey = null;
      }
    }
  }

  Future<void> _persistLaunchAndConnectImpl(ConnectionLaunch launch) async {
    await _profiles.ensureLoaded();

    final label = launch.deviceLabel ?? '${launch.username}@${launch.host}';
    final updateId = launch.existingProfileId;
    final String? profileIdForAuthUi;
    if (updateId != null) {
      await _profiles.updateById(
        id: updateId,
        label: label,
        host: launch.host,
        port: launch.port,
        username: launch.username,
        keyPath: launch.keyPath,
        password: launch.password.trim().isEmpty
            ? null
            : launch.password.trim(),
      );
      profileIdForAuthUi = updateId;
    } else {
      profileIdForAuthUi = await _profiles.add(
        label: label,
        host: launch.host,
        port: launch.port,
        username: launch.username,
        keyPath: launch.keyPath,
        password: launch.password.trim().isNotEmpty
            ? launch.password.trim()
            : null,
      );
    }

    final c = _tabs.openTab(
      host: launch.host,
      port: launch.port,
      username: launch.username,
      password: launch.password,
      privateKeyPem: launch.privateKeyPem,
    );
    final pid = profileIdForAuthUi;
    if (pid != null) {
      final profile = _profileById(pid);
      if (profile != null) {
        _bindAuthFailureCredentialSheet(profile, launch.privateKeyPem, c);
      }
    }
  }

  SavedHostProfile? _profileById(String id) {
    for (final p in _profiles.profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 连接失败后若为凭据类错误，弹出已保存主机的口令/密钥口令输入层并在当前标签重连。
  void _bindAuthFailureCredentialSheet(
    SavedHostProfile profile,
    String? privateKeyPem,
    SshWorkspaceController c,
  ) {
    var handledOutcome = false;
    void onCred() {
      if (handledOutcome) return;
      if (c.connected) {
        c.removeListener(onCred);
        handledOutcome = true;
        return;
      }
      if (c.connecting) return;

      if (!c.connected) {
        handledOutcome = true;
        c.removeListener(onCred);
        if (c.suggestCredentialSheetAfterFailure) {
          unawaited(
            _retrySavedProfileAfterAuthFailure(profile, privateKeyPem, c),
          );
        }
        return;
      }
    }

    c.addListener(onCred);
  }

  Future<void> _retrySavedProfileAfterAuthFailure(
    SavedHostProfile profile,
    String? privateKeyPem,
    SshWorkspaceController failed,
  ) async {
    if (!_tabs.tabs.any((t) => t.containsController(failed))) return;
    if (!mounted) return;
    // 弹层有时会抢不到 Overlay；让给出一帧再给 context。
    await Future<void>.delayed(Duration.zero);

    if (!mounted) return;
    if (!_tabs.tabs.any((t) => t.containsController(failed))) return;
    final liveProfile = _profileById(profile.id) ?? profile;
    final cred = await showSavedHostConnectSheet(context, liveProfile);
    if (!mounted || cred == null) return;
    if (!_tabs.tabs.any((t) => t.containsController(failed))) return;
    final pemForReconnect = cred.privateKeyPem ?? privateKeyPem;
    await failed.reconnectWithCredentials(
      password: cred.password,
      privateKeyPem: pemForReconnect,
    );
    _bindAuthFailureCredentialSheet(liveProfile, pemForReconnect, failed);
    if (cred.password.trim().isNotEmpty) {
      await _profiles.updateById(
        id: liveProfile.id,
        label: liveProfile.label,
        host: liveProfile.host,
        port: liveProfile.port,
        username: liveProfile.username,
        keyPath: liveProfile.keyPath,
        password: cred.password.trim(),
      );
    }
  }

  Future<void> _connectFromSaved(SavedHostProfile profile) async {
    if (_savedConnectBusyProfileId == profile.id) return;
    _savedConnectBusyProfileId = profile.id;
    try {
      await _connectFromSavedImpl(profile);
    } finally {
      if (_savedConnectBusyProfileId == profile.id) {
        _savedConnectBusyProfileId = null;
      }
    }
  }

  Future<void> _connectFromSavedImpl(SavedHostProfile profile) async {
    await _profiles.ensureLoaded();

    String? pem;
    Object? keyReadFailure;
    try {
      pem = await loadPrivateKeyFromPath(profile.keyPath);
    } catch (e) {
      keyReadFailure = e;
    }
    if (!mounted) return;

    var password = profile.password ?? '';
    final hasKey =
        profile.keyPath != null && profile.keyPath!.trim().isNotEmpty;

    if (hasKey && pem == null && keyReadFailure != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(
              context,
            )!.snackbarPrivateKeyReadFailed('$keyReadFailure'),
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

    _bindAuthFailureCredentialSheet(profile, pem, c);
  }

  Future<void> _deleteSavedProfileWithConfirm(SavedHostProfile profile) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.contextDelete),
        content: Text(l10n.codeSnippetDeleteConfirm(profile.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.codeSnippetCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.contextDelete),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    await _profiles.remove(profile.id);
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
                    builder: (_) => WorkbenchInterfaceSettingsDialog(
                      settings: widget.settings,
                    ),
                  );
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: Text(l10n.menuLlmSettings),
              onTap: () {
                Navigator.pop(ctx);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!context.mounted) return;
                  showDialog<void>(
                    context: context,
                    builder: (_) =>
                        WorkbenchLlmSettingsDialog(settings: widget.settings),
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
                    builder: (_) => WorkbenchTerminalSettingsDialog(
                      settings: widget.settings,
                    ),
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
            if (AppUpdateService.isUpdateEnabled)
              ListTile(
                leading: const Icon(Icons.system_update_outlined),
                title: Text(l10n.menuCheckForUpdates),
                onTap: () {
                  Navigator.pop(ctx);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!context.mounted) return;
                    unawaited(_checkForUpdatesManual());
                  });
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.menuAbout),
              subtitle: _versionTagLabel == null
                  ? null
                  : Text(l10n.aboutCurrentVersion(_versionTagLabel!)),
              onTap: () {
                Navigator.pop(ctx);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!context.mounted) return;
                  _showAboutDialog();
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
    return _wrapMacPlatformMenu(
      CallbackShortcuts(
        bindings: _shellShortcutBindings(),
        child: Scaffold(
          backgroundColor: context.wb.bg,
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _WorkbenchTopBar(
                  onNewHost: _openNewHostSheet,
                  onSettings: _openSettingsMenu,
                  onCodeSnippets: _openCodeSnippets,
                  onHealthBoard: _openHealthBoard,
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
                        onDeleteProfile: _deleteSavedProfileWithConfirm,
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
                            onDuplicate: (i) => _tabs.duplicateTab(i),
                            onSplitRight: _splitRight,
                            onSplitDown: _splitDown,
                          ),
                        if (_pendingSnippetBody != null)
                          _SnippetPickBanner(onCancel: _cancelSnippetPick),
                        Expanded(
                          child: TerminalWithAssistantSplit(
                            settings: widget.settings,
                            sessionTab: _tabs.selectedTab,
                            terminalChild: _rightPane(),
                          ),
                        ),
                        WorkbenchStatusBar(
                          controller: _tabs.selectedTab?.controller,
                        ),
                      ],
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

  Widget _middlePane() {
    final tab = _tabs.selectedTab;
    final c = tab?.controller;
    final l10n = AppLocalizations.of(context)!;
    if (c == null || !c.connected) {
      return _WorkbenchPlaceholder(
        icon: Icons.folder_open_outlined,
        title: l10n.placeholderFileBrowserTitle,
        subtitle: l10n.placeholderFileBrowserSubtitle,
        actionLabel: l10n.newConnection,
        onAction: _openNewHostShortcut,
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
        actionLabel: l10n.newConnection,
        onAction: _openNewHostShortcut,
      );
    }
    return SessionPaneLayout(
      key: ValueKey<Object>('tab-${tab.id}'),
      tabs: _tabs,
      tab: tab,
      tabIndex: _tabs.selectedIndex,
      workbenchSettings: widget.settings,
      pickingSnippetTarget: _pendingSnippetBody != null,
      onPickSnippetTarget: _completeSnippetPick,
    );
  }
}

class _SnippetPickBanner extends StatelessWidget {
  const _SnippetPickBanner({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: context.wb.accentBlue.withValues(alpha: 0.14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              Icons.touch_app_rounded,
              size: 18,
              color: context.wb.accentBlue,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.codeSnippetClickTargetHint,
                style: TextStyle(
                  color: context.wb.primaryText,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            TextButton(
              onPressed: onCancel,
              child: Text(l10n.codeSnippetCancel),
            ),
          ],
        ),
      ),
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
  State<_ResizableSidebarAndTerminal> createState() =>
      _ResizableSidebarAndTerminalState();
}

class _ResizableSidebarAndTerminalState
    extends State<_ResizableSidebarAndTerminal> {
  static const double _splitterW = 5;
  static const double _minSidebar = 200;
  static const double _minTerminal = 280;
  static const double _maxSidebar = 520;

  /// 合并原左栏与中栏后，默认略宽以便文件列表可读；终端仍占剩余空间。
  double _sidebarW = 300;

  double? _lastTotalWidth;

  void _syncToLayout(double total) {
    final maxSidebar = (total - _splitterW - _minTerminal).clamp(
      _minSidebar,
      _maxSidebar,
    );
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
      final maxSidebar = (total - _splitterW - _minTerminal).clamp(
        _minSidebar,
        _maxSidebar,
      );
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
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: context.wb.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: context.wb.border)),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.wb.panelElevated.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context.wb.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _SidebarSwitchButton(
                      selected: view == _SidebarView.savedHosts,
                      tooltip: l10n.sidebarSavedHostsTooltip,
                      icon: Icons.dns_outlined,
                      onPressed: () => onViewChanged(_SidebarView.savedHosts),
                    ),
                  ),
                  Expanded(
                    child: _SidebarSwitchButton(
                      selected: view == _SidebarView.fileBrowser,
                      tooltip: l10n.sidebarFilesTooltip,
                      icon: Icons.folder_open_outlined,
                      onPressed: () => onViewChanged(_SidebarView.fileBrowser),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 140),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: KeyedSubtree(
                key: ValueKey<_SidebarView>(view),
                child: view == _SidebarView.savedHosts
                    ? savedHosts
                    : fileBrowser,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarSwitchButton extends StatelessWidget {
  const _SidebarSwitchButton({
    required this.selected,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final bool selected;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: 30,
            decoration: BoxDecoration(
              color: selected
                  ? context.wb.accentBlue.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: selected
                  ? Border.all(
                      color: context.wb.accentBlue.withValues(alpha: 0.34),
                    )
                  : null,
            ),
            child: Icon(
              icon,
              size: 18,
              color: selected ? context.wb.primaryText : context.wb.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkbenchColumnSplitter extends StatelessWidget {
  const _WorkbenchColumnSplitter({required this.width, required this.onDrag});

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
          child: Center(child: Container(width: 1, color: context.wb.border)),
        ),
      ),
    );
  }
}

class _WorkbenchTopBar extends StatelessWidget {
  const _WorkbenchTopBar({
    required this.onNewHost,
    required this.onSettings,
    required this.onCodeSnippets,
    required this.onHealthBoard,
  });

  final VoidCallback onNewHost;
  final VoidCallback onSettings;
  final VoidCallback onCodeSnippets;
  final VoidCallback onHealthBoard;

  @override
  Widget build(BuildContext context) {
    final capLeft = !kIsWeb && Platform.isMacOS
        ? MediaQuery.viewPaddingOf(context).left
        : 0.0;
    final chrome = workbenchUsesCustomWindowChrome();
    final macChrome = chrome && Platform.isMacOS;
    final leftPad = macChrome ? 8.0 + capLeft : 12.0 + capLeft;

    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: context.wb.topBar,
      elevation: 0,
      child: Container(
        height: 54,
        padding: EdgeInsets.fromLTRB(leftPad, 0, 10, 0),
        decoration: BoxDecoration(
          color: context.wb.topBar,
          border: Border(bottom: BorderSide(color: context.wb.topBarDivider)),
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
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: context.wb.accentBlue.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: context.wb.accentBlue.withValues(alpha: 0.24),
                ),
              ),
              child: Icon(
                Icons.terminal_rounded,
                color: context.wb.accentBlue,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              l10n.appBarTitle,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: context.wb.primaryText,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(width: 8),
            if (chrome)
              Expanded(child: DragToMoveArea(child: const SizedBox(height: 54)))
            else
              const Spacer(),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: context.wb.accentBlue,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 14),
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
            const SizedBox(width: 8),
            _ToolbarIconButton(
              tooltip: l10n.menuCodeSnippets,
              onPressed: onCodeSnippets,
              icon: Icons.code_rounded,
            ),
            _ToolbarIconButton(
              tooltip: l10n.menuHealthBoard,
              onPressed: onHealthBoard,
              icon: Icons.monitor_heart_outlined,
            ),
            _ToolbarIconButton(
              tooltip: l10n.settingsTooltip,
              onPressed: onSettings,
              icon: Icons.settings_outlined,
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

class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: context.wb.panelElevated.withValues(alpha: 0.56),
          foregroundColor: context.wb.textMuted,
          hoverColor: context.wb.primaryText.withValues(alpha: 0.07),
        ),
        icon: Icon(icon, size: 18),
      ),
    );
  }
}

class _WorkbenchPlaceholder extends StatelessWidget {
  const _WorkbenchPlaceholder({
    required this.icon,
    this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String? title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

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
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: context.wb.panelElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.wb.border),
                ),
                child: Icon(
                  icon,
                  size: 26,
                  color: context.wb.textMuted.withValues(alpha: 0.78),
                ),
              ),
              if (title != null && title!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  title!,
                  style: TextStyle(
                    color: context.wb.primaryText,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
              ] else
                const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.wb.textMuted,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
              if (onAction != null && actionLabel != null) ...[
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(actionLabel!),
                ),
              ],
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
    required this.onDuplicate,
    required this.onSplitRight,
    required this.onSplitDown,
  });

  final SessionTabsController tabs;
  final void Function(int index) onSelect;
  final void Function(int index) onClose;
  final void Function(int index) onDuplicate;
  final VoidCallback onSplitRight;
  final VoidCallback onSplitDown;

  @override
  State<_WorkspaceSessionTabBar> createState() =>
      _WorkspaceSessionTabBarState();
}

class _WorkspaceSessionTabBarState extends State<_WorkspaceSessionTabBar> {
  final ScrollController _scrollController = ScrollController();
  List<GlobalKey> _itemKeys = [];
  int _lastSelectionForScroll = -1;
  int _lastTabCount = -1;

  void _showTabContextMenu(
    BuildContext context,
    Offset globalPosition,
    int index,
  ) {
    final tabs = widget.tabs;
    final l10n = AppLocalizations.of(context)!;
    final n = tabs.tabs.length;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final topLeft = overlay.localToGlobal(Offset.zero);
    final rel = RelativeRect.fromLTRB(
      globalPosition.dx - topLeft.dx,
      globalPosition.dy - topLeft.dy,
      globalPosition.dx - topLeft.dx + 1,
      globalPosition.dy - topLeft.dy + 1,
    );
    widget.onSelect(index);
    showMenu<String>(
      context: context,
      position: rel,
      color: context.wb.panelElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: context.wb.border),
      ),
      items: [
        PopupMenuItem(value: 'duplicate', child: Text(l10n.menuTabDuplicate)),
        PopupMenuItem(value: 'splitRight', child: Text(l10n.menuSplitRight)),
        PopupMenuItem(value: 'splitLeft', child: Text(l10n.menuSplitLeft)),
        PopupMenuItem(value: 'splitDown', child: Text(l10n.menuSplitDown)),
        PopupMenuItem(value: 'splitUp', child: Text(l10n.menuSplitUp)),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'left',
          enabled: index > 0,
          child: Text(l10n.menuTabCloseLeft),
        ),
        PopupMenuItem(
          value: 'others',
          enabled: n > 1,
          child: Text(l10n.menuTabCloseOthers),
        ),
        PopupMenuItem(
          value: 'all',
          enabled: n > 0,
          child: Text(l10n.menuTabCloseAll),
        ),
        PopupMenuItem(
          value: 'right',
          enabled: index < n - 1,
          child: Text(l10n.menuTabCloseRight),
        ),
      ],
    ).then((v) {
      if (!context.mounted || v == null) return;
      switch (v) {
        case 'duplicate':
          widget.onDuplicate(index);
          return;
        case 'splitRight':
          widget.onSelect(index);
          widget.onSplitRight();
          return;
        case 'splitLeft':
          widget.onSelect(index);
          widget.tabs.splitFocusedPane(
            axis: SessionPaneAxis.horizontal,
            placement: SessionSplitPlacement.before,
          );
          return;
        case 'splitDown':
          widget.onSelect(index);
          widget.onSplitDown();
          return;
        case 'splitUp':
          widget.onSelect(index);
          widget.tabs.splitFocusedPane(
            axis: SessionPaneAxis.vertical,
            placement: SessionSplitPlacement.before,
          );
          return;
        case 'left':
          tabs.closeTabsToLeftOf(index);
          return;
        case 'right':
          tabs.closeTabsToRightOf(index);
          return;
        case 'others':
          tabs.closeOtherTabs(index);
          return;
        case 'all':
          tabs.closeAll();
          return;
      }
    });
  }

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
    final l10n = AppLocalizations.of(context)!;
    Widget buildTab(SessionTab t, int i) {
      final selected = i == tabs.selectedIndex;
      return KeyedSubtree(
        key: _itemKeys[i],
        child: Listener(
          onPointerDown: (e) {
            if (e.buttons == kMiddleMouseButton) {
              widget.onSelect(i);
              widget.onClose(i);
            }
          },
          child: GestureDetector(
            onTap: () => widget.onSelect(i),
            onSecondaryTapUp: (d) =>
                _showTabContextMenu(context, d.globalPosition, i),
            child: Material(
              color: selected
                  ? context.wb.accentBlue.withValues(alpha: 0.18)
                  : context.wb.panel,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected
                        ? context.wb.accentBlue.withValues(alpha: 0.32)
                        : context.wb.border.withValues(alpha: 0.55),
                  ),
                ),
                padding: const EdgeInsets.only(left: 4, right: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.circle,
                            size: 7,
                            color: _sessionStatusDot(context, t.controller),
                          ),
                          const SizedBox(width: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 180),
                            child: Text(
                              t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: selected
                                    ? context.wb.primaryText
                                    : context.wb.secondaryText,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      visualDensity: VisualDensity.compact,
                      tooltip: l10n.menuTabDuplicate,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () {
                        widget.onSelect(i);
                        widget.onDuplicate(i);
                      },
                      icon: Icon(
                        Icons.copy_all_outlined,
                        size: 14,
                        color: context.wb.textMuted,
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      visualDensity: VisualDensity.compact,
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonLabel,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => widget.onClose(i),
                      icon: Icon(
                        Icons.close_rounded,
                        size: 15,
                        color: context.wb.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: context.wb.panelElevated,
      child: SizedBox(
        height: 38,
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
            return Row(
              children: [
                Expanded(
                  child: Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: true,
                    trackVisibility: true,
                    thickness: 4,
                    radius: const Radius.circular(3),
                    // 否则会拦截底部区域的点击，用户常误以为「关不掉标签」。
                    interactive: false,
                    child: ListView.separated(
                      controller: _scrollController,
                      primary: false,
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      itemCount: tabs.tabs.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 3),
                      itemBuilder: (context, i) => buildTab(tabs.tabs[i], i),
                    ),
                  ),
                ),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: context.wb.border,
                ),
                IconButton(
                  tooltip: l10n.menuTabDuplicate,
                  visualDensity: VisualDensity.compact,
                  onPressed: tabs.tabs.isEmpty
                      ? null
                      : () => widget.onDuplicate(tabs.selectedIndex),
                  icon: Icon(
                    Icons.copy_all_outlined,
                    size: 16,
                    color: context.wb.textMuted,
                  ),
                ),
                IconButton(
                  tooltip: l10n.menuSplitRight,
                  visualDensity: VisualDensity.compact,
                  onPressed: tabs.tabs.isEmpty ? null : widget.onSplitRight,
                  icon: Icon(
                    Icons.vertical_split_outlined,
                    size: 16,
                    color: context.wb.textMuted,
                  ),
                ),
                IconButton(
                  tooltip: l10n.menuSplitDown,
                  visualDensity: VisualDensity.compact,
                  onPressed: tabs.tabs.isEmpty ? null : widget.onSplitDown,
                  icon: Icon(
                    Icons.horizontal_split_outlined,
                    size: 16,
                    color: context.wb.textMuted,
                  ),
                ),
                const SizedBox(width: 4),
              ],
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
  final Future<void> Function(SavedHostProfile profile) onDeleteProfile;

  static bool _anyConnectedTab(SessionTabsController tabs, SavedHostProfile p) {
    for (final t in tabs.tabs) {
      for (final leaf in t.root.leaves) {
        final c = leaf.controller;
        if (p.matchesEndpoint(
              host: c.host,
              port: c.port,
              username: c.username,
            ) &&
            c.connected) {
          return true;
        }
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
          final total = profiles.profiles.length;
          final online = profiles.profiles
              .where((p) => _anyConnectedTab(tabs, p))
              .length;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.savedConnectionsHeader,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: context.wb.textMuted,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0,
                              ),
                        ),
                      ),
                      if (total > 0)
                        Text(
                          '$online/$total',
                          style: TextStyle(
                            color: context.wb.textMuted,
                            fontSize: 11,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (profiles.profiles.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                    child: _SidebarEmptyHint(text: l10n.savedConnectionsEmpty),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate((context, i) {
                      final p = profiles.profiles[i];
                      return _RailSavedTile(
                        profile: p,
                        online: _anyConnectedTab(tabs, p),
                        onTap: () => onTapProfile(p),
                        onEdit: () => onEditProfile(p),
                        onDelete: () => onDeleteProfile(p),
                      );
                    }, childCount: profiles.profiles.length),
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

class _SidebarEmptyHint extends StatelessWidget {
  const _SidebarEmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.wb.panelElevated.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.wb.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          text,
          style: TextStyle(
            color: context.wb.textMuted.withValues(alpha: 0.9),
            fontSize: 12,
            height: 1.4,
          ),
        ),
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
  final Future<void> Function() onDelete;

  static void _showContextMenu(
    BuildContext context,
    Offset globalPosition,
    _RailSavedTile tile,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
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
      color: context.wb.panelElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: context.wb.border),
      ),
      items: [
        PopupMenuItem(value: 'open', child: Text(l10n.contextOpenSession)),
        PopupMenuItem(value: 'edit', child: Text(l10n.contextEdit)),
        PopupMenuItem(
          value: 'del',
          child: Text(
            l10n.contextDelete,
            style: TextStyle(color: Colors.red.shade300),
          ),
        ),
      ],
    ).then((v) {
      if (v == 'open') unawaited(tile.onTap());
      if (v == 'edit') unawaited(tile.onEdit());
      if (v == 'del') unawaited(tile.onDelete());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final dot = online ? context.wb.online : context.wb.offline;

    return GestureDetector(
      onSecondaryTapUp: (d) =>
          _showContextMenu(context, d.globalPosition, this),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onTap(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                      boxShadow: online
                          ? [
                              BoxShadow(
                                color: dot.withValues(alpha: 0.32),
                                blurRadius: 8,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.wb.primaryText,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          profile.subtitle,
                          maxLines: 1,
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
                  PopupMenuButton<String>(
                    tooltip: l10n.paneMenuTooltip,
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      color: context.wb.textMuted,
                    ),
                    onSelected: (value) {
                      switch (value) {
                        case 'open':
                          unawaited(onTap());
                          return;
                        case 'edit':
                          unawaited(onEdit());
                          return;
                        case 'del':
                          unawaited(onDelete());
                          return;
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'open',
                        child: Text(l10n.contextOpenSession),
                      ),
                      PopupMenuItem(
                        value: 'edit',
                        child: Text(l10n.contextEdit),
                      ),
                      PopupMenuItem(
                        value: 'del',
                        child: Text(
                          l10n.contextDelete,
                          style: TextStyle(color: Colors.red.shade300),
                        ),
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
}
