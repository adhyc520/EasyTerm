import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/desktop_forwards_store.dart';
import '../../services/local_port_forwarder.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';

/// 本地端口转发管理：列表 / 新增 / 删除，按 host 持久化并在重连后重建。
class ForwardsApp extends StatefulWidget {
  const ForwardsApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<ForwardsApp> createState() => _ForwardsAppState();
}

class _ForwardsAppState extends State<ForwardsApp> {
  late final DesktopForwardsStore _store;
  final List<_ForwardRow> _rows = [];
  bool _loading = true;
  String? _error;
  final _hostCtrl = TextEditingController(text: '127.0.0.1');
  final _portCtrl = TextEditingController();
  final _localCtrl = TextEditingController();
  bool _adding = false;

  SshWorkspaceController get c => widget.controller;

  String get _hostKey => '${c.username}@${c.host}:${c.port}';

  @override
  void initState() {
    super.initState();
    _store = DesktopForwardsStore(_hostKey);
    widget.window.onConnectionRestored = _onRestored;
    c.addListener(_onCtrl);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    widget.window.onConnectionRestored = null;
    c.removeListener(_onCtrl);
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _localCtrl.dispose();
    super.dispose();
  }

  void _onCtrl() {
    if (mounted) setState(() {});
  }

  void _onRestored() {
    unawaited(_rebuildFromSpecs());
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final specs = await _store.load();
      // 同步已有活动转发
      _rows
        ..clear()
        ..addAll([
          for (final f in c.desktopForwards)
            _ForwardRow(
              spec: DesktopForwardSpec(
                remoteHost: f.remoteHost,
                remotePort: f.remotePort,
                localPort: f.localPort,
              ),
              forwarder: f,
            ),
        ]);
      // 持久化清单中尚未启动的，在已连接时补开
      if (c.connected && !c.dropped) {
        for (final s in specs) {
          if (_rows.any((r) =>
              r.spec.remoteHost == s.remoteHost &&
              r.spec.remotePort == s.remotePort)) {
            continue;
          }
          await _startSpec(s, persist: false);
        }
      } else {
        for (final s in specs) {
          if (!_rows.any((r) =>
              r.spec.remoteHost == s.remoteHost &&
              r.spec.remotePort == s.remotePort)) {
            _rows.add(_ForwardRow(spec: s));
          }
        }
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _rebuildFromSpecs() async {
    final specs = await _store.load();
    for (final s in specs) {
      final exists = c.desktopForwards.any(
        (f) => f.remoteHost == s.remoteHost && f.remotePort == s.remotePort,
      );
      if (!exists) await _startSpec(s, persist: false);
    }
    await _bootstrap();
  }

  Future<void> _persist() async {
    await _store.save([for (final r in _rows) r.spec]);
  }

  Future<void> _startSpec(DesktopForwardSpec spec, {bool persist = true}) async {
    if (!c.connected || c.dropped) {
      setState(() => _error = '未连接');
      return;
    }
    try {
      final fwd = await c.openLocalForward(
        spec.remoteHost,
        spec.remotePort,
        localPort: spec.localPort,
      );
      final row = _ForwardRow(
        spec: DesktopForwardSpec(
          remoteHost: spec.remoteHost,
          remotePort: spec.remotePort,
          localPort: fwd.localPort,
        ),
        forwarder: fwd,
      );
      setState(() {
        _rows.removeWhere((r) =>
            r.spec.remoteHost == spec.remoteHost &&
            r.spec.remotePort == spec.remotePort);
        _rows.add(row);
        _error = null;
      });
      if (persist) await _persist();
    } catch (e) {
      if (mounted) setState(() => _error = '启动失败：$e');
    }
  }

  Future<void> _add() async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    final local = int.tryParse(_localCtrl.text.trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      setState(() => _error = '请填写合法的远端 host 与端口');
      return;
    }
    setState(() => _adding = true);
    await _startSpec(
      DesktopForwardSpec(
        remoteHost: host,
        remotePort: port,
        localPort: local,
      ),
    );
    if (mounted) {
      setState(() => _adding = false);
      _portCtrl.clear();
      _localCtrl.clear();
    }
  }

  Future<void> _remove(_ForwardRow row) async {
    final fwd = row.forwarder;
    if (fwd != null) {
      await c.releaseLocalForward(fwd);
    }
    setState(() => _rows.remove(row));
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final online = c.connected && !c.dropped;

    return ColoredBox(
      color: wb.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Icon(Icons.alt_route_rounded, size: 18, color: wb.accentBlue),
                const SizedBox(width: 8),
                Text(
                  '端口转发',
                  style: TextStyle(
                    color: wb.primaryText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (!online)
                  Text('未连接', style: TextStyle(color: wb.offline, fontSize: 12)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _hostCtrl,
                    style: TextStyle(
                      fontSize: 12,
                      color: wb.primaryText,
                      fontFamily: 'monospace',
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '远端 Host',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _portCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: TextStyle(
                      fontSize: 12,
                      color: wb.primaryText,
                      fontFamily: 'monospace',
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '远端端口',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _localCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: TextStyle(
                      fontSize: 12,
                      color: wb.primaryText,
                      fontFamily: 'monospace',
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '本地端口',
                      hintText: '自动',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: online && !_adding ? () => unawaited(_add()) : null,
                  child: _adding
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('添加'),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text(_error!, style: TextStyle(color: wb.offline, fontSize: 12)),
            ),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: wb.accentBlue))
                : _rows.isEmpty
                    ? Center(
                        child: Text(
                          '暂无转发\n添加后可通过 localhost:本地端口 访问远端服务',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: wb.textMuted),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                        itemCount: _rows.length,
                        separatorBuilder: (_, _) => Divider(color: wb.border),
                        itemBuilder: (context, i) {
                          final r = _rows[i];
                          final live = r.forwarder?.isRunning == true;
                          final local = r.forwarder?.localPort ?? r.spec.localPort;
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.circle,
                              size: 10,
                              color: live
                                  ? const Color(0xFF34D399)
                                  : wb.textMuted,
                            ),
                            title: Text(
                              'localhost:${local ?? '?'}  →  ${r.spec.remoteHost}:${r.spec.remotePort}',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                                color: wb.primaryText,
                              ),
                            ),
                            subtitle: Text(
                              live ? '运行中' : '未启动',
                              style: TextStyle(fontSize: 11, color: wb.textMuted),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!live && online)
                                  IconButton(
                                    tooltip: '启动',
                                    icon: Icon(Icons.play_arrow_rounded,
                                        color: wb.accentBlue),
                                    onPressed: () =>
                                        unawaited(_startSpec(r.spec)),
                                  ),
                                IconButton(
                                  tooltip: '删除',
                                  icon: const Icon(Icons.delete_outline,
                                      color: Color(0xFFEF4444)),
                                  onPressed: () => unawaited(_remove(r)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _ForwardRow {
  _ForwardRow({required this.spec, this.forwarder});
  DesktopForwardSpec spec;
  LocalPortForwarder? forwarder;
}
