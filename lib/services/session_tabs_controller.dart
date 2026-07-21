import 'dart:async';

import 'package:flutter/foundation.dart';

import 'assistant_chat_session.dart';
import 'ssh_workspace_controller.dart';
import 'workbench_settings_store.dart';

class SessionTab {
  SessionTab({required this.id, required this.controller})
    : assistant = AssistantChatSession();

  final int id;
  final SshWorkspaceController controller;
  final AssistantChatSession assistant;

  String get title => '${controller.username}@${controller.host}';
}

/// 多标签 SSH 会话：每个标签独立 [SshWorkspaceController]，关闭标签即释放连接。
class SessionTabsController extends ChangeNotifier {
  SessionTabsController({required this.settings});

  final WorkbenchSettingsStore settings;

  final List<SessionTab> _tabs = [];
  int _selectedIndex = 0;
  int _idSeq = 1;

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

  /// 打开新标签并后台连接；返回该标签的 [SshWorkspaceController]。
  SshWorkspaceController openTab({
    required String host,
    required int port,
    required String username,
    required String password,
    String? privateKeyPem,
  }) {
    final now = DateTime.now();

    if (_lastOpenTabAt != null &&
        _lastOpenedController != null &&
        now.difference(_lastOpenTabAt!) < _openTabDebounce) {
      for (var i = 0; i < _tabs.length; i++) {
        if (identical(_tabs[i].controller, _lastOpenedController)) {
          _selectedIndex = i;
          notifyListeners();
          break;
        }
      }
      return _lastOpenedController!;
    }

    _lastOpenTabAt = now;

    final c = SshWorkspaceController(
      settings: settings,
      host: host,
      port: port,
      username: username,
      password: password,
      privateKeyPem: privateKeyPem,
    );
    c.addListener(_onTabNotify);
    final tab = SessionTab(id: _idSeq++, controller: c);
    _tabs.add(tab);
    _selectedIndex = _tabs.length - 1;
    _lastOpenedController = c;
    notifyListeners();
    unawaited(
      c.connect().whenComplete(() {
        if (_tabs.any((t) => identical(t.controller, c))) {
          notifyListeners();
        }
      }),
    );
    return c;
  }

  void selectTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    _selectedIndex = index;
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
    tab.assistant.dispose();
    tab.controller.removeListener(_onTabNotify);
    tab.controller.dispose();
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
