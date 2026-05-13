import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ssh_workspace_controller.dart';
import 'workbench_settings_store.dart';

class SessionTab {
  SessionTab({required this.id, required this.controller});

  final int id;
  final SshWorkspaceController controller;

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
    tab.controller.removeListener(_onTabNotify);
    tab.controller.dispose();
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

  void closeAll() {
    _stripAllTabs();
    notifyListeners();
  }

  void _stripAllTabs() {
    for (final t in _tabs) {
      t.controller.removeListener(_onTabNotify);
      t.controller.dispose();
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
