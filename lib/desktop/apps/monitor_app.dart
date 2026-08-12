import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote_gpu.dart';
import '../../services/remote_host_metrics.dart';
import '../../services/remote_network.dart';
import '../../services/remote_process_list.dart';
import '../../services/terminal_session_controller.dart';
import '../../services/remote_exec_capable.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../widgets/remote_state_view.dart';
import '../desktop_window_manager.dart';
import '../widgets/desktop_monitor_widgets.dart';
import '../widgets/desktop_scrollable_actions.dart';

/// 主机资源 + 网络监控：每 5s 拉取；窗口最小化时暂停。
class MonitorApp extends StatefulWidget {
  const MonitorApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final TerminalSessionController controller;

  @override
  State<MonitorApp> createState() => _MonitorAppState();
}

class _MonitorAppState extends State<MonitorApp>
    with SingleTickerProviderStateMixin {
  RemoteExecCapable get _exec => widget.controller as RemoteExecCapable;
late final TabController _tabs;
  Timer? _timer;
  RemoteHostSnapshot? _snap;
  RemoteNetworkSnapshot? _net;
  RemoteGpuSnapshot? _gpu;
  List<RemoteNetIfaceRate> _rates = const [];
  bool _loading = false;
  String? _error;
  RemoteOsKind? _os;
  final List<double> _cpuHist = [];
  final List<double> _memHist = [];
  final Map<int, List<double>> _gpuHist = {};
  final _netFilterCtrl = TextEditingController();
  final _netFilterFocus = FocusNode();
  final _netListFocus = FocusNode();
  int? _selectedListenerIndex;
  String _netFilter = '';
  bool _hideLoopback = true;
  bool _showAllIfaces = false;
  bool _showAllListeners = false;
  bool _showAllMounts = false;
  bool _userPaused = false;
  Duration _interval = const Duration(seconds: 5);
  DateTime? _lastTickAt;

  static const int _histMax = 24;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    widget.wm.addListener(_onWm);
    widget.controller.addListener(_onController);
    widget.window.onConnectionRestored = _onConnectionRestored;
    unawaited(_tick());
    _armTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tabs.dispose();
    _netFilterCtrl.dispose();
    _netFilterFocus.dispose();
    _netListFocus.dispose();
    widget.window.onConnectionRestored = null;
    widget.wm.removeListener(_onWm);
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _moveListenerSelection(int delta, int length) {
    if (length == 0) return;
    final cur = _selectedListenerIndex ?? (delta > 0 ? -1 : length);
    var next = cur + delta;
    if (next < 0) next = 0;
    if (next >= length) next = length - 1;
    setState(() => _selectedListenerIndex = next);
    _netListFocus.requestFocus();
  }

  void _openSelectedListener(List<RemoteListenSocket> listeners) {
    final i = _selectedListenerIndex;
    if (i == null || i < 0 || i >= listeners.length) return;
    final target = listeners[i].browserTarget;
    if (target == null) return;
    widget.wm.open(DesktopAppType.browser, args: {'url': target});
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
    final c = widget.controller;
    if (!c.connected || c.dropped) {
      setState(() {
        _error = '连接已断开，重连后刷新';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = _snap == null && _net == null && _gpu == null;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _exec.snapshot(osHint: _os),
        fetchRemoteNetworkSnapshot(_exec, osHint: _os),
        fetchRemoteGpuSnapshot(_exec, osHint: _os),
      ]);
      if (!mounted) return;
      final snap = results[0] as RemoteHostSnapshot?;
      final net = results[1] as RemoteNetworkSnapshot?;
      final gpu = results[2] as RemoteGpuSnapshot?;
      if (snap == null && net == null && gpu == null) {
        setState(() {
          final detail = _exec.lastRemoteCommandError;
          _error = detail == null ? '无法获取指标' : '刷新失败：$detail';
          _loading = false;
        });
        return;
      }
      if (net != null && net.os != RemoteOsKind.unknown) {
        _os = net.os;
      } else if (gpu != null && gpu.os != RemoteOsKind.unknown) {
        _os = gpu.os;
      }
      if (snap != null) {
        if (snap.cpuUsed01 != null) {
          _cpuHist.add(snap.cpuUsed01!);
          if (_cpuHist.length > _histMax) _cpuHist.removeAt(0);
        }
        if (snap.memUsed01 != null) {
          _memHist.add(snap.memUsed01!);
          if (_memHist.length > _histMax) _memHist.removeAt(0);
        }
      }
      if (gpu != null && gpu.available) {
        for (final g in gpu.gpus) {
          if (g.util01 == null) continue;
          final hist = _gpuHist.putIfAbsent(g.index, () => <double>[]);
          hist.add(g.util01!);
          if (hist.length > _histMax) hist.removeAt(0);
        }
      }
      // 用上一帧 `_net` 算吞吐。
      final rates = net?.ratesAgainst(_net) ?? const <RemoteNetIfaceRate>[];
      setState(() {
        if (snap != null) _snap = snap;
        if (net != null) {
          _net = net;
          _rates = rates;
        }
        if (gpu != null) _gpu = gpu;
        _loading = false;
        _lastTickAt = DateTime.now();
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _pct(double? v) {
    if (v == null) return '—';
    return '${(v * 100).clamp(0, 100).toStringAsFixed(0)}%';
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final connected = widget.controller.connected && !widget.controller.dropped;

    return ColoredBox(
      color: wb.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 0),
            child: Row(
              children: [
                Icon(Icons.monitor_heart_rounded, size: 18, color: wb.accentBlue),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '主机监控',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: wb.primaryText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: DesktopScrollableActions(
                    height: 36,
                    children: [
                      LastUpdatedChip(
                        lastTickAt: _lastTickAt,
                        live: !_paused && connected,
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
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: wb.accentBlue,
                          ),
                        )
                      else
                        IconButton(
                          tooltip: '刷新',
                          iconSize: 18,
                          onPressed:
                              connected ? () => unawaited(_tick()) : null,
                          icon: Icon(
                            Icons.refresh_rounded,
                            color: wb.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (!connected || _error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text(
                _error ?? '未连接',
                style: TextStyle(color: wb.textMuted, fontSize: 13),
              ),
            ),
          TabBar(
            controller: _tabs,
            labelColor: wb.accentBlue,
            unselectedLabelColor: wb.textMuted,
            indicatorColor: wb.accentBlue,
            tabs: const [
              Tab(text: '资源'),
              Tab(text: '网络'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _buildResources(wb),
                _buildNetwork(wb),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResources(WorkbenchColors wb) {
    final s = _snap;
    if (s == null && _error == null && !_loading) {
      return RemoteStateView(
        state: RemoteState.empty,
        message: '暂无资源数据',
        onRetry: () => unawaited(_tick()),
        data: const SizedBox.shrink(),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: 160,
              child: SparklineCard(
                title: 'CPU',
                valueLabel: _pct(s?.cpuUsed01),
                history: List<double>.from(_cpuHist),
                height: 28,
              ),
            ),
            SizedBox(
              width: 160,
              child: SparklineCard(
                title: '内存',
                valueLabel: _pct(s?.memUsed01),
                history: List<double>.from(_memHist),
                height: 28,
              ),
            ),
            _GaugeCard(
              label: '磁盘',
              value: _pct(s?.diskUsed01),
              tone: s?.diskUsed01,
            ),
            _GaugeCard(
              label: 'Inode',
              value: _pct(s?.inodeUsed01),
              tone: s?.inodeUsed01,
            ),
            _GaugeCard(
              label: '负载',
              value: s?.loadLine ?? '—',
              tone: s?.loadPressure01,
            ),
          ],
        ),
        if (_gpu != null && _gpu!.available && _gpu!.gpus.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('GPU', style: TextStyle(fontSize: 11, color: wb.textMuted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final g in _gpu!.gpus)
                Builder(
                  builder: (context) {
                    final sub = [
                      if (g.memUsedMiB != null && g.memTotalMiB != null)
                        '${g.memUsedMiB!.toStringAsFixed(0)}/${g.memTotalMiB!.toStringAsFixed(0)} MiB',
                      if (g.tempC != null) '${g.tempC!.toStringAsFixed(0)}°C',
                    ].join(' · ');
                    return SizedBox(
                      width: 200,
                      child: SparklineCard(
                        title: 'GPU${g.index} · ${g.name}',
                        valueLabel: g.util01 == null
                            ? '—'
                            : '${(g.util01! * 100).toStringAsFixed(0)}%',
                        history:
                            List<double>.from(_gpuHist[g.index] ?? const []),
                        height: 28,
                        peakLabel: sub.isEmpty ? null : sub,
                      ),
                    );
                  },
                ),
            ],
          ),
        ] else if (_gpu != null && !_gpu!.available) ...[
          const SizedBox(height: 14),
          Text(
            _gpu!.error == null
                ? '未检测到 NVIDIA GPU（需 nvidia-smi）'
                : 'GPU：${_gpu!.error}',
            style: TextStyle(fontSize: 11, color: wb.textMuted),
          ),
        ],
        if (s?.hostInfoLine != null) ...[
          const SizedBox(height: 14),
          Text('主机', style: TextStyle(fontSize: 11, color: wb.textMuted)),
          const SizedBox(height: 4),
          Text(
            s!.hostInfoLine!,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: wb.secondaryText,
            ),
          ),
        ],
        if (s?.uptimeLine != null) ...[
          const SizedBox(height: 14),
          Text('运行时间', style: TextStyle(fontSize: 11, color: wb.textMuted)),
          const SizedBox(height: 4),
          Text(
            s!.uptimeLine!,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: wb.secondaryText,
            ),
          ),
        ],
        if (s != null && s.mounts.isNotEmpty) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Text('磁盘挂载', style: TextStyle(fontSize: 11, color: wb.textMuted)),
              const Spacer(),
              if (s.mounts.length > 10)
                TextButton(
                  onPressed: () =>
                      setState(() => _showAllMounts = !_showAllMounts),
                  child: Text(
                    _showAllMounts
                        ? '收起'
                        : '显示前 10（共 ${s.mounts.length}）',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (final m in (_showAllMounts ? s.mounts : s.mounts.take(10)))
            _MonitorMountBar(mount: m),
        ] else if (s?.dfSpaceLine != null) ...[
          const SizedBox(height: 10),
          Text('磁盘', style: TextStyle(fontSize: 11, color: wb.textMuted)),
          const SizedBox(height: 4),
          Text(
            s!.dfSpaceLine!,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: wb.secondaryText,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNetwork(WorkbenchColors wb) {
    final net = _net;
    if (net == null) {
      return Center(
        child: Text(
          _loading ? '采集中…' : '暂无网络数据',
          style: TextStyle(color: wb.textMuted, fontSize: 13),
        ),
      );
    }

    final rates = _rates.isNotEmpty
        ? _rates
        : [
            for (final i in net.interfaces)
              RemoteNetIfaceRate(
                iface: i,
                rxBytesPerSec: null,
                txBytesPerSec: null,
              ),
          ];
    final noLoop = rates.where((r) => !r.iface.isLoopback).toList();
    final base = _hideLoopback && noLoop.isNotEmpty ? noLoop : rates;
    final q = _netFilter.trim().toLowerCase();
    final filtered = q.isEmpty
        ? base
        : [
            for (final r in base)
              if (r.iface.name.toLowerCase().contains(q)) r,
          ];
    final ifaceLimit = 8;
    final shownIfaces =
        _showAllIfaces ? filtered : filtered.take(ifaceLimit).toList();
    final listeners = q.isEmpty
        ? net.listeners
        : [
            for (final s in net.listeners)
              if (s.endpoint.toLowerCase().contains(q) ||
                  (s.pid?.toString().contains(q) ?? false) ||
                  s.protocol.toLowerCase().contains(q))
                s,
          ];
    final listenerLimit = 40;
    final shownListeners = _showAllListeners
        ? listeners
        : listeners.take(listenerLimit).toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(
              child: FilterField(
                controller: _netFilterCtrl,
                focusNode: _netFilterFocus,
                hintText: '筛选网卡 / 端口 / PID…',
                onChanged: (v) => setState(() {
                  _netFilter = v;
                  _selectedListenerIndex = null;
                }),
              ),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: const Text('隐藏回环'),
              selected: _hideLoopback,
              onSelected: (v) => setState(() => _hideLoopback = v),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _GaugeCard(
              label: 'TCP Estab',
              value: net.tcpEstablished?.toString() ?? '—',
            ),
            _GaugeCard(
              label: 'Listen',
              value: net.tcpListen?.toString() ?? '—',
            ),
            _GaugeCard(
              label: 'TimeWait',
              value: net.tcpTimeWait?.toString() ?? '—',
            ),
            _GaugeCard(
              label: '监听端口',
              value: '${net.listeners.length}',
            ),
          ],
        ),
        if (net.summaryLine != null) ...[
          const SizedBox(height: 12),
          Text(
            net.summaryLine!,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: wb.secondaryText,
            ),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Text('网卡吞吐', style: TextStyle(fontSize: 11, color: wb.textMuted)),
            const Spacer(),
            if (filtered.length > ifaceLimit)
              TextButton(
                onPressed: () =>
                    setState(() => _showAllIfaces = !_showAllIfaces),
                child: Text(
                  _showAllIfaces
                      ? '收起'
                      : '显示前 $ifaceLimit（共 ${filtered.length}）',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        for (final r in shownIfaces) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: wb.panel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: wb.border),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Text(
                    r.iface.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: wb.primaryText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '↓ ${formatNetRate(r.rxBytesPerSec)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: wb.online,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '↑ ${formatNetRate(r.txBytesPerSec)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: wb.accentBlue,
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    formatNetBytes(r.iface.rxBytes + r.iface.txBytes),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: wb.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Text('监听中', style: TextStyle(fontSize: 11, color: wb.textMuted)),
            const Spacer(),
            if (listeners.length > listenerLimit)
              TextButton(
                onPressed: () =>
                    setState(() => _showAllListeners = !_showAllListeners),
                child: Text(
                  _showAllListeners
                      ? '收起'
                      : '显示前 $listenerLimit（共 ${listeners.length}）',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (listeners.isEmpty)
          Text(
            q.isEmpty ? '无监听端口' : '无匹配监听',
            style: TextStyle(color: wb.textMuted, fontSize: 12),
          )
        else
          Focus(
            focusNode: _netListFocus,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                    _moveListenerSelection(1, shownListeners.length),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                    _moveListenerSelection(-1, shownListeners.length),
                const SingleActivator(LogicalKeyboardKey.enter): () =>
                    _openSelectedListener(shownListeners),
                const SingleActivator(LogicalKeyboardKey.slash): () =>
                    _netFilterFocus.requestFocus(),
                const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                    () => _netFilterFocus.requestFocus(),
                const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
                    _netFilterFocus.requestFocus(),
              },
              child: Column(
                children: [
                  for (var i = 0; i < shownListeners.length; i++)
                    Builder(
                      builder: (context) {
                        final s = shownListeners[i];
                        final selected = _selectedListenerIndex == i;
                        return Material(
                          color: selected
                              ? wb.accentBlue.withValues(alpha: 0.16)
                              : Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              setState(() => _selectedListenerIndex = i);
                              _netListFocus.requestFocus();
                            },
                            onDoubleTap: s.browserTarget == null
                                ? null
                                : () {
                                    final target = s.browserTarget;
                                    if (target == null) return;
                                    widget.wm.open(
                                      DesktopAppType.browser,
                                      args: {'url': target},
                                    );
                                  },
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 4,
                                horizontal: 4,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 52,
                                    child: Text(
                                      s.protocol.toUpperCase(),
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                        color: wb.textMuted,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      s.endpoint,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                        color: wb.secondaryText,
                                      ),
                                    ),
                                  ),
                                  if (s.pid != null)
                                    Text(
                                      'pid ${s.pid}',
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 10,
                                        color: wb.textMuted,
                                      ),
                                    ),
                                  if (s.browserTarget != null) ...[
                                    const SizedBox(width: 6),
                                    Icon(
                                      Icons.open_in_browser_rounded,
                                      size: 14,
                                      color: wb.textMuted,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _MonitorMountBar extends StatelessWidget {
  const _MonitorMountBar({required this.mount});

  final RemoteDiskMount mount;

  Color _tone(BuildContext context, double t) {
    if (t >= 0.9) return const Color(0xFFEF4444);
    if (t >= 0.75) return const Color(0xFFEAB308);
    return context.wb.online;
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final m = mount;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  m.mountPoint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: wb.primaryText,
                  ),
                ),
              ),
              Text(
                '${(m.used01 * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                  color: _tone(context, m.used01),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${formatDiskBytes(m.usedBytes)} / ${formatDiskBytes(m.sizeBytes)}',
            style: TextStyle(fontSize: 11, color: wb.textMuted),
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: m.used01.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: wb.border,
              color: _tone(context, m.used01),
            ),
          ),
        ],
      ),
    );
  }
}

class _GaugeCard extends StatelessWidget {
  const _GaugeCard({
    required this.label,
    required this.value,
    this.tone,
  });

  final String label;
  final String value;
  final double? tone;

  Color _toneColor(BuildContext context) {
    final t = tone;
    if (t == null) return context.wb.primaryText;
    if (t >= 0.9) return const Color(0xFFEF4444);
    if (t >= 0.75) return const Color(0xFFEAB308);
    return context.wb.online;
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Container(
      width: 148,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: wb.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: wb.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: wb.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: _toneColor(context),
              fontFamily: 'monospace',
            ),
          ),
          if (tone != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: tone!.clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: wb.border,
                color: _toneColor(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
