import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/remote_host_metrics.dart';
import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';

/// 底部状态栏：远端 CPU / 内存 / 磁盘 / inode / 负载 + uptime（图标 + 悬浮说明）。
class WorkbenchStatusBar extends StatefulWidget {
  const WorkbenchStatusBar({super.key, this.controller});

  final SshWorkspaceController? controller;

  @override
  State<WorkbenchStatusBar> createState() => _WorkbenchStatusBarState();
}

class _WorkbenchStatusBarState extends State<WorkbenchStatusBar> {
  Timer? _pollTimer;
  Timer? _clockTimer;
  String? _uptimeSnippet;
  RemoteHostSnapshot? _snap;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_onController);
    _pollTimer = Timer.periodic(const Duration(seconds: 22), (_) => _poll());
    scheduleMicrotask(_poll);
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant WorkbenchStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onController);
      widget.controller?.addListener(_onController);
      scheduleMicrotask(_poll);
    }
    _syncClockTimer();
  }

  void _syncClockTimer() {
    final need = widget.controller?.connected == true;
    if (need) {
      if (_clockTimer == null || !_clockTimer!.isActive) {
        _clockTimer?.cancel();
        _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          if (widget.controller?.connected == true) setState(() {});
        });
      }
    } else {
      _clockTimer?.cancel();
      _clockTimer = null;
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onController);
    _pollTimer?.cancel();
    _clockTimer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final c = widget.controller;
    if (c == null || !c.connected) {
      if (mounted) {
        setState(() {
          _snap = null;
          _uptimeSnippet = null;
        });
      }
      _syncClockTimer();
      return;
    }

    _syncClockTimer();

    final snap = await fetchRemoteHostSnapshot(c);
    if (!mounted) return;

    final uptime = snap?.uptimeLine;
    setState(() {
      _snap = snap;
      if (uptime != null && uptime.isNotEmpty) {
        _uptimeSnippet = uptime.length > 96
            ? '${uptime.substring(0, 93)}…'
            : uptime;
      } else {
        _uptimeSnippet = null;
      }
    });
  }

  static String _wallClockForLocale(String languageCode) {
    final d = languageCode == 'zh'
        ? DateTime.now().toUtc().add(const Duration(hours: 8))
        : DateTime.now();
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(d);
  }

  String _statusLineText(AppLocalizations l10n, String lang, bool connected) {
    final c = widget.controller;
    if (!connected) {
      if (c == null) return l10n.statusPickHost;
      return l10n.statusNotConnected;
    }
    final clock = _wallClockForLocale(lang);
    final up = _uptimeSnippet;
    final tail = (up != null && up.isNotEmpty)
        ? l10n.statusRemoteUptimeLine(up)
        : l10n.statusNoRemoteInfo;
    if (lang == 'zh') {
      return '北京时间 $clock · $tail';
    }
    return '$clock · $tail';
  }

  static String _shortCwd(String path) {
    final parts = path.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return path.isEmpty ? '/' : path;
    if (parts.length <= 2) return path;
    return '…/${parts[parts.length - 2]}/${parts.last}';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final connected = c != null && c.connected;
    final s = _snap;
    final l10n = AppLocalizations.of(context)!;
    final lang = Localizations.localeOf(context).languageCode;

    return Material(
      color: context.wb.panelElevated,
      child: Container(
        height: context.wbScaled(56),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: context.wb.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            if (connected) ...[
              _IconMetricRing(
                icon: Icons.speed_rounded,
                value01: s?.cpuUsed01,
                active: true,
                tooltip: _tooltipCpu(l10n, s),
              ),
              const SizedBox(width: 10),
              _IconMetricRing(
                icon: Icons.memory_rounded,
                value01: s?.memUsed01,
                active: true,
                tooltip: _tooltipMem(l10n, s),
              ),
              const SizedBox(width: 10),
              _IconMetricRing(
                icon: Icons.storage_rounded,
                value01: s?.diskUsed01,
                active: true,
                tooltip: _tooltipDisk(l10n, s),
              ),
              const SizedBox(width: 10),
              _IconMetricRing(
                icon: Icons.account_tree_outlined,
                value01: s?.inodeUsed01,
                active: true,
                tooltip: _tooltipInode(l10n, s),
              ),
              const SizedBox(width: 10),
              _IconMetricRing(
                icon: Icons.show_chart_rounded,
                value01: s?.loadPressure01,
                active: true,
                tooltip: _tooltipLoad(l10n, s),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Tooltip(
                  message: c.followTerminalCwd && !c.sawOsc7
                      ? '${c.terminalCwd}\n${l10n.statusBarCwdNoOsc7Hint}'
                      : c.terminalCwd,
                  child: Text(
                    c.followTerminalCwd && !c.sawOsc7
                        ? '${_shortCwd(c.terminalCwd.isNotEmpty ? c.terminalCwd : c.remoteCwd)} · · ·'
                        : _shortCwd(c.terminalCwd.isNotEmpty ? c.terminalCwd : c.remoteCwd),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: c.followTerminalCwd && !c.sawOsc7
                          ? context.wb.offline
                          : context.wb.textMuted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: Text(
                _statusLineText(l10n, lang, connected),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.wb.textMuted,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _tooltipMem(AppLocalizations l, RemoteHostSnapshot? s) {
  if (s?.memUsed01 == null) return l.tooltipMemNoData;
  final p = (s!.memUsed01! * 100).toStringAsFixed(1);
  return l.tooltipMem(p);
}

String _tooltipCpu(AppLocalizations l, RemoteHostSnapshot? s) {
  if (s?.cpuUsed01 == null) return l.tooltipCpuNoData;
  final p = (s!.cpuUsed01! * 100).toStringAsFixed(1);
  return l.tooltipCpu(p);
}

String _tooltipDisk(AppLocalizations l, RemoteHostSnapshot? s) {
  final buf = StringBuffer(l.tooltipDiskTitle);
  if (s?.diskUsed01 != null) {
    buf.write(l.tooltipDiskUsed((s!.diskUsed01! * 100).toStringAsFixed(1)));
  } else {
    buf.write(l.tooltipDiskNoUsage);
  }
  if (s?.dfSpaceLine != null && s!.dfSpaceLine!.isNotEmpty) {
    buf.write('\n${s.dfSpaceLine}');
  }
  return buf.toString();
}

String _tooltipInode(AppLocalizations l, RemoteHostSnapshot? s) {
  final buf = StringBuffer(l.tooltipInodeTitle);
  if (s?.inodeUsed01 != null) {
    buf.write(l.tooltipInodeUsed((s!.inodeUsed01! * 100).toStringAsFixed(1)));
  } else {
    buf.write(l.tooltipInodeNoUsage);
  }
  if (s?.dfInodeLine != null && s!.dfInodeLine!.isNotEmpty) {
    buf.write('\n${s.dfInodeLine}');
  }
  return buf.toString();
}

String _tooltipLoad(AppLocalizations l, RemoteHostSnapshot? s) {
  final buf = StringBuffer(l.tooltipLoadTitle);
  if (s?.loadLine != null && s!.loadLine!.isNotEmpty) {
    buf.write(l.tooltipLoadLine(s.loadLine!));
  } else {
    buf.write(l.tooltipLoadNoData);
  }
  if (s?.loadPressure01 != null) {
    buf.write(
      l.tooltipLoadPressure((s!.loadPressure01! * 100).toStringAsFixed(0)),
    );
  }
  return buf.toString();
}

class _IconMetricRing extends StatelessWidget {
  const _IconMetricRing({
    required this.icon,
    required this.value01,
    required this.active,
    required this.tooltip,
  });

  final IconData icon;
  final double? value01;
  final bool active;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final v = value01;
    final hasValue = v != null && v.isFinite;
    final display = hasValue ? v.clamp(0.0, 1.0) : 0.0;
    final color = active ? context.wb.accentBlue : context.wb.border;

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      showDuration: const Duration(seconds: 12),
      child: SizedBox(
        width: 36,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(
                value: active && hasValue ? display.clamp(0.02, 0.99) : null,
                strokeWidth: 2.5,
                backgroundColor: context.wb.border.withValues(alpha: 0.45),
                color: color,
              ),
            ),
            Icon(icon, size: 16, color: context.wb.textMuted),
          ],
        ),
      ),
    );
  }
}
