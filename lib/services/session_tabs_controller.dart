import 'dart:async';

import 'package:flutter/foundation.dart';

import '../desktop/desktop_window_manager.dart';
import 'assistant_chat_session.dart';
import 'session_pane.dart';
import 'ssh_workspace_controller.dart';
import 'workbench_settings_store.dart';

enum SessionViewMode { terminal, desktop }

class SessionTab {
  SessionTab({
    required this.id,
    required SshWorkspaceController controller,
    required int paneId,
  }) : root = SessionPaneLeaf(paneId: paneId, controller: controller),
       focusedPaneId = paneId,
       assistant = AssistantChatSession();

  final int id;
  SessionPaneNode root;
  int focusedPaneId;
  final AssistantChatSession assistant;
  SessionViewMode viewMode = SessionViewMode.terminal;
  DesktopWindowManager? _desktop;

  DesktopWindowManager? get desktopWindowManager => _desktop;

  /// 当前焦点窗格的控制器（侧栏 SFTP / 助手 / 状态栏共用）。
  SshWorkspaceController get controller {
    final leaf = root.findLeaf(focusedPaneId) ?? root.leaves.first;
    return leaf.controller;
  }

  String get title {
    final base = '${controller.username}@${controller.host}';
    if (!hasSplit) return base;
    final n = root.leaves.length;
    return '$base ($n)';
  }

  bool get hasSplit => root is SessionPaneSplit;

  bool containsController(SshWorkspaceController c) {
    for (final leaf in root.leaves) {
      if (identical(leaf.controller, c)) return true;
    }
    return false;
  }

  void focusPane(int paneId) {
    if (root.containsPaneId(paneId)) {
      focusedPaneId = paneId;
    }
  }

  void ensureFocusValid() {
    if (!root.containsPaneId(focusedPaneId)) {
      focusedPaneId = root.leaves.first.paneId;
    }
  }
}

/// 多标签 SSH 会话：每个标签内可分屏，每个窗格独立 [SshWorkspaceController]。
class SessionTabsController extends ChangeNotifier {
  SessionTabsController({required this.settings});

  final WorkbenchSettingsStore settings;

  final List<SessionTab> _tabs = [];
  int _selectedIndex = 0;
  int _idSeq = 1;
  int _paneIdSeq = 1;

  List<SessionTab> get tabs => List.unmodifiable(_tabs);

  /// 短时间内重复点击（如双击）时只打开一个标签，与目标主机无关。
  static const Duration _openTabDebounce = Duration(milliseconds: 500);

  DateTime? _lastOpenTabAt;
  SshWorkspaceController? _lastOpenedController;

  int get selectedIndex {
    if (_tabs.isEmpty) return 0;
    return _selectedIndex.clamp(0, _tabs.length - 1);
  }

  SessionTab? get selectedTab => _tabs.isEmpty ? null : _tabs[selectedIndex];

  void _onTabNotify() => notifyListeners();

  SshWorkspaceController _spawnController({
    required String host,
    required int port,
    required String username,
    required String password,
    String? privateKeyPem,
  }) {
    final c = SshWorkspaceController(
      settings: settings,
      host: host,
      port: port,
      username: username,
      password: password,
      privateKeyPem: privateKeyPem,
    );
    c.addListener(_onTabNotify);
    return c;
  }

  void _connectInBackground(SshWorkspaceController c) {
    unawaited(
      c.connect().whenComplete(() {
        if (_tabs.any((t) => t.containsController(c))) {
          notifyListeners();
        }
      }),
    );
  }

  /// 打开新标签并后台连接；返回该标签的 [SshWorkspaceController]。
  SshWorkspaceController openTab({
    required String host,
    required int port,
    required String username,
    required String password,
    String? privateKeyPem,
    bool bypassDebounce = false,
  }) {
    final now = DateTime.now();

    if (!bypassDebounce &&
        _lastOpenTabAt != null &&
        _lastOpenedController != null &&
        now.difference(_lastOpenTabAt!) < _openTabDebounce) {
      for (var i = 0; i < _tabs.length; i++) {
        if (_tabs[i].containsController(_lastOpenedController!)) {
          _selectedIndex = i;
          notifyListeners();
          break;
        }
      }
      return _lastOpenedController!;
    }

    _lastOpenTabAt = now;

    final c = _spawnController(
      host: host,
      port: port,
      username: username,
      password: password,
      privateKeyPem: privateKeyPem,
    );
    final tab = SessionTab(id: _idSeq++, controller: c, paneId: _paneIdSeq++);
    _tabs.add(tab);
    _selectedIndex = _tabs.length - 1;
    _lastOpenedController = c;
    notifyListeners();
    _connectInBackground(c);
    return c;
  }

  /// 复制 [index] 标签为新标签并重新连接（同主机凭据，独立会话）。
  SshWorkspaceController? duplicateTab(int index) {
    if (index < 0 || index >= _tabs.length) return null;
    final src = _tabs[index].controller;
    return openTab(
      host: src.host,
      port: src.port,
      username: src.username,
      password: src.password,
      privateKeyPem: src.privateKeyPem,
      bypassDebounce: true,
    );
  }

  /// 复制当前选中标签。
  SshWorkspaceController? duplicateSelectedTab() {
    if (_tabs.isEmpty) return null;
    return duplicateTab(selectedIndex);
  }

  /// 在焦点窗格旁分屏，新窗格用同主机凭据新建连接。
  SshWorkspaceController? splitFocusedPane({
    required SessionPaneAxis axis,
    SessionSplitPlacement placement = SessionSplitPlacement.after,
  }) {
    final tab = selectedTab;
    if (tab == null) return null;
    return splitPane(
      tabIndex: selectedIndex,
      targetPaneId: tab.focusedPaneId,
      axis: axis,
      placement: placement,
    );
  }

  SshWorkspaceController? splitPane({
    required int tabIndex,
    required int targetPaneId,
    required SessionPaneAxis axis,
    SessionSplitPlacement placement = SessionSplitPlacement.after,
  }) {
    if (tabIndex < 0 || tabIndex >= _tabs.length) return null;
    final tab = _tabs[tabIndex];
    final target = tab.root.findLeaf(targetPaneId);
    if (target == null) return null;

    final src = target.controller;
    final c = _spawnController(
      host: src.host,
      port: src.port,
      username: src.username,
      password: src.password,
      privateKeyPem: src.privateKeyPem,
    );
    final newLeaf = SessionPaneLeaf(paneId: _paneIdSeq++, controller: c);
    tab.root = splitLeaf(
      root: tab.root,
      targetPaneId: targetPaneId,
      newLeaf: newLeaf,
      axis: axis,
      placement: placement,
    );
    tab.focusedPaneId = newLeaf.paneId;
    notifyListeners();
    _connectInBackground(c);
    return c;
  }

  void focusPane(int tabIndex, int paneId) {
    if (tabIndex < 0 || tabIndex >= _tabs.length) return;
    final tab = _tabs[tabIndex];
    if (!tab.root.containsPaneId(paneId)) return;
    tab.focusPane(paneId);
    notifyListeners();
  }

  void setSplitRatio(SessionPaneSplit split, double ratio) {
    split.ratio = ratio.clamp(0.15, 0.85);
    notifyListeners();
  }

  /// 关闭窗格；若为标签内最后一个窗格则关闭整个标签。
  void closePane(int tabIndex, int paneId) {
    if (tabIndex < 0 || tabIndex >= _tabs.length) return;
    final tab = _tabs[tabIndex];
    final leaf = tab.root.findLeaf(paneId);
    if (leaf == null) return;

    final onlyOne = tab.root is SessionPaneLeaf;
    if (onlyOne) {
      closeTab(tabIndex);
      return;
    }

    leaf.controller.removeListener(_onTabNotify);
    leaf.controller.dispose();
    final next = tab.root.removeLeaf(paneId);
    if (next == null) {
      closeTab(tabIndex);
      return;
    }
    tab.root = next;
    tab.ensureFocusValid();
    notifyListeners();
  }

  /// 关闭当前焦点窗格（或无分屏时关闭标签）。
  void closeFocusedPaneOrTab() {
    final tab = selectedTab;
    if (tab == null) return;
    closePane(selectedIndex, tab.focusedPaneId);
  }

  void selectTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    _selectedIndex = index;
    notifyListeners();
  }

  static String hostKeyFor(SessionTab tab) {
    final c = tab.controller;
    return '${c.username}@${c.host}:${c.port}';
  }

  /// 切换标签视图模式（终端 / 可视化桌面）。桌面管理器懒创建；进入桌面从空桌面开始。
  void setViewMode(int tabIndex, SessionViewMode mode) {
    if (tabIndex < 0 || tabIndex >= _tabs.length) return;
    final t = _tabs[tabIndex];
    if (t.viewMode == mode) return;
    t.viewMode = mode;
    if (mode == SessionViewMode.desktop) {
      t._desktop ??= DesktopWindowManager(
        controller: t.controller,
        hostKey: hostKeyFor(t),
        settings: settings,
      );
      unawaited(t._desktop!.prepareFreshDesktop());
    } else {
      // 退出桌面：清窗口，不持久化布局；主 shell / 终端缓冲仍保留
      unawaited(t._desktop?.leaveDesktop());
    }
    notifyListeners();
  }

  void closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    _disposeTabResources(tab);
    _tabs.removeAt(index);
    if (_tabs.isEmpty) {
      _selectedIndex = 0;
    } else if (_selectedIndex >= _tabs.length) {
      _selectedIndex = _tabs.length - 1;
    } else if (index < _selectedIndex) {
      _selectedIndex -= 1;
    }
    notifyListeners();
  }

  /// 关闭 [index] 左侧的全部标签，并选中 [index]。
  void closeTabsToLeftOf(int index) {
    if (index <= 0 || index >= _tabs.length) return;
    for (var i = index - 1; i >= 0; i--) {
      _disposeTabResources(_tabs[i]);
    }
    _tabs.removeRange(0, index);
    _selectedIndex = 0;
    notifyListeners();
  }

  /// 关闭 [index] 右侧的全部标签，并选中 [index]。
  void closeTabsToRightOf(int index) {
    if (index < 0 || index >= _tabs.length - 1) return;
    for (var i = _tabs.length - 1; i > index; i--) {
      _disposeTabResources(_tabs[i]);
    }
    _tabs.removeRange(index + 1, _tabs.length);
    if (_selectedIndex > index) _selectedIndex = index;
    notifyListeners();
  }

  /// 仅保留 [index] 标签。
  void closeOtherTabs(int index) {
    if (index < 0 || index >= _tabs.length || _tabs.length <= 1) return;
    final keep = _tabs[index];
    for (var i = 0; i < _tabs.length; i++) {
      if (i != index) _disposeTabResources(_tabs[i]);
    }
    _tabs
      ..clear()
      ..add(keep);
    _selectedIndex = 0;
    notifyListeners();
  }

  void _disposeTabResources(SessionTab tab) {
    tab._desktop?.dispose();
    tab._desktop = null;
    tab.assistant.dispose();
    for (final leaf in tab.root.leaves) {
      leaf.controller.removeListener(_onTabNotify);
      leaf.controller.dispose();
    }
  }

  void closeAll() {
    _stripAllTabs();
    notifyListeners();
  }

  void _stripAllTabs() {
    for (final t in _tabs) {
      _disposeTabResources(t);
    }
    _tabs.clear();
    _selectedIndex = 0;
  }

  @override
  void dispose() {
    _stripAllTabs();
    super.dispose();
  }
}
