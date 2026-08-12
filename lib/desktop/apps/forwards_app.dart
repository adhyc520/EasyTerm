import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/desktop_forwards_store.dart';
import '../../services/local_port_forwarder.dart';
import '../../services/terminal_session_controller.dart';
import '../../services/remote_exec_capable.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../widgets/destructive_action_dialog.dart';
import '../../widgets/remote_state_view.dart';
import '../desktop_window_manager.dart';
import '../widgets/desktop_scrollable_actions.dart';
import '../widgets/desktop_ui.dart';

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
  final TerminalSessionController controller;

  @override
  State<ForwardsApp> createState() => _ForwardsAppState();
}

class _ForwardsAppState extends State<ForwardsApp> {
  SshWorkspaceController get _ssh => widget.controller as SshWorkspaceController;

  late final DesktopForwardsStore _store;
  final List<_ForwardRow> _rows = [];
  /// localPort → TCP probe result (null = not probed yet).
  final Map<int, bool?> _reachable = {};
  /// remoteHost:remotePort → last auto-restart attempt.
  final Map<String, DateTime> _lastRestartAt = {};
  Timer? _probeTimer;
  int _probeGen = 0;
  bool _loading = true;
  String? _error;
  bool _autoReconnect = true;
  final _hostCtrl = TextEditingController(text: '127.0.0.1');
  final _portCtrl = TextEditingController();
  final _localCtrl = TextEditingController();
  bool _adding = false;
  DesktopForwardSpec? _lastDeleted;
  /// 编辑中的旧转发：成功「添加」后删除并替换。
  _ForwardRow? _editingRow;

  static const _restartCooldown = Duration(seconds: 30);

  SshWorkspaceController get c => _ssh;

  String get _hostKey => '${c.username}@${c.host}:${c.port}';

  @override
  void initState() {
    super.initState();
    _store = DesktopForwardsStore(_hostKey);
    widget.window.onConnectionRestored = _onRestored;
    c.addListener(_onCtrl);
    unawaited(_bootstrap());
    _probeTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_probeRunning()),
    );
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
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

  Future<void> _bootstrap({bool announceRestore = true}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    var restored = 0;
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
          restored++;
        }
      } else {
        for (final s in specs) {
          if (!_rows.any((r) =>
              r.spec.remoteHost == s.remoteHost &&
              r.spec.remotePort == s.remotePort)) {
            _rows.add(_ForwardRow(spec: s));
            restored++;
          }
        }
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) {
      setState(() => _loading = false);
      if (announceRestore && restored > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已恢复 $restored 个端口转发')),
        );
      }
      unawaited(_probeRunning());
    }
  }

  Future<bool> _probePort(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _probeRunning() async {
    if (!mounted) return;
    final gen = ++_probeGen;
    final online = c.connected && !c.dropped;
    final ports = <int>{
      for (final r in _rows)
        if (r.forwarder?.isRunning == true)
          if (r.forwarder?.localPort != null)
            r.forwarder!.localPort!
          else if (r.spec.localPort != null)
            r.spec.localPort!,
    };
    final next = Map<int, bool?>.of(_reachable);
    next.removeWhere((k, _) => !ports.contains(k));
    for (final port in ports) {
      if (!mounted || gen != _probeGen) return;
      next[port] = await _probePort(port);
    }
    if (!mounted || gen != _probeGen) return;
    setState(() {
      _reachable
        ..clear()
        ..addAll(next);
    });
    if (_autoReconnect && online) {
      unawaited(_maybeAutoReconnect(next));
    }
  }

  String _rowKey(DesktopForwardSpec s) =>
      '${s.remoteHost}:${s.remotePort}';

  Future<void> _maybeAutoReconnect(Map<int, bool?> reachable) async {
    if (!mounted || !_autoReconnect) return;
    if (!c.connected || c.dropped) return;
    final now = DateTime.now();
    final toRestart = <_ForwardRow>[];
    for (final r in _rows) {
      final live = r.forwarder?.isRunning == true;
      final local = r.forwarder?.localPort ?? r.spec.localPort;
      final ok = local != null ? reachable[local] : null;
      // 曾启动过但 forwarder 已死，或仍「运行中」但本地端口不可达。
      final needs =
          (r.forwarder != null && !live) || (live && ok == false);
      if (!needs) continue;
      final key = _rowKey(r.spec);
      final last = _lastRestartAt[key];
      if (last != null && now.difference(last) < _restartCooldown) continue;
      toRestart.add(r);
    }
    for (final r in toRestart) {
      if (!mounted || !_autoReconnect) return;
      if (!c.connected || c.dropped) return;
      final key = _rowKey(r.spec);
      _lastRestartAt[key] = DateTime.now();
      final old = r.forwarder;
      if (old != null) {
        try {
          await c.releaseLocalForward(old);
        } catch (_) {}
      }
      final ok = await _startSpec(r.spec, persist: false);
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已自动重连 localhost:${r.spec.localPort ?? '?'} → '
              '${r.spec.remoteHost}:${r.spec.remotePort}',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _rebuildFromSpecs() async {
    final specs = await _store.load();
    var restored = 0;
    for (final s in specs) {
      final exists = c.desktopForwards.any(
        (f) => f.remoteHost == s.remoteHost && f.remotePort == s.remotePort,
      );
      if (!exists) {
        await _startSpec(s, persist: false);
        restored++;
      }
    }
    await _bootstrap(announceRestore: false);
    if (restored > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已恢复 $restored 个端口转发')),
      );
    }
  }

  Future<void> _persist() async {
    await _store.save([for (final r in _rows) r.spec]);
  }

  /// 探测本机端口是否可绑定；占用则在 preferred+1..+50 找空闲端口。
  Future<int?> _resolveLocalPort(int preferred) async {
    Future<bool> canBind(int port) async {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        await s.close();
        return true;
      } catch (_) {
        return false;
      }
    }

    if (await canBind(preferred)) return preferred;
    final end = (preferred + 50).clamp(1, 65535);
    for (var p = preferred + 1; p <= end; p++) {
      if (await canBind(p)) return p;
    }
    return null;
  }

  Future<bool> _startSpec(DesktopForwardSpec spec, {bool persist = true}) async {
    if (!c.connected || c.dropped) {
      setState(() => _error = '未连接');
      return false;
    }
    var localPort = spec.localPort;
    if (localPort != null && localPort > 0) {
      final resolved = await _resolveLocalPort(localPort);
      if (resolved == null) {
        if (mounted) {
          setState(() => _error = '本地端口 $localPort 及后续 50 个端口均被占用');
        }
        return false;
      }
      if (resolved != localPort && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('端口占用，已改用 $resolved')),
        );
      }
      localPort = resolved;
    }
    try {
      final fwd = await c.openLocalForward(
        spec.remoteHost,
        spec.remotePort,
        localPort: localPort,
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
      unawaited(_probeRunning());
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = '启动失败：$e');
      return false;
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
    final editing = _editingRow;
    // 同 host:port 编辑时先释放旧转发，避免端口占用；不同目标则成功后再删旧项。
    final sameTarget = editing != null &&
        editing.spec.remoteHost == host &&
        editing.spec.remotePort == port;
    if (sameTarget) {
      final fwd = editing.forwarder;
      if (fwd != null) await c.releaseLocalForward(fwd);
      setState(() {
        _rows.remove(editing);
        _editingRow = null;
      });
    }
    final ok = await _startSpec(
      DesktopForwardSpec(
        remoteHost: host,
        remotePort: port,
        localPort: local,
      ),
    );
    if (ok && editing != null && !sameTarget) {
      final fwd = editing.forwarder;
      if (fwd != null) await c.releaseLocalForward(fwd);
      if (mounted) {
        setState(() {
          _rows.remove(editing);
          _editingRow = null;
        });
        await _persist();
      }
    } else if (ok && mounted) {
      setState(() => _editingRow = null);
    }
    if (mounted) {
      setState(() => _adding = false);
      if (ok) {
        _portCtrl.clear();
        _localCtrl.clear();
        _hostCtrl.text = '127.0.0.1';
      }
    }
  }

  void _beginEdit(_ForwardRow row) {
    setState(() {
      _editingRow = row;
      _hostCtrl.text = row.spec.remoteHost;
      _portCtrl.text = '${row.spec.remotePort}';
      final local = row.forwarder?.localPort ?? row.spec.localPort;
      _localCtrl.text = local != null ? '$local' : '';
      _error = null;
    });
  }

  void _cancelEdit() {
    setState(() {
      _editingRow = null;
      _hostCtrl.text = '127.0.0.1';
      _portCtrl.clear();
      _localCtrl.clear();
    });
  }

  Future<void> _remove(_ForwardRow row) async {
    final local = row.forwarder?.localPort ?? row.spec.localPort;
    final label =
        'localhost:${local ?? '?'} → ${row.spec.remoteHost}:${row.spec.remotePort}';
    final ok = await confirmDestructiveAction(
      context,
      title: '删除转发',
      body: '确定删除转发 $label？本地端口将立即关闭。',
      confirmLabel: '删除',
    );
    if (!ok || !mounted) return;
    final fwd = row.forwarder;
    if (fwd != null) {
      await c.releaseLocalForward(fwd);
    }
    final deleted = row.spec;
    setState(() {
      _rows.remove(row);
      _lastDeleted = deleted;
      if (identical(_editingRow, row)) {
        _editingRow = null;
        _hostCtrl.text = '127.0.0.1';
        _portCtrl.clear();
        _localCtrl.clear();
      }
    });
    await _persist();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已删除转发 $label'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            final spec = _lastDeleted;
            if (spec == null) return;
            _lastDeleted = null;
            unawaited(_startSpec(spec));
          },
        ),
      ),
    );
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
          DesktopAppToolbar(
            child: Row(
              children: [
                Icon(Icons.alt_route_rounded, size: 18, color: wb.accentBlue),
                const SizedBox(width: 8),
                const DesktopAppTitle('端口转发'),
                const Spacer(),
                Tooltip(
                  message: '中断后自动重连',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '中断后自动重连',
                        style: TextStyle(fontSize: 12, color: wb.secondaryText),
                      ),
                      const SizedBox(width: 4),
                      Switch(
                        value: _autoReconnect,
                        onChanged: (v) => setState(() => _autoReconnect = v),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                ),
                if (!online)
                  Text('未连接', style: TextStyle(color: wb.offline, fontSize: 12)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: DesktopHScrollRow(
              children: [
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _hostCtrl,
                    autofocus: true,
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
                      : Text(_editingRow != null ? '保存' : '添加'),
                ),
                if (_editingRow != null) ...[
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: _adding ? null : _cancelEdit,
                    child: const Text('取消'),
                  ),
                ],
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text(_error!, style: TextStyle(color: wb.offline, fontSize: 12)),
            ),
          Expanded(
            child: RemoteStateView(
              state: _loading
                  ? RemoteState.loading
                  : (!online && _rows.isEmpty)
                      ? RemoteState.disconnected
                      : (_error != null && _rows.isEmpty)
                          ? RemoteState.error
                          : _rows.isEmpty
                              ? RemoteState.empty
                              : RemoteState.data,
              message: !online && _rows.isEmpty
                  ? '未连接'
                  : (_error != null && _rows.isEmpty)
                      ? _error
                      : '暂无转发',
              detail: _rows.isEmpty && _error == null && online
                  ? '添加后可通过 localhost:本地端口 访问远端服务'
                  : null,
              onRetry: () => unawaited(_bootstrap()),
              data: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                        itemCount: _rows.length,
                        separatorBuilder: (_, _) => Divider(color: wb.border),
                        itemBuilder: (context, i) {
                          final r = _rows[i];
                          final live = r.forwarder?.isRunning == true;
                          final local =
                              r.forwarder?.localPort ?? r.spec.localPort;
                          final reachable =
                              local != null ? _reachable[local] : null;
                          final Color statusColor;
                          final String statusLabel;
                          if (!live) {
                            statusColor = wb.textMuted;
                            statusLabel = '未启动';
                          } else if (reachable == true) {
                            statusColor = const Color(0xFF34D399);
                            statusLabel = '运行中 · 可达';
                          } else if (reachable == false) {
                            statusColor = const Color(0xFFFBBF24);
                            statusLabel = '运行中 · 无响应';
                          } else {
                            statusColor = const Color(0xFF34D399);
                            statusLabel = '运行中';
                          }
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.circle,
                              size: 10,
                              color: statusColor,
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
                              statusLabel,
                              style: TextStyle(
                                fontSize: 11,
                                color: wb.textMuted,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (local != null) ...[
                                  IconButton(
                                    tooltip: '复制 URL',
                                    icon: Icon(
                                      Icons.link_rounded,
                                      color: wb.textMuted,
                                    ),
                                    onPressed: () async {
                                      final url = 'http://localhost:$local';
                                      await Clipboard.setData(
                                        ClipboardData(text: url),
                                      );
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text('已复制 $url'),
                                          duration: const Duration(seconds: 1),
                                        ),
                                      );
                                    },
                                  ),
                                  IconButton(
                                    tooltip: '在浏览器打开',
                                    icon: Icon(
                                      Icons.open_in_browser_rounded,
                                      color: wb.accentBlue,
                                    ),
                                    onPressed: () {
                                      widget.wm.open(
                                        DesktopAppType.browser,
                                        args: {
                                          'url': 'http://localhost:$local',
                                          'mode': 'direct',
                                        },
                                      );
                                    },
                                  ),
                                ],
                                if (!live && online)
                                  IconButton(
                                    tooltip: '启动',
                                    icon: Icon(Icons.play_arrow_rounded,
                                        color: wb.accentBlue),
                                    onPressed: () =>
                                        unawaited(_startSpec(r.spec)),
                                  ),
                                IconButton(
                                  tooltip: '编辑',
                                  icon: Icon(
                                    Icons.edit_outlined,
                                    color: identical(_editingRow, r)
                                        ? wb.accentBlue
                                        : wb.textMuted,
                                  ),
                                  onPressed: () => _beginEdit(r),
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
