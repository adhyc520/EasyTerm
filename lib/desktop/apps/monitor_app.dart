import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/remote_host_metrics.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';

/// 主机资源监控：每 5s 拉取 [RemoteHostSnapshot]；窗口最小化时暂停。
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

class _MonitorAppState extends State<MonitorApp> {
  Timer? _timer;
  RemoteHostSnapshot? _snap;
  bool _loading = false;
  String? _error;
  final List<double> _cpuHist = [];
  final List<double> _memHist = [];

  static const int _histMax = 24;

  @override
  void initState() {
    super.initState();
    widget.wm.addListener(_onWm);
    widget.controller.addListener(_onController);
    unawaited(_tick());
    _armTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
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
      _loading = _snap == null;
      _error = null;
    });
    try {
      final snap = await fetchRemoteHostSnapshot(c);
      if (!mounted) return;
      if (snap == null) {
        setState(() {
          _error = '无法获取指标';
          _loading = false;
        });
        return;
      }
      if (snap.cpuUsed01 != null) {
        _cpuHist.add(snap.cpuUsed01!);
        if (_cpuHist.length > _histMax) _cpuHist.removeAt(0);
      }
      if (snap.memUsed01 != null) {
        _memHist.add(snap.memUsed01!);
        if (_memHist.length > _histMax) _memHist.removeAt(0);
      }
      setState(() {
        _snap = snap;
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
    final s = _snap;
    final connected = widget.controller.connected && !widget.controller.dropped;

    return ColoredBox(
      color: wb.bg,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
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
          if (!connected || _error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error ?? '未连接',
              style: TextStyle(color: wb.textMuted, fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
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
          if (s?.uptimeLine != null) ...[
            const SizedBox(height: 14),
            Text(
              '运行时间',
              style: TextStyle(fontSize: 11, color: wb.textMuted),
            ),
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
          if (s?.dfSpaceLine != null) ...[
            const SizedBox(height: 10),
            Text(
              '磁盘',
              style: TextStyle(fontSize: 11, color: wb.textMuted),
            ),
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
  });

  final String label;
  final String value;
  final double? tone;
  final List<double>? history;

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
          Text(label, style: TextStyle(fontSize: 11, color: wb.textMuted)),
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
