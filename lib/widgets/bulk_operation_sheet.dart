import 'package:flutter/material.dart';

import '../models/saved_host_profile.dart';
import '../services/bulk_command_executor.dart';
import '../services/host_profiles_store.dart';
import '../services/session_tabs_controller.dart';
import '../services/terminal_session_controller.dart';
import '../services/remote_exec_capable.dart';
import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';

Future<void> showBulkOperationSheet(
  BuildContext context, {
  required SessionTabsController tabs,
  required HostProfilesStore profiles,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => BulkOperationSheet(tabs: tabs, profiles: profiles),
  );
}

class BulkOperationSheet extends StatefulWidget {
  const BulkOperationSheet({
    super.key,
    required this.tabs,
    required this.profiles,
  });

  final SessionTabsController tabs;
  final HostProfilesStore profiles;

  @override
  State<BulkOperationSheet> createState() => _BulkOperationSheetState();
}

class _BulkOperationSheetState extends State<BulkOperationSheet> {
  final TextEditingController _command = TextEditingController(text: 'uptime');
  final TextEditingController _timeout = TextEditingController(text: '30');
  final Set<String> _selectedKeys = {};
  bool _parallel = true;
  bool _busy = false;
  List<BulkCommandResult>? _results;

  @override
  void initState() {
    super.initState();
    for (final c in _connectedControllers()) {
      _selectedKeys.add(_keyFor(c));
    }
  }

  @override
  void dispose() {
    _command.dispose();
    _timeout.dispose();
    super.dispose();
  }

  static String _keyFor(TerminalSessionController c) =>
      '${c.username}@${c.host}:${c.port}';

  List<TerminalSessionController> _connectedControllers() {
    final seen = <String>{};
    final out = <TerminalSessionController>[];
    for (final t in widget.tabs.tabs) {
      for (final leaf in t.root.leaves) {
        final c = leaf.controller;
        if (!c.connected) continue;
        final k = _keyFor(c);
        if (seen.add(k)) out.add(c);
      }
    }
    return out;
  }

  List<_HostPick> _picks() {
    final connected = _connectedControllers();
    final picks = <_HostPick>[
      for (final c in connected)
        _HostPick(
          key: _keyFor(c),
          label: _keyFor(c),
          subtitle: '已打开会话',
          controller: c,
        ),
    ];
    final connectedKeys = picks.map((e) => e.key).toSet();
    for (final p in widget.profiles.profiles) {
      final k = '${p.username}@${p.host}:${p.port}';
      if (connectedKeys.contains(k)) continue;
      // 仅列出已有打开连接的主机可执行；未连接 profile 标记为不可选（需先开会话）。
      picks.add(
        _HostPick(
          key: 'profile:${p.id}',
          label: p.label,
          subtitle: '${p.subtitle}（未连接）',
          controller: null,
          profile: p,
        ),
      );
    }
    return picks;
  }

  Future<void> _run() async {
    final cmd = _command.text.trim();
    if (cmd.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入命令')),
      );
      return;
    }
    final hosts = <TerminalSessionController>[];
    for (final pick in _picks()) {
      if (!_selectedKeys.contains(pick.key)) continue;
      final c = pick.controller;
      if (c == null || !c.connected) continue;
      hosts.add(c);
    }
    if (hosts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择至少一台已连接的主机')),
      );
      return;
    }
    setState(() {
      _busy = true;
      _results = null;
    });
    final timeout = int.tryParse(_timeout.text.trim()) ?? 30;
    final results = await BulkCommandExecutor().executeOnHosts(
      hosts: hosts,
      command: cmd,
      timeoutSec: timeout,
      parallel: _parallel,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _results = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final picks = _picks();
    final fieldStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: wb.primaryText);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 8,
        bottom: 16 + bottom,
        // 键盘
      ),
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '批量命令',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: wb.primaryText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '目标主机',
                  style: fieldStyle?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                if (picks.isEmpty)
                  Text(
                    '没有已连接的主机。请先打开会话。',
                    style: TextStyle(color: wb.textMuted, fontSize: 13),
                  )
                else
                  ...picks.map((pick) {
                    final enabled = pick.controller != null;
                    return CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: enabled && _selectedKeys.contains(pick.key),
                      onChanged: !enabled || _busy
                          ? null
                          : (v) {
                              setState(() {
                                if (v == true) {
                                  _selectedKeys.add(pick.key);
                                } else {
                                  _selectedKeys.remove(pick.key);
                                }
                              });
                            },
                      title: Text(pick.label, style: fieldStyle),
                      subtitle: Text(
                        pick.subtitle,
                        style: TextStyle(
                          color: wb.textMuted,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  }),
                const SizedBox(height: 8),
                TextField(
                  controller: _command,
                  style: fieldStyle?.copyWith(fontFamily: 'monospace'),
                  decoration: const InputDecoration(labelText: '命令'),
                  minLines: 2,
                  maxLines: 4,
                  enabled: !_busy,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _parallel,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _parallel = v ?? true),
                        title: const Text('并行执行'),
                      ),
                    ),
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _timeout,
                        style: fieldStyle,
                        decoration: const InputDecoration(
                          labelText: '超时(秒)',
                        ),
                        keyboardType: TextInputType.number,
                        enabled: !_busy,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _busy ? null : _run,
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('执行'),
                ),
                if (_results != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    '结果',
                    style: fieldStyle?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  for (final r in _results!)
                    _ResultCard(result: r, wb: wb),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HostPick {
  _HostPick({
    required this.key,
    required this.label,
    required this.subtitle,
    this.controller,
    this.profile,
  });

  final String key;
  final String label;
  final String subtitle;
  final TerminalSessionController? controller;
  final SavedHostProfile? profile;
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, required this.wb});

  final BulkCommandResult result;
  final WorkbenchColors wb;

  @override
  Widget build(BuildContext context) {
    final ok = result.ok;
    final headerColor = ok ? wb.online : const Color(0xFFEF4444);
    final body = StringBuffer();
    if (result.error != null) {
      body.writeln(result.error);
    }
    if (result.stdout.trim().isNotEmpty) body.writeln(result.stdout.trim());
    if (result.stderr.trim().isNotEmpty) {
      body.writeln('stderr:');
      body.writeln(result.stderr.trim());
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: wb.border),
          color: wb.panelElevated.withValues(alpha: 0.55),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: headerColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      result.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: wb.primaryText,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      '${result.duration.inMilliseconds}ms'
                      '${result.exitCode != null ? ' · exit ${result.exitCode}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(color: wb.textMuted, fontSize: 11),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SelectableText(
                body.toString().trim().isEmpty ? '(无输出)' : body.toString(),
                style: TextStyle(
                  color: wb.primaryText.withValues(alpha: 0.92),
                  fontSize: 12,
                  fontFamily: 'monospace',
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
