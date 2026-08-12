import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/remote_host_metrics.dart';
import '../../services/terminal_session_controller.dart';
import '../../services/remote_exec_capable.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import 'desktop_widget.dart';

class MonitorDesktopWidget extends DesktopWidgetKind {
  MonitorDesktopWidget(this.controller);

  final TerminalSessionController controller;

  @override
  String get id => 'monitor';

  @override
  String get name => '系统监控';

  @override
  IconData get icon => Icons.monitor_heart_rounded;

  @override
  DesktopWidgetConfig defaultConfig() => DesktopWidgetConfig(
        position: const Offset(32, 160),
        size: const Size(220, 120),
      );

  @override
  Widget build(BuildContext context, DesktopWidgetConfig config) {
    return _MonitorBody(controller: controller);
  }
}

class _MonitorBody extends StatefulWidget {
  const _MonitorBody({required this.controller});
  final TerminalSessionController controller;

  @override
  State<_MonitorBody> createState() => _MonitorBodyState();
}

class _MonitorBodyState extends State<_MonitorBody> {
  Timer? _timer;
  RemoteHostSnapshot? _snap;

  @override
  void initState() {
    super.initState();
    unawaited(_tick());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_tick());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    final c = widget.controller;
    if (!c.connected || c.dropped) return;
    try {
      final snap = await (c as RemoteExecCapable).snapshot();
      if (mounted) setState(() => _snap = snap);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final cpu = ((_snap?.cpuUsed01 ?? 0) * 100);
    final mem = ((_snap?.memUsed01 ?? 0) * 100);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '系统',
            style: TextStyle(
              color: wb.primaryText,
              fontWeight: FontWeight.w600,
              fontSize: 12,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          _bar(wb, 'CPU', cpu),
          const SizedBox(height: 4),
          _bar(wb, 'MEM', mem),
        ],
      ),
    );
  }

  Widget _bar(WorkbenchColors wb, String label, double pct) {
    final v = (pct / 100).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(
            label,
            style: TextStyle(
              color: wb.textMuted,
              fontSize: 11,
              height: 1.2,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: v,
              minHeight: 6,
              backgroundColor: wb.border,
              color: wb.accentBlue,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${pct.round()}%',
          style: TextStyle(
            color: wb.textMuted,
            fontSize: 11,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}
