import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/remote_gpu.dart';
import '../../services/remote_host_metrics.dart';
import '../../services/remote_network.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';

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
  final SshWorkspaceController controller;

  @override
  State<MonitorApp> createState() => _MonitorAppState();
}

class _MonitorAppState extends State<MonitorApp>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  Timer? _timer;
  RemoteHostSnapshot? _snap;
  RemoteNetworkSnapshot? _net;
  RemoteGpuSnapshot? _gpu;
  List<RemoteNetIfaceRate> _rates = const [];
  bool _loading = false;
  String? _error;
  final List<double> _cpuHist = [];
  final List<double> _memHist = [];

  static const int _histMax = 24;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    widget.wm.addListener(_onWm);
    widget.controller.addListener(_onController);
    unawaited(_tick());
    _armTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tabs.dispose();
    widget.wm.removeListener(_onWm);
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _onWm() {
    _armTimer();
    if (mounted) setState(() {});
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  bool get _paused => widget.window.state == WindowState.minimized;

  void _armTimer() {
    _timer?.cancel();
    if (_paused) {
      _timer = null;
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
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
        fetchRemoteHostSnapshot(c),
        fetchRemoteNetworkSnapshot(c),
        fetchRemoteGpuSnapshot(c),
      ]);
      if (!mounted) return;
      final snap = results[0] as RemoteHostSnapshot?;
      final net = results[1] as RemoteNetworkSnapshot?;
      final gpu = results[2] as RemoteGpuSnapshot?;
      if (snap == null && net == null && gpu == null) {
        setState(() {
          _error = '无法获取指标';
          _loading = false;
        });
        return;
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
                Text(
                  '主机监控',
                  style: TextStyle(
                    color: wb.primaryText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
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
                    onPressed: connected ? () => unawaited(_tick()) : null,
                    icon: Icon(Icons.refresh_rounded, color: wb.textMuted),
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
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _GaugeCard(
              label: 'CPU',
              value: _pct(s?.cpuUsed01),
              tone: s?.cpuUsed01,
              history: _cpuHist,
            ),
            _GaugeCard(
              label: '内存',
              value: _pct(s?.memUsed01),
              tone: s?.memUsed01,
              history: _memHist,
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
                _GaugeCard(
                  label: 'GPU${g.index} · ${g.name}',
                  value: g.util01 == null
                      ? '—'
                      : '${(g.util01! * 100).toStringAsFixed(0)}%',
                  tone: g.util01,
                  subtitle: [
                    if (g.memUsedMiB != null && g.memTotalMiB != null)
                      '${g.memUsedMiB!.toStringAsFixed(0)}/${g.memTotalMiB!.toStringAsFixed(0)} MiB',
                    if (g.tempC != null) '${g.tempC!.toStringAsFixed(0)}°C',
                  ].join(' · '),
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
          Text('磁盘挂载', style: TextStyle(fontSize: 11, color: wb.textMuted)),
          const SizedBox(height: 8),
          for (final m in s.mounts.take(10)) _MonitorMountBar(mount: m),
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
    final shown = rates.where((r) => !r.iface.isLoopback).toList();
    final use = shown.isNotEmpty ? shown : rates;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
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
        Text('网卡吞吐', style: TextStyle(fontSize: 11, color: wb.textMuted)),
        const SizedBox(height: 6),
        for (final r in use.take(8)) ...[
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
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: wb.accentBlue,
                    ),
                  ),
                ),
                Text(
                  formatNetBytes(r.iface.rxBytes + r.iface.txBytes),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    color: wb.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Text('监听中', style: TextStyle(fontSize: 11, color: wb.textMuted)),
        const SizedBox(height: 6),
        if (net.listeners.isEmpty)
          Text(
            '无监听端口',
            style: TextStyle(color: wb.textMuted, fontSize: 12),
          )
        else
          for (final s in net.listeners.take(40))
            Material(
              color: Colors.transparent,
              child: InkWell(
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
                  padding: const EdgeInsets.symmetric(vertical: 4),
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
                    ],
                  ),
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
    this.history,
    this.subtitle,
  });

  final String label;
  final String value;
  final double? tone;
  final List<double>? history;
  final String? subtitle;

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
    final hist = history;
    final sub = subtitle?.trim();
    return Container(
      width: sub == null || sub.isEmpty ? 148 : 200,
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
          if (sub != null && sub.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: wb.textMuted),
            ),
          ],
          if (hist != null && hist.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 28,
              width: double.infinity,
              child: CustomPaint(
                painter: _SparklinePainter(
                  values: List<double>.from(hist),
                  color: wb.accentBlue,
                ),
              ),
            ),
          ],
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

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final n = values.length;
    for (var i = 0; i < n; i++) {
      final x = n == 1 ? 0.0 : size.width * i / (n - 1);
      final y = size.height * (1 - values[i].clamp(0.0, 1.0));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}
