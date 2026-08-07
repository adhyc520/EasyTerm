import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/remote_users.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';

/// 用户与组：当前登录、最近登录、passwd 账户列表。
class UsersApp extends StatefulWidget {
  const UsersApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<UsersApp> createState() => _UsersAppState();
}

class _UsersAppState extends State<UsersApp>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  RemoteUsersSnapshot? _snap;
  bool _loading = false;
  String? _error;
  bool _hideSystem = true;
  String _filter = '';
  final _filterCtrl = TextEditingController();

  bool get _connected =>
      widget.controller.connected && !widget.controller.dropped;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    widget.window.onConnectionRestored = _onRestored;
    unawaited(_reload());
  }

  @override
  void dispose() {
    widget.window.onConnectionRestored = null;
    _tabs.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  void _onRestored() {
    if (!mounted) return;
    setState(() => _error = null);
    unawaited(_reload());
  }

  Future<void> _reload() async {
    if (!_connected) {
      setState(() {
        _error = '连接已断开';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final snap = await fetchRemoteUsers(widget.controller);
    if (!mounted) return;
    if (snap == null) {
      setState(() {
        _loading = false;
        _error = widget.controller.lastRemoteCommandError == null
            ? '无法获取用户信息'
            : '刷新失败：${widget.controller.lastRemoteCommandError}';
      });
      return;
    }
    setState(() {
      _snap = snap;
      _loading = false;
      _error = snap.error;
    });
  }

  List<RemotePasswdEntry> get _accounts {
    final all = _snap?.accounts ?? const [];
    final q = _filter.trim().toLowerCase();
    return [
      for (final a in all)
        if ((!_hideSystem || !a.isSystem) &&
            (q.isEmpty ||
                a.name.toLowerCase().contains(q) ||
                a.home.toLowerCase().contains(q) ||
                a.shell.toLowerCase().contains(q)))
          a,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final snap = _snap;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
          child: Row(
            children: [
              Text(
                '用户与组',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: wb.primaryText,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                onPressed:
                    _connected && !_loading ? () => unawaited(_reload()) : null,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabs,
          labelColor: wb.accentBlue,
          unselectedLabelColor: wb.textMuted,
          indicatorColor: wb.accentBlue,
          tabs: [
            Tab(
              text:
                  '在线 (${snap?.loggedIn.length ?? 0})',
            ),
            Tab(text: '最近登录'),
            Tab(text: '账户'),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(_error!, style: TextStyle(color: Colors.red.shade300, fontSize: 12)),
          ),
        Expanded(
          child: _loading && snap == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _loggedInList(wb, snap?.loggedIn ?? const []),
                    _recentList(wb, snap?.recent ?? const []),
                    _accountsPane(wb),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _loggedInList(WorkbenchColors wb, List<RemoteLoggedInUser> items) {
    if (items.isEmpty) {
      return Center(
        child: Text('当前无登录会话', style: TextStyle(color: wb.textMuted)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final u = items[i];
        return ListTile(
          dense: true,
          leading: Icon(Icons.person_rounded, size: 18, color: wb.accentBlue),
          title: Text(u.user, style: TextStyle(color: wb.primaryText, fontSize: 13)),
          subtitle: Text(
            [
              u.tty,
              if (u.host.isNotEmpty) u.host,
              if (u.since.isNotEmpty) u.since,
            ].join(' · '),
            style: TextStyle(fontSize: 11, color: wb.textMuted),
          ),
        );
      },
    );
  }

  Widget _recentList(WorkbenchColors wb, List<RemoteLoginRecord> items) {
    if (items.isEmpty) {
      return Center(
        child: Text('无最近登录记录', style: TextStyle(color: wb.textMuted)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final u = items[i];
        return ListTile(
          dense: true,
          leading: Icon(Icons.history_rounded, size: 18, color: wb.textMuted),
          title: Text(u.user, style: TextStyle(color: wb.primaryText, fontSize: 13)),
          subtitle: Text(
            [
              u.tty,
              if (u.host.isNotEmpty) u.host,
              if (u.when.isNotEmpty) u.when,
            ].join(' · '),
            style: TextStyle(fontSize: 11, color: wb.textMuted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }

  Widget _accountsPane(WorkbenchColors wb) {
    final items = _accounts;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _filterCtrl,
                  autofocus: true,
                  onChanged: (v) => setState(() => _filter = v),
                  style: TextStyle(fontSize: 12, color: wb.primaryText),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '筛选用户名 / home / shell',
                    hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
                    prefixIcon: Icon(Icons.search, size: 16, color: wb.textMuted),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('隐藏系统', style: TextStyle(fontSize: 11)),
                selected: _hideSystem,
                onSelected: (v) => setState(() => _hideSystem = v),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text('无匹配账户', style: TextStyle(color: wb.textMuted)),
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final a = items[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        a.isSystem
                            ? Icons.settings_rounded
                            : Icons.account_circle_rounded,
                        size: 18,
                        color: a.isSystem ? wb.textMuted : wb.accentBlue,
                      ),
                      title: Text(
                        '${a.name}  ·  uid ${a.uid}',
                        style: TextStyle(color: wb.primaryText, fontSize: 12),
                      ),
                      subtitle: Text(
                        '${a.home}  ·  ${a.shell}',
                        style: TextStyle(fontSize: 11, color: wb.textMuted),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
