import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/remote_sudo.dart';
import '../../services/remote_users.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../widgets/destructive_action_dialog.dart';
import '../../widgets/remote_state_view.dart';
import '../../widgets/sudo_password_dialog.dart';
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
  bool _busy = false;
  String? _error;
  bool _hideSystem = true;
  String _filter = '';
  final _filterCtrl = TextEditingController();

  int? _uidMinOverride;
  final _uidMinCtrl = TextEditingController();

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
    _uidMinCtrl.dispose();
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

  int get _uidMin => _uidMinOverride ?? _snap?.uidMin ?? 1000;

  List<RemotePasswdEntry> get _accounts {
    final all = _snap?.accounts ?? const [];
    final q = _filter.trim().toLowerCase();
    final uidMin = _uidMin;
    return [
      for (final a in all)
        if ((!_hideSystem || !a.isSystem(uidMin)) &&
            (q.isEmpty ||
                a.name.toLowerCase().contains(q) ||
                a.home.toLowerCase().contains(q) ||
                a.shell.toLowerCase().contains(q) ||
                (a.groupName?.toLowerCase().contains(q) ?? false) ||
                a.groups.any((g) => g.toLowerCase().contains(q))))
          a,
    ];
  }

  Future<void> _mutate(
    String cmd, {
    required String hint,
    List<int>? stdinPayload,
  }) async {
    if (!_connected || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await runWithSudoPasswordPrompt(
      context,
      widget.controller,
      attempt: (sudoPassword) => runUsersMutate(
        widget.controller,
        cmd,
        terminalHint: hint,
        sudoPassword: sudoPassword,
        stdinPayload: stdinPayload,
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (RemoteSudo.isCancelled(err)) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    await _reload();
  }

  Future<void> _createUser() async {
    final result = await showDialog<({String name, String? password})>(
      context: context,
      builder: (ctx) => const _UserCreateDialog(),
    );
    if (result == null || !mounted) return;
    if (!isSafeUsername(result.name)) {
      setState(() => _error = '非法用户名');
      return;
    }
    final ok = await confirmDestructiveAction(
      context,
      title: '新建用户',
      body: result.password != null && result.password!.isNotEmpty
          ? '确定创建用户「${result.name}」并设置密码？'
          : '确定创建用户「${result.name}」（无密码）？',
      confirmLabel: '创建',
      danger: false,
      terminalFallback: result.password != null && result.password!.isNotEmpty
          ? "sudo useradd -m '${result.name}' && sudo chpasswd"
          : "sudo useradd -m '${result.name}'",
    );
    if (!ok || !mounted) return;
    final pass = result.password;
    await _mutate(
      userAddCommand(result.name, password: pass),
      hint: "sudo useradd -m '${result.name}'",
      stdinPayload: pass != null && pass.isNotEmpty
          ? chpasswdStdinPayload(result.name, pass)
          : null,
    );
  }

  Future<void> _deleteUser(RemotePasswdEntry a) async {
    final ok = await confirmDestructiveAction(
      context,
      title: '删除用户',
      body: '确定删除用户「${a.name}」及其家目录？此操作不可撤销。',
      confirmLabel: '删除',
      terminalFallback: "sudo userdel -r '${a.name}'",
    );
    if (!ok || !mounted) return;
    await _mutate(
      userDeleteCommand(a.name),
      hint: "sudo userdel -r '${a.name}'",
    );
  }

  Future<void> _lockUser(RemotePasswdEntry a, {required bool lock}) async {
    final title = lock ? '锁定用户' : '解锁用户';
    final ok = await confirmDestructiveAction(
      context,
      title: title,
      body: lock
          ? '确定锁定「${a.name}」？该账户将无法登录。'
          : '确定解锁「${a.name}」？',
      confirmLabel: lock ? '锁定' : '解锁',
      danger: lock,
      terminalFallback:
          lock ? "sudo usermod -L '${a.name}'" : "sudo usermod -U '${a.name}'",
    );
    if (!ok || !mounted) return;
    await _mutate(
      lock ? userLockCommand(a.name) : userUnlockCommand(a.name),
      hint: lock ? "sudo usermod -L '${a.name}'" : "sudo usermod -U '${a.name}'",
    );
  }

  Future<void> _changePassword(RemotePasswdEntry a) async {
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => _UserPasswordDialog(username: a.name),
    );
    if (password == null || !mounted) return;
    final ok = await confirmDestructiveAction(
      context,
      title: '修改密码',
      body: '确定修改用户「${a.name}」的密码？',
      confirmLabel: '修改',
      danger: false,
      terminalFallback: userPasswdCommand(a.name),
    );
    if (!ok || !mounted) return;
    await _mutate(
      userSetPasswordCommand(a.name),
      hint: 'sudo chpasswd',
      stdinPayload: chpasswdStdinPayload(a.name, password),
    );
  }

  Future<void> _kickSession(RemoteLoggedInUser u) async {
    final ok = await confirmDestructiveAction(
      context,
      title: '踢出会话',
      body: '确定结束 ${u.user} 在 ${u.tty} 上的会话？未保存的工作将丢失。',
      confirmLabel: '踢出',
      terminalFallback: "sudo pkill -KILL -t '${u.tty}'",
    );
    if (!ok || !mounted) return;
    await _mutate(
      sessionKickByTtyCommand(u.tty),
      hint: "sudo pkill -KILL -t '${u.tty}'",
    );
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
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              IconButton(
                tooltip: '刷新',
                onPressed: _connected && !_loading && !_busy
                    ? () => unawaited(_reload())
                    : null,
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
              text: '在线 (${snap?.loggedIn.length ?? 0})',
            ),
            Tab(text: '最近登录'),
            Tab(text: '账户'),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              _error!,
              style: TextStyle(color: Colors.red.shade300, fontSize: 12),
            ),
          ),
        Expanded(
          child: RemoteStateView(
            state: !_connected
                ? RemoteState.disconnected
                : (_loading && snap == null)
                    ? RemoteState.loading
                    : (_error != null && snap == null)
                        ? RemoteState.error
                        : RemoteState.data,
            message: !_connected
                ? '未连接'
                : (_error != null && snap == null)
                    ? _error
                    : null,
            onRetry: () => unawaited(_reload()),
            data: TabBarView(
              controller: _tabs,
              children: [
                _loggedInList(wb, snap?.loggedIn ?? const []),
                _recentPane(wb, snap),
                _accountsPane(wb),
              ],
            ),
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
          title: Text(
            u.user,
            style: TextStyle(color: wb.primaryText, fontSize: 13),
          ),
          subtitle: Text(
            [
              u.tty,
              if (u.host.isNotEmpty) u.host,
              if (u.since.isNotEmpty) u.since,
            ].join(' · '),
            style: TextStyle(fontSize: 11, color: wb.textMuted),
          ),
          trailing: IconButton(
            tooltip: '踢出会话',
            onPressed: _connected && !_busy
                ? () => unawaited(_kickSession(u))
                : null,
            icon: Icon(
              Icons.logout_rounded,
              size: 18,
              color: Colors.red.shade300,
            ),
          ),
        );
      },
    );
  }

  Widget _recentPane(WorkbenchColors wb, RemoteUsersSnapshot? snap) {
    final recent = snap?.recent ?? const [];
    final failed = snap?.failedLogins ?? const [];
    if (recent.isEmpty && failed.isEmpty) {
      return Center(
        child: Text('无最近登录记录', style: TextStyle(color: wb.textMuted)),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        if (recent.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '成功登录',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: wb.textMuted,
              ),
            ),
          ),
          for (final u in recent) _loginTile(wb, u, failed: false),
        ],
        if (failed.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '失败登录 (lastb)',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.orange.shade300,
              ),
            ),
          ),
          for (final u in failed) _loginTile(wb, u, failed: true),
        ],
      ],
    );
  }

  Widget _loginTile(
    WorkbenchColors wb,
    RemoteLoginRecord u, {
    required bool failed,
  }) {
    return ListTile(
      dense: true,
      leading: Icon(
        failed ? Icons.warning_amber_rounded : Icons.history_rounded,
        size: 18,
        color: failed ? Colors.orange.shade300 : wb.textMuted,
      ),
      title: Text(
        u.user,
        style: TextStyle(color: wb.primaryText, fontSize: 13),
      ),
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
                    hintText: '筛选用户名 / 组 / home / shell',
                    hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
                    prefixIcon:
                        Icon(Icons.search, size: 16, color: wb.textMuted),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
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
              const SizedBox(width: 6),
              Tooltip(
                message: '系统账号 UID 阈值（默认 ${_snap?.uidMin ?? 1000}）',
                child: SizedBox(
                  width: 72,
                  child: TextField(
                    controller: _uidMinCtrl,
                    keyboardType: TextInputType.number,
                    style: TextStyle(fontSize: 11, color: wb.primaryText),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '阈值',
                      hintStyle: TextStyle(color: wb.textMuted, fontSize: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 6,
                      ),
                      suffixIcon: _uidMinOverride != null
                          ? IconButton(
                              tooltip: '恢复默认 ${_snap?.uidMin ?? 1000}',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 24,
                                minHeight: 24,
                              ),
                              icon: Icon(
                                Icons.clear,
                                size: 14,
                                color: wb.textMuted,
                              ),
                              onPressed: () => setState(() {
                                _uidMinOverride = null;
                                _uidMinCtrl.clear();
                              }),
                            )
                          : null,
                    ),
                    onSubmitted: (v) {
                      final t = v.trim();
                      if (t.isEmpty) {
                        setState(() {
                          _uidMinOverride = null;
                          _uidMinCtrl.clear();
                        });
                        return;
                      }
                      final n = int.tryParse(t);
                      if (n == null || n < 0 || n > 65535) return;
                      setState(() => _uidMinOverride = n);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '新建用户',
                onPressed: _connected && !_busy
                    ? () => unawaited(_createUser())
                    : null,
                icon: const Icon(Icons.person_add_rounded, size: 18),
              ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child:
                      Text('无匹配账户', style: TextStyle(color: wb.textMuted)),
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final a = items[i];
                    final system = a.isSystem(_uidMin);
                    final groupLabel = a.groupName ?? 'gid ${a.gid}';
                    final extraGroups = a.groups.isEmpty
                        ? ''
                        : ' +${a.groups.join(',')}';
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        system
                            ? Icons.settings_rounded
                            : Icons.account_circle_rounded,
                        size: 18,
                        color: system ? wb.textMuted : wb.accentBlue,
                      ),
                      title: Text(
                        a.name,
                        style: TextStyle(color: wb.primaryText, fontSize: 12),
                      ),
                      subtitle: Text(
                        'uid ${a.uid} · $groupLabel$extraGroups · ${a.home}',
                        style: TextStyle(fontSize: 11, color: wb.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: PopupMenuButton<String>(
                        enabled: _connected && !_busy && !system,
                        tooltip: '操作',
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.more_vert_rounded,
                          size: 18,
                          color: system ? wb.textMuted : wb.secondaryText,
                        ),
                        onSelected: (v) {
                          switch (v) {
                            case 'passwd':
                              unawaited(_changePassword(a));
                            case 'lock':
                              unawaited(_lockUser(a, lock: true));
                            case 'unlock':
                              unawaited(_lockUser(a, lock: false));
                            case 'delete':
                              unawaited(_deleteUser(a));
                          }
                        },
                        itemBuilder: (ctx) => const [
                          PopupMenuItem(
                            value: 'passwd',
                            child: Text('修改密码'),
                          ),
                          PopupMenuItem(
                            value: 'lock',
                            child: Text('锁定'),
                          ),
                          PopupMenuItem(
                            value: 'unlock',
                            child: Text('解锁'),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text('删除用户'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _UserCreateDialog extends StatefulWidget {
  const _UserCreateDialog();

  @override
  State<_UserCreateDialog> createState() => _UserCreateDialogState();
}

class _UserCreateDialogState extends State<_UserCreateDialog> {
  final _nameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (!isSafeUsername(name)) {
      setState(() => _error = '用户名须为小写字母/数字/_/-，≤32 字符');
      return;
    }
    final pass = _passCtrl.text;
    Navigator.pop(
      context,
      (name: name, password: pass.isEmpty ? null : pass),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return AlertDialog(
      backgroundColor: wb.panelElevated,
      title: Text('新建用户', style: TextStyle(color: wb.primaryText)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              style: TextStyle(color: wb.primaryText, fontSize: 13),
              decoration: InputDecoration(
                labelText: '用户名',
                labelStyle: TextStyle(color: wb.textMuted),
                isDense: true,
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passCtrl,
              obscureText: true,
              style: TextStyle(color: wb.primaryText, fontSize: 13),
              decoration: InputDecoration(
                labelText: '密码（可选）',
                labelStyle: TextStyle(color: wb.textMuted),
                isDense: true,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('继续'),
        ),
      ],
    );
  }
}

class _UserPasswordDialog extends StatefulWidget {
  const _UserPasswordDialog({required this.username});

  final String username;

  @override
  State<_UserPasswordDialog> createState() => _UserPasswordDialogState();
}

class _UserPasswordDialogState extends State<_UserPasswordDialog> {
  final _passCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _passCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final pass = _passCtrl.text;
    if (pass.isEmpty) {
      setState(() => _error = '请输入新密码');
      return;
    }
    Navigator.pop(context, pass);
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return AlertDialog(
      backgroundColor: wb.panelElevated,
      title: Text(
        '修改密码 · ${widget.username}',
        style: TextStyle(color: wb.primaryText),
      ),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _passCtrl,
          autofocus: true,
          obscureText: true,
          style: TextStyle(color: wb.primaryText, fontSize: 13),
          decoration: InputDecoration(
            labelText: '新密码',
            labelStyle: TextStyle(color: wb.textMuted),
            isDense: true,
            errorText: _error,
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('继续'),
        ),
      ],
    );
  }
}
