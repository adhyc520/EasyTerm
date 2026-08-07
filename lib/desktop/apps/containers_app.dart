import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/remote_containers.dart';
import '../../services/remote_process_list.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../widgets/destructive_action_dialog.dart';
import '../../widgets/remote_state_view.dart';
import '../desktop_window_manager.dart';
import '../widgets/desktop_monitor_widgets.dart';
import '../widgets/desktop_scrollable_actions.dart';

enum _Sort { name, status, cpu, memory }

/// Docker 容器列表与启停。
class ContainersApp extends StatefulWidget {
  const ContainersApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<ContainersApp> createState() => _ContainersAppState();
}

class _ContainersAppState extends State<ContainersApp> {
  Timer? _timer;
  RemoteOsKind? _os;
  List<RemoteContainer> _items = const [];
  bool _available = true;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  String _filter = '';
  String? _selected;
  /// True when [_selected] was visible in a prior refresh but is missing now.
  bool _selectedGone = false;
  _Sort _sort = _Sort.status;
  bool _sortAsc = true;
  final _filterCtrl = TextEditingController();
  bool _userPaused = false;
  Duration _interval = const Duration(seconds: 5);
  DateTime? _lastTickAt;

  @override
  void initState() {
    super.initState();
    widget.wm.addListener(_onWm);
    widget.controller.addListener(_onController);
    widget.window.onConnectionRestored = _onConnectionRestored;
    unawaited(_tick());
    _armTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _filterCtrl.dispose();
    widget.window.onConnectionRestored = null;
    widget.wm.removeListener(_onWm);
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _onConnectionRestored() {
    if (!mounted) return;
    setState(() => _error = null);
    unawaited(_tick());
  }

  void _onWm() {
    _armTimer();
    if (mounted) setState(() {});
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  bool get _paused =>
      widget.window.state == WindowState.minimized || _userPaused;

  bool get _connected =>
      widget.controller.connected && !widget.controller.dropped;

  void _armTimer() {
    _timer?.cancel();
    if (_paused) {
      _timer = null;
      return;
    }
    _timer = Timer.periodic(_interval, (_) {
      unawaited(_tick());
    });
  }

  Future<void> _tick() async {
    if (!mounted || _paused) return;
    if (!_connected) {
      setState(() {
        _error = '连接已断开，重连后刷新';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = _items.isEmpty;
      _error = null;
    });
    try {
      final snap = await fetchRemoteContainers(
        widget.controller,
        osHint: _os,
      );
      if (!mounted) return;
      if (snap == null) {
        setState(() {
          _error = '无法获取容器列表';
          _loading = false;
        });
        return;
      }
      if (snap.os != RemoteOsKind.unknown) _os = snap.os;
      setState(() {
        _items = snap.containers;
        _available = snap.available;
        _loading = false;
        _error = snap.error;
        _lastTickAt = DateTime.now();
        if (_selected != null) {
          final stillThere =
              snap.containers.any((c) => c.id == _selected);
          if (stillThere) {
            _selectedGone = false;
          } else if (!_selectedGone) {
            // Keep id so detail can explain disappearance.
            _selectedGone = true;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<RemoteContainer> get _filtered {
    final q = _filter.trim().toLowerCase();
    var list = [
      for (final c in _items)
        if (q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            c.image.toLowerCase().contains(q) ||
            c.id.toLowerCase().contains(q) ||
            (c.ports?.toLowerCase().contains(q) ?? false))
          c,
    ];
    int cmp(RemoteContainer a, RemoteContainer b) {
      int r;
      switch (_sort) {
        case _Sort.name:
          r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _Sort.status:
          r = (a.isRunning ? 0 : 1).compareTo(b.isRunning ? 0 : 1);
          if (r == 0) {
            r = a.status.toLowerCase().compareTo(b.status.toLowerCase());
          }
        case _Sort.cpu:
          r = (a.cpuPercent ?? -1).compareTo(b.cpuPercent ?? -1);
        case _Sort.memory:
          r = (a.memPercent ?? -1).compareTo(b.memPercent ?? -1);
      }
      return _sortAsc ? r : -r;
    }

    list = [...list]..sort(cmp);
    return list;
  }

  Future<void> _act(RemoteContainerAction action) async {
    final id = _selected;
    if (id == null || _os == null || _busy) return;
    RemoteContainer? selected;
    for (final c in _items) {
      if (c.id == id) {
        selected = c;
        break;
      }
    }
    final name = selected?.name.isNotEmpty == true ? selected!.name : id;
    if (action == RemoteContainerAction.stop) {
      final ok = await confirmDestructiveAction(
        context,
        title: '停止容器',
        body: '确定停止容器「$name」？正在其中运行的服务将中断。',
        confirmLabel: '停止',
      );
      if (!ok || !mounted) return;
    } else if (action == RemoteContainerAction.restart) {
      final ok = await confirmDestructiveAction(
        context,
        title: '重启容器',
        body: '确定重启容器「$name」？服务会短暂中断。',
        confirmLabel: '重启',
      );
      if (!ok || !mounted) return;
    } else if (action == RemoteContainerAction.remove) {
      final ok = await confirmDestructiveAction(
        context,
        title: '删除容器',
        body: '确定删除容器「$name」？此操作不可撤销。',
        confirmLabel: '删除',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    final out = await controlRemoteContainer(
      widget.controller,
      os: _os!,
      ref: id,
      action: action,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (out != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(out.trim())),
      );
    }
    await _tick();
  }

  void _openLogs(RemoteContainer c) {
    widget.wm.open(
      DesktopAppType.logs,
      args: {
        'source': 'docker',
        'unit': c.name.isNotEmpty ? c.name : c.id,
      },
    );
  }

  void _execShell(RemoteContainer c) {
    final ref = c.name.isNotEmpty ? c.name : c.id;
    widget.wm.open(
      DesktopAppType.terminal,
      args: {'inject': 'docker exec -it $ref sh\n'},
    );
  }

  Future<void> _inspect(RemoteContainer c) async {
    if (_os == null) return;
    final ref = c.name.isNotEmpty ? c.name : c.id;
    final raw = await inspectRemoteContainer(
      widget.controller,
      os: _os!,
      ref: ref,
    );
    if (!mounted) return;
    final wb = context.wb;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: wb.panelElevated,
        title: Text('容器详情 · $ref', style: TextStyle(color: wb.primaryText)),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectableText(
              (raw == null || raw.trim().isEmpty) ? '无法获取 inspect 输出' : raw.trim(),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: wb.secondaryText,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _toggleSort(_Sort s) {
    setState(() {
      if (_sort == s) {
        _sortAsc = !_sortAsc;
      } else {
        _sort = s;
        _sortAsc = s == _Sort.name;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final list = _filtered;
    RemoteContainer? selected;
    for (final c in _items) {
      if (c.id == _selected) {
        selected = c;
        break;
      }
    }
    final showMissingDetail =
        _selected != null && selected == null && _selectedGone;

    return ColoredBox(
      color: wb.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
            child: Row(
              children: [
                Icon(Icons.view_in_ar_rounded, size: 18, color: wb.accentBlue),
                const SizedBox(width: 8),
                Text(
                  '容器',
                  style: TextStyle(
                    color: wb.primaryText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _available
                      ? '${list.length} / ${_items.length}'
                      : 'Docker 不可用',
                  style: TextStyle(fontSize: 12, color: wb.textMuted),
                ),
                const Spacer(),
                LastUpdatedChip(
                  lastTickAt: _lastTickAt,
                  live: !_paused && _connected,
                ),
                const SizedBox(width: 4),
                PauseToggle(
                  paused: _userPaused,
                  onPausedChanged: (v) {
                    setState(() => _userPaused = v);
                    _armTimer();
                  },
                  interval: _interval,
                  onIntervalChanged: (d) {
                    setState(() => _interval = d);
                    _armTimer();
                  },
                  intervals: const [
                    Duration(seconds: 1),
                    Duration(seconds: 3),
                    Duration(seconds: 5),
                    Duration(seconds: 10),
                    Duration(seconds: 30),
                  ],
                ),
                if (_loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: '刷新',
                    iconSize: 18,
                    onPressed: _connected ? () => unawaited(_tick()) : null,
                    icon: Icon(Icons.refresh_rounded, color: wb.textMuted),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _filterCtrl,
                    autofocus: true,
                    style: TextStyle(fontSize: 12, color: wb.primaryText),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '筛选名称 / 镜像 / 端口',
                      hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 16,
                        color: wb.textMuted,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 0,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onChanged: (v) => setState(() => _filter = v),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: DesktopScrollableActions(
                    children: [
                      _ActBtn(
                        label: '启动',
                        enabled:
                            selected != null && !selected.isRunning && !_busy,
                        onPressed: () =>
                            unawaited(_act(RemoteContainerAction.start)),
                      ),
                      const SizedBox(width: 4),
                      _ActBtn(
                        label: '停止',
                        enabled:
                            selected != null && selected.isRunning && !_busy,
                        onPressed: () =>
                            unawaited(_act(RemoteContainerAction.stop)),
                      ),
                      const SizedBox(width: 4),
                      _ActBtn(
                        label: '重启',
                        enabled: selected != null && !_busy,
                        onPressed: () =>
                            unawaited(_act(RemoteContainerAction.restart)),
                      ),
                      const SizedBox(width: 4),
                      _ActBtn(
                        label: '日志',
                        enabled: selected != null,
                        onPressed: () => _openLogs(selected!),
                      ),
                      const SizedBox(width: 4),
                      _ActBtn(
                        label: '进入',
                        enabled: selected != null && selected.isRunning,
                        onPressed: () => _execShell(selected!),
                      ),
                      const SizedBox(width: 4),
                      _ActBtn(
                        label: '检查',
                        enabled: selected != null && !_busy,
                        onPressed: () => unawaited(_inspect(selected!)),
                      ),
                      const SizedBox(width: 4),
                      _ActBtn(
                        label: '删除',
                        enabled: selected != null && !_busy,
                        onPressed: () =>
                            unawaited(_act(RemoteContainerAction.remove)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_error != null && _items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text(
                _error!,
                style: TextStyle(color: wb.offline, fontSize: 12),
              ),
            ),
          _HeaderRow(
            sort: _sort,
            asc: _sortAsc,
            onSort: _toggleSort,
          ),
          Expanded(
            child: RemoteStateView(
              state: !_connected && _items.isEmpty
                  ? RemoteState.disconnected
                  : (_loading && _items.isEmpty)
                      ? RemoteState.loading
                      : (!_available && _items.isEmpty)
                          ? RemoteState.notInstalled
                          : (_error != null && _items.isEmpty)
                              ? RemoteState.error
                              : list.isEmpty
                                  ? RemoteState.empty
                                  : RemoteState.data,
              message: !_connected && _items.isEmpty
                  ? '未连接'
                  : (!_available && _items.isEmpty)
                      ? (_error ?? '远端未安装 Docker，或当前用户无权访问 docker.sock')
                      : (_error != null && _items.isEmpty)
                          ? _error
                          : '无容器',
              onRetry: !_connected && _items.isEmpty
                  ? () => unawaited(widget.controller.reconnect())
                  : () => unawaited(_tick()),
              retryLabel: !_connected && _items.isEmpty
                  ? '重连'
                  : (!_available && _items.isEmpty)
                      ? '重试'
                      : null,
              data: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final c = list[i];
                  final sel = c.id == _selected;
                  return InkWell(
                    onTap: () => setState(() => _selected = c.id),
                    onDoubleTap: () {
                      setState(() => _selected = c.id);
                      _openLogs(c);
                    },
                    child: Container(
                      color: sel
                          ? wb.accentBlue.withValues(alpha: 0.12)
                          : null,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.circle,
                            size: 8,
                            color: c.isRunning ? wb.online : wb.textMuted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  c.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: wb.primaryText,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  c.image,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: wb.textMuted,
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              c.status,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: wb.secondaryText,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 56,
                            child: Text(
                              c.cpuPercent == null
                                  ? '—'
                                  : '${c.cpuPercent!.toStringAsFixed(1)}%',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: wb.secondaryText,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 72,
                            child: Text(
                              c.memUsage ??
                                  (c.memPercent == null
                                      ? '—'
                                      : '${c.memPercent!.toStringAsFixed(1)}%'),
                              textAlign: TextAlign.right,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: wb.secondaryText,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (showMissingDetail)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: wb.border)),
                color: wb.panel,
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: wb.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '所选容器已不存在（可能已被删除或重建）',
                      style: TextStyle(fontSize: 12, color: wb.textMuted),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _selected = null;
                      _selectedGone = false;
                    }),
                    child: const Text('清除选区'),
                  ),
                ],
              ),
            )
          else if (selected != null)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: wb.border)),
                color: wb.panel,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${selected.shortId}  ·  ${selected.name}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: wb.primaryText,
                    ),
                  ),
                  if (selected.ports != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '端口  ${selected.ports}',
                      style: TextStyle(
                        fontSize: 11,
                        color: wb.textMuted,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                  if (selected.netIo != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      '网络  ${selected.netIo}',
                      style: TextStyle(
                        fontSize: 11,
                        color: wb.textMuted,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ActBtn extends StatelessWidget {
  const _ActBtn({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: enabled ? onPressed : null,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      child: Text(label),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.sort,
    required this.asc,
    required this.onSort,
  });

  final _Sort sort;
  final bool asc;
  final void Function(_Sort) onSort;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    Widget col(String label, _Sort s, {int flex = 1, double? width}) {
      final active = sort == s;
      final child = InkWell(
        onTap: () => onSort(s),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            mainAxisSize: width == null ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: active ? wb.accentBlue : wb.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (active)
                Icon(
                  asc ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 12,
                  color: wb.accentBlue,
                ),
            ],
          ),
        ),
      );
      if (width != null) return SizedBox(width: width, child: child);
      return Expanded(flex: flex, child: child);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: wb.border),
          bottom: BorderSide(color: wb.border),
        ),
        color: wb.panel,
      ),
      child: Row(
        children: [
          const SizedBox(width: 16),
          col('名称 / 镜像', _Sort.name, flex: 3),
          col('状态', _Sort.status, flex: 2),
          col('CPU', _Sort.cpu, width: 56),
          col('内存', _Sort.memory, width: 72),
        ],
      ),
    );
  }
}
