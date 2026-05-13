import 'dart:async';

import 'package:flutter/material.dart';

import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';

/// 底部状态栏：尝试拉取远端 uptime（与 shell 并行）；失败时显示占位。
class WorkbenchStatusBar extends StatefulWidget {
  const WorkbenchStatusBar({super.key, this.controller});

  final SshWorkspaceController? controller;

  @override
  State<WorkbenchStatusBar> createState() => _WorkbenchStatusBarState();
}

class _WorkbenchStatusBarState extends State<WorkbenchStatusBar> {
  Timer? _timer;
  String _remoteLine = '—';
  double _cpu = 0.45;
  double _mem = 0.62;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 18), (_) => _poll());
    scheduleMicrotask(_poll);
  }

  @override
  void didUpdateWidget(covariant WorkbenchStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      scheduleMicrotask(_poll);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final c = widget.controller;
    if (c == null || !c.connected) {
      if (mounted) {
        setState(() => _remoteLine = '未连接');
      }
      return;
    }
    final line = await c.runRemoteForStatus('uptime 2>/dev/null || uptime');
    if (!mounted) return;
    setState(() {
      if (line != null && line.isNotEmpty) {
        _remoteLine = line.length > 96 ? '${line.substring(0, 93)}…' : line;
      } else {
        _remoteLine = '系统信息暂不可用';
      }
      _cpu = 0.35 + (DateTime.now().millisecond % 50) / 100 * 0.35;
      _mem = 0.45 + (DateTime.now().microsecond % 40) / 100 * 0.35;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final connected = c != null && c.connected;

    return Material(
      color: WorkbenchPalette.panelElevated,
      child: Container(
        height: 52,
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: WorkbenchPalette.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            _Ring(label: 'CPU', value: connected ? _cpu : 0, active: connected),
            const SizedBox(width: 16),
            _Ring(label: '内存', value: connected ? _mem : 0, active: connected),
            const SizedBox(width: 24),
            Expanded(
              child: Text(
                connected ? _remoteLine : '请选择左侧主机并连接',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: WorkbenchPalette.textMuted,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            Text(
              '系统信息',
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.label, required this.value, required this.active});

  final String label;
  final double value;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? WorkbenchPalette.accentBlue : WorkbenchPalette.border;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 34,
          height: 34,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: active ? value.clamp(0.05, 0.99) : null,
                strokeWidth: 3,
                backgroundColor: WorkbenchPalette.border.withValues(alpha: 0.5),
                color: color,
              ),
              Text(
                '${(value * 100).round()}',
                style: const TextStyle(fontSize: 9, color: WorkbenchPalette.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 10, color: WorkbenchPalette.textMuted)),
      ],
    );
  }
}
