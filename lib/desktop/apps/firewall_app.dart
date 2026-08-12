import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote_firewall.dart';
import '../../services/remote_sudo.dart';
import '../../services/terminal_session_controller.dart';
import '../../services/remote_exec_capable.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../widgets/destructive_action_dialog.dart';
import '../../widgets/remote_state_view.dart';
import '../../widgets/sudo_password_dialog.dart';
import '../desktop_window_manager.dart';
import '../widgets/desktop_monitor_widgets.dart';
import '../widgets/desktop_ui.dart';

/// 防火墙：检测 ufw / firewalld / iptables；UFW 启停与放行/拒绝/删规则；
/// firewalld 显示 zone 并支持添加 service/port + reload。
/// 特权操作优先 `sudo -n`；需密码时弹窗用 `sudo -S` 授权。
class FirewallApp extends StatefulWidget {
  const FirewallApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final TerminalSessionController controller;

  @override
  State<FirewallApp> createState() => _FirewallAppState();
}

class _FirewallAppState extends State<FirewallApp> {
  RemoteExecCapable get _exec => widget.controller as RemoteExecCapable;
RemoteFirewallSnapshot? _snap;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  final _portCtrl = TextEditingController();
  final _serviceCtrl = TextEditingController();
  final _fwPortCtrl = TextEditingController();
  bool _showRaw = false;

  bool get _connected =>
      widget.controller.connected && !widget.controller.dropped;

  @override
  void initState() {
    super.initState();
    widget.window.onConnectionRestored = _onRestored;
    unawaited(_reload());
  }

  @override
  void dispose() {
    widget.window.onConnectionRestored = null;
    _portCtrl.dispose();
    _serviceCtrl.dispose();
    _fwPortCtrl.dispose();
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
    final snap = await fetchFirewallSnapshot(_exec);
    if (!mounted) return;
    if (snap == null) {
      setState(() {
        _loading = false;
        _error = _exec.lastRemoteCommandError == null
            ? '无法读取防火墙状态'
            : '刷新失败：${_exec.lastRemoteCommandError}';
      });
      return;
    }
    setState(() {
      _snap = snap;
      _loading = false;
      _error = snap.error;
    });
  }

  Future<void> _mutate(String cmd, {required String hint, String? confirm}) async {
    if (_busy) return;
    if (confirm != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认操作'),
          content: Text(confirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await runWithSudoPasswordPrompt(
      context,
      _exec,
      attempt: (sudoPassword) => runFirewallMutate(
        _exec,
        cmd,
        terminalHint: hint,
        sudoPassword: sudoPassword,
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

  Future<void> _confirmPortMutate({required bool allow}) async {
    final p = _portCtrl.text.trim();
    if (!isSafeFirewallPortSpec(p)) {
      setState(() => _error = '非法端口规格');
      return;
    }
    final portNum = parseFirewallPortNumber(p);
    final sshRisk = portNum == widget.controller.port || portNum == 22;
    final title = allow ? '放行端口' : '拒绝端口';
    final body = !allow && sshRisk
        ? '拒绝 $p 可能导致当前 SSH 会话立即断开，且无法再从此端口连入。确定继续？'
        : allow
            ? '确定放行 $p？'
            : '确定拒绝 $p？';
    final ok = await confirmDestructiveAction(
      context,
      title: title,
      body: body,
      confirmLabel: allow ? '放行' : '拒绝',
      sshPortWarning: sshRisk,
      terminalFallback: allow ? 'sudo ufw allow $p' : 'sudo ufw deny $p',
    );
    if (!ok || !mounted) return;
    await _mutate(
      allow ? ufwAllowCommand(p) : ufwDenyCommand(p),
      hint: allow ? 'sudo ufw allow $p' : 'sudo ufw deny $p',
    );
  }

  Future<void> _setFirewalldDefaultZone(String zone) async {
    if (!isSafeFirewalldZoneName(zone)) {
      setState(() => _error = '非法 zone 名');
      return;
    }
    final ok = await confirmDestructiveAction(
      context,
      title: '切换默认 Zone',
      body: '将默认 zone 设为「$zone」。新连接将使用该 zone 的规则。确定继续？',
      confirmLabel: '切换',
      danger: false,
      terminalFallback: 'sudo firewall-cmd --set-default-zone=$zone',
    );
    if (!ok || !mounted) return;
    await _mutate(
      firewalldSetDefaultZoneCommand(zone),
      hint: 'sudo firewall-cmd --set-default-zone=$zone',
    );
  }

  Future<void> _reloadFirewalld() async {
    final ok = await confirmDestructiveAction(
      context,
      title: '重新加载 firewalld',
      body: '执行 firewall-cmd --reload 会应用已保存的配置。确定继续？',
      confirmLabel: '重新加载',
      danger: false,
      terminalFallback: 'sudo firewall-cmd --reload',
    );
    if (!ok || !mounted) return;
    await _mutate(
      firewalldReloadCommand(),
      hint: 'sudo firewall-cmd --reload',
    );
  }

  Future<void> _addFirewalldService() async {
    final name = _serviceCtrl.text.trim();
    if (!isSafeFirewalldServiceName(name)) {
      setState(() => _error = '非法服务名（仅允许小写字母、数字、_、-）');
      return;
    }
    final ok = await confirmDestructiveAction(
      context,
      title: '添加服务',
      body: '永久添加服务「$name」到当前 zone，并重新加载 firewalld。确定继续？',
      confirmLabel: '添加',
      danger: false,
      terminalFallback:
          'sudo firewall-cmd --permanent --add-service=$name && sudo firewall-cmd --reload',
    );
    if (!ok || !mounted) return;
    await _mutate(
      firewalldAddServiceCommand(name),
      hint:
          'sudo firewall-cmd --permanent --add-service=$name && sudo firewall-cmd --reload',
    );
  }

  Future<void> _addFirewalldPort() async {
    final p = _fwPortCtrl.text.trim();
    if (!isSafeFirewallPortSpec(p)) {
      setState(() => _error = '非法端口规格');
      return;
    }
    final portNum = parseFirewallPortNumber(p);
    final sshRisk = portNum == widget.controller.port || portNum == 22;
    final ok = await confirmDestructiveAction(
      context,
      title: '添加端口',
      body: '永久添加端口「$p」到当前 zone，并重新加载 firewalld。确定继续？',
      confirmLabel: '添加',
      danger: false,
      sshPortWarning: sshRisk,
      terminalFallback:
          'sudo firewall-cmd --permanent --add-port=$p && sudo firewall-cmd --reload',
    );
    if (!ok || !mounted) return;
    await _mutate(
      firewalldAddPortCommand(p),
      hint:
          'sudo firewall-cmd --permanent --add-port=$p && sudo firewall-cmd --reload',
    );
  }

  Future<void> _removeFirewalldService(String name) async {
    final ok = await confirmDestructiveAction(
      context,
      title: '移除服务',
      body: '永久移除服务「$name」并重新加载 firewalld。确定继续？',
      confirmLabel: '移除',
      terminalFallback:
          'sudo firewall-cmd --permanent --remove-service=$name && sudo firewall-cmd --reload',
    );
    if (!ok || !mounted) return;
    await _mutate(
      firewalldRemoveServiceCommand(name),
      hint:
          'sudo firewall-cmd --permanent --remove-service=$name && sudo firewall-cmd --reload',
    );
  }

  Future<void> _removeFirewalldPort(String port) async {
    final ok = await confirmDestructiveAction(
      context,
      title: '移除端口',
      body: '永久移除端口「$port」并重新加载 firewalld。确定继续？',
      confirmLabel: '移除',
      terminalFallback:
          'sudo firewall-cmd --permanent --remove-port=$port && sudo firewall-cmd --reload',
    );
    if (!ok || !mounted) return;
    await _mutate(
      firewalldRemovePortCommand(port),
      hint:
          'sudo firewall-cmd --permanent --remove-port=$port && sudo firewall-cmd --reload',
    );
  }

  void _copyHint(String hint) {
    unawaited(Clipboard.setData(ClipboardData(text: hint)));
    widget.wm.open(
      DesktopAppType.terminal,
      args: {'inject': hint},
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已打开终端并填入命令（未自动执行）')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final snap = _snap;
    final isUfw = snap?.backend == RemoteFirewallBackend.ufw;
    final isFirewalld = snap?.backend == RemoteFirewallBackend.firewalld;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopAppToolbar(
          child: Row(
            children: [
              const DesktopAppTitle('防火墙'),
              const SizedBox(width: 8),
              DesktopMetaChip(label: snap?.backend.label ?? '…'),
              if (snap?.active != null) ...[
                const SizedBox(width: 8),
                DesktopMetaChip(
                  label: snap!.active! ? '已启用' : '已关闭',
                  accent: snap.active!,
                  leading: Icon(
                    Icons.circle,
                    size: 8,
                    color: snap.active! ? wb.online : wb.offline,
                  ),
                ),
              ],
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
              DesktopToolIcon(
                tooltip: '刷新',
                onPressed:
                    _connected && !_loading ? () => unawaited(_reload()) : null,
                icon: Icons.refresh_rounded,
              ),
            ],
          ),
        ),
        if (isUfw)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => unawaited(
                            _mutate(
                              ufwSetEnabledCommand(true),
                              hint: 'sudo ufw --force enable',
                              confirm: '启用 UFW 可能切断当前 SSH。确定继续？',
                            ),
                          ),
                  child: const Text('启用'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => unawaited(
                            _mutate(
                              ufwSetEnabledCommand(false),
                              hint: 'sudo ufw disable',
                              confirm: '关闭防火墙？',
                            ),
                          ),
                  child: const Text('禁用'),
                ),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _portCtrl,
                    autofocus: true,
                    style: TextStyle(fontSize: 12, color: wb.primaryText),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '80/tcp',
                      hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
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
                PopupMenuButton<String>(
                  tooltip: '常用预设',
                  enabled: !_busy,
                  onSelected: (spec) {
                    _portCtrl.text = spec;
                    unawaited(_confirmPortMutate(allow: true));
                  },
                  itemBuilder: (ctx) => const [
                    PopupMenuItem(value: '22/tcp', child: Text('SSH · 22/tcp')),
                    PopupMenuItem(value: '80/tcp', child: Text('HTTP · 80/tcp')),
                    PopupMenuItem(
                      value: '443/tcp',
                      child: Text('HTTPS · 443/tcp'),
                    ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      '预设',
                      style: TextStyle(fontSize: 12, color: wb.accentBlue),
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => unawaited(_confirmPortMutate(allow: true)),
                  child: const Text('放行'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => unawaited(_confirmPortMutate(allow: false)),
                  child: const Text('拒绝'),
                ),
              ],
            ),
          )
        else if (isFirewalld)
          _firewalldPanel(wb, snap!)
        else if (snap != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: wb.panelElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: wb.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '此后端（${snap.backend.label}）暂不支持可视化编辑',
                    style: TextStyle(
                      fontSize: 12,
                      color: wb.primaryText,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '可在终端执行下列命令查看或修改规则：',
                    style: TextStyle(fontSize: 11, color: wb.textMuted),
                  ),
                  const SizedBox(height: 6),
                  for (final cmd in _backendHintCommands(snap.backend)) ...[
                    SelectableText(
                      cmd,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: wb.secondaryText,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _copyHint(cmd),
                        icon: const Icon(Icons.copy_rounded, size: 14),
                        label: const Text('在终端打开'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: SelectableText(
              _error!,
              style: TextStyle(color: Colors.red.shade300, fontSize: 12),
            ),
          ),
        if (_error != null && _error!.contains('sudo'))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                final lines = _error!.split('\n');
                final hint = lines.length > 1 ? lines.last : lines.first;
                _copyHint(hint);
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('在终端打开命令'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              TextButton(
                onPressed: () => setState(() => _showRaw = !_showRaw),
                child: Text(_showRaw ? '显示规则列表' : '显示原始状态'),
              ),
            ],
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
                        : (!_showRaw &&
                                snap != null &&
                                snap.rules.isEmpty &&
                                !_loading)
                            ? RemoteState.empty
                            : RemoteState.data,
            message: !_connected
                ? '未连接'
                : (_error != null && snap == null)
                    ? _error
                    : (snap?.error ?? '无规则或无法解析'),
            onRetry: () => unawaited(_reload()),
            data: _showRaw
                ? SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      snap?.statusText ?? '',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: wb.primaryText,
                      ),
                    ),
                  )
                : _rulesList(wb, snap),
          ),
        ),
      ],
    );
  }

  Widget _firewalldPanel(WorkbenchColors wb, RemoteFirewallSnapshot snap) {
    final zone = snap.firewalldZone;
    InputDecoration denseField(String hint) => InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
        );

    Widget chips(
      String label,
      List<String> items,
      Color accent, {
      required void Function(String value) onRemove,
    }) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: wb.textMuted),
          ),
          const SizedBox(height: 4),
          if (items.isEmpty)
            Text(
              '（无）',
              style: TextStyle(fontSize: 11, color: wb.textMuted),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final s in items)
                  InputChip(
                    label: Text(s, style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: accent.withValues(alpha: 0.12),
                    side: BorderSide(color: accent.withValues(alpha: 0.35)),
                    padding: EdgeInsets.zero,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                    onDeleted: _busy ? null : () => onRemove(s),
                    deleteIconColor: wb.textMuted,
                  ),
              ],
            ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: wb.panelElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: wb.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    zone != null ? 'Zone：${zone.zone}' : 'Zone：未知',
                    style: TextStyle(
                      fontSize: 12,
                      color: wb.primaryText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (zone != null && zone.availableZones.isNotEmpty)
                  PopupMenuButton<String>(
                    tooltip: '切换默认 Zone',
                    enabled: !_busy,
                    onSelected: (z) {
                      if (z == zone.zone) return;
                      unawaited(_setFirewalldDefaultZone(z));
                    },
                    itemBuilder: (ctx) => [
                      for (final z in zone.availableZones)
                        PopupMenuItem(
                          value: z,
                          child: Row(
                            children: [
                              if (z == zone.zone)
                                Icon(Icons.check, size: 14, color: wb.accentBlue)
                              else
                                const SizedBox(width: 14),
                              const SizedBox(width: 6),
                              Text(z),
                            ],
                          ),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '切换 Zone',
                            style: TextStyle(
                              fontSize: 12,
                              color: wb.accentBlue,
                            ),
                          ),
                          Icon(
                            Icons.arrow_drop_down,
                            size: 16,
                            color: wb.accentBlue,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            if (zone != null) ...[
              const SizedBox(height: 8),
              chips(
                'Services',
                zone.services,
                wb.accentBlue,
                onRemove: (s) => unawaited(_removeFirewalldService(s)),
              ),
              const SizedBox(height: 8),
              chips(
                'Ports',
                zone.ports,
                wb.online,
                onRemove: (p) => unawaited(_removeFirewalldPort(p)),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _serviceCtrl,
                    style: TextStyle(fontSize: 12, color: wb.primaryText),
                    decoration: denseField('http'),
                  ),
                ),
                FilledButton(
                  onPressed:
                      _busy ? null : () => unawaited(_addFirewalldService()),
                  child: const Text('添加服务'),
                ),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _fwPortCtrl,
                    style: TextStyle(fontSize: 12, color: wb.primaryText),
                    decoration: denseField('8080/tcp'),
                  ),
                ),
                FilledButton(
                  onPressed:
                      _busy ? null : () => unawaited(_addFirewalldPort()),
                  child: const Text('添加端口'),
                ),
                OutlinedButton(
                  onPressed:
                      _busy ? null : () => unawaited(_reloadFirewalld()),
                  child: const Text('重新加载'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _rulesList(WorkbenchColors wb, RemoteFirewallSnapshot? snap) {
    final rules = snap?.rules ?? const [];
    final isUfw = snap?.backend == RemoteFirewallBackend.ufw;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: rules.length,
      itemBuilder: (context, i) {
        final r = rules[i];
        return ListTile(
          dense: true,
          leading: Icon(
            Icons.shield_rounded,
            size: 18,
            color: wb.accentBlue,
          ),
          title: Text(
            r.to.isNotEmpty ? r.to : r.raw,
            style: TextStyle(
              fontSize: 12,
              color: wb.primaryText,
              fontFamily: 'monospace',
            ),
          ),
          subtitle: Text(
            [
              if (r.number != null) '#${r.number}',
              if (r.action.isNotEmpty) r.action,
              if (r.from.isNotEmpty) 'from ${r.from}',
            ].join(' · '),
            style: TextStyle(fontSize: 11, color: wb.textMuted),
          ),
          trailing: isUfw
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '填入端口以便编辑',
                      icon: Icon(
                        Icons.edit_outlined,
                        size: 18,
                        color: wb.textMuted,
                      ),
                      onPressed: () {
                        final spec = r.to.isNotEmpty ? r.to : r.raw;
                        final m = RegExp(r'(\d+(?:/(?:tcp|udp))?)')
                            .firstMatch(spec);
                        _portCtrl.text = m?.group(1) ?? spec;
                      },
                    ),
                    if (r.number != null)
                      IconButton(
                        tooltip: '删除规则',
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: Colors.red.shade300,
                        ),
                        onPressed: _busy
                            ? null
                            : () => unawaited(
                                  _mutate(
                                    ufwDeleteCommand(r.number!),
                                    hint: 'sudo ufw delete ${r.number}',
                                    confirm: '删除规则 #${r.number}？',
                                  ),
                                ),
                      ),
                  ],
                )
              : null,
        );
      },
    );
  }

  List<String> _backendHintCommands(RemoteFirewallBackend backend) {
    return switch (backend) {
      RemoteFirewallBackend.firewalld => const [
          'sudo firewall-cmd --list-all',
          'sudo firewall-cmd --reload',
        ],
      RemoteFirewallBackend.iptables => const [
          'sudo iptables -L -n -v',
          'sudo iptables -S',
        ],
      RemoteFirewallBackend.ufw => const ['sudo ufw status numbered'],
      RemoteFirewallBackend.unknown => const [
          'sudo ufw status numbered',
          'sudo firewall-cmd --list-all',
          'sudo iptables -L -n -v',
        ],
    };
  }
}
