import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote_firewall.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';

/// 防火墙：检测 ufw / firewalld / iptables；UFW 支持启停与放行/拒绝/删规则。
class FirewallApp extends StatefulWidget {
  const FirewallApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<FirewallApp> createState() => _FirewallAppState();
}

class _FirewallAppState extends State<FirewallApp> {
  RemoteFirewallSnapshot? _snap;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  final _portCtrl = TextEditingController();
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
    final snap = await fetchFirewallSnapshot(widget.controller);
    if (!mounted) return;
    if (snap == null) {
      setState(() {
        _loading = false;
        _error = widget.controller.lastRemoteCommandError == null
            ? '无法读取防火墙状态'
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
    final err = await runFirewallMutate(
      widget.controller,
      cmd,
      terminalHint: hint,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    await _reload();
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(
            children: [
              Text(
                '防火墙',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: wb.primaryText,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: wb.panelElevated,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: wb.border),
                ),
                child: Text(
                  snap?.backend.label ?? '…',
                  style: TextStyle(fontSize: 11, color: wb.textMuted),
                ),
              ),
              if (snap?.active != null) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.circle,
                  size: 8,
                  color: snap!.active! ? wb.online : wb.offline,
                ),
                const SizedBox(width: 4),
                Text(
                  snap.active! ? '已启用' : '已关闭',
                  style: TextStyle(fontSize: 11, color: wb.textMuted),
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
              IconButton(
                tooltip: '刷新',
                onPressed:
                    _connected && !_loading ? () => unawaited(_reload()) : null,
                icon: const Icon(Icons.refresh_rounded, size: 18),
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
                    style: TextStyle(fontSize: 12, color: wb.primaryText),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '22/tcp',
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
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () {
                          final p = _portCtrl.text.trim();
                          if (!isSafeFirewallPortSpec(p)) {
                            setState(() => _error = '非法端口规格');
                            return;
                          }
                          unawaited(
                            _mutate(
                              ufwAllowCommand(p),
                              hint: 'sudo ufw allow $p',
                            ),
                          );
                        },
                  child: const Text('放行'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () {
                          final p = _portCtrl.text.trim();
                          if (!isSafeFirewallPortSpec(p)) {
                            setState(() => _error = '非法端口规格');
                            return;
                          }
                          unawaited(
                            _mutate(
                              ufwDenyCommand(p),
                              hint: 'sudo ufw deny $p',
                            ),
                          );
                        },
                  child: const Text('拒绝'),
                ),
              ],
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
          child: _loading && snap == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _showRaw
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
      ],
    );
  }

  Widget _rulesList(WorkbenchColors wb, RemoteFirewallSnapshot? snap) {
    final rules = snap?.rules ?? const [];
    if (rules.isEmpty) {
      return Center(
        child: Text(
          snap?.error ?? '无规则或无法解析',
          style: TextStyle(color: wb.textMuted),
        ),
      );
    }
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
          trailing: isUfw && r.number != null
              ? IconButton(
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
                )
              : null,
        );
      },
    );
  }
}
