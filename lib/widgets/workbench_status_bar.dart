import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';

/// 底部状态栏：远端 CPU / 内存 / 磁盘 / inode / 负载 + uptime（图标 + 悬浮说明）。
class WorkbenchStatusBar extends StatefulWidget {
  const WorkbenchStatusBar({super.key, this.controller});

  final SshWorkspaceController? controller;

  @override
  State<WorkbenchStatusBar> createState() => _WorkbenchStatusBarState();
}

/// 单次 SSH 拉取的多段输出解析结果。
class _ParsedRemoteSnapshot {
  _ParsedRemoteSnapshot({
    this.memUsed01,
    this.cpuUsed01,
    this.diskUsed01,
    this.inodeUsed01,
    this.loadPressure01,
    this.loadLine,
    this.dfSpaceLine,
    this.dfInodeLine,
    this.uptimeLine,
  });

  final double? memUsed01;
  final double? cpuUsed01;
  final double? diskUsed01;
  final double? inodeUsed01;
  final double? loadPressure01;
  final String? loadLine;
  final String? dfSpaceLine;
  final String? dfInodeLine;
  final String? uptimeLine;

  static _ParsedRemoteSnapshot? parse(String raw) {
    if (raw.isEmpty) return null;
    const a = '__A__';
    const b = '__B__';
    const c = '__C__';
    const d = '__D__';
    const e = '__E__';
    const f = '__F__';
    const g = '__G__';
    const z = '__Z__';
    if (!raw.contains(a)) return null;

    String section(String start, String end) {
      final i0 = raw.indexOf(start);
      if (i0 < 0) return '';
      var from = i0 + start.length;
      while (from < raw.length && (raw[from] == '\n' || raw[from] == '\r')) {
        from++;
      }
      final i1 = raw.indexOf(end, from);
      if (i1 < 0) return raw.substring(from).trim();
      return raw.substring(from, i1).trim();
    }

    final memBlock = section(a, b);
    final vmBlock = section(b, c);
    final dfP = section(c, d);
    final dfPi = section(d, e);
    final loadBlock = section(e, f);
    final nprocBlock = section(f, g);
    final uptimeBlock = section(g, z);

    final mem = _parseMeminfo(memBlock);
    final cpu = _parseVmstatIdle(vmBlock);
    final disk = _parseDfPercent(dfP);
    final inode = _parseDfPercent(dfPi);
    final loadParts = _parseLoadavg(loadBlock);
    final nproc = int.tryParse(nprocBlock.split('\n').first.trim()) ?? 1;
    double? loadPressure;
    if (loadParts != null && loadParts.isNotEmpty && nproc > 0) {
      loadPressure = (loadParts[0] / nproc).clamp(0.0, 1.0);
    }

    final uptime = uptimeBlock.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).join(' ');

    return _ParsedRemoteSnapshot(
      memUsed01: mem,
      cpuUsed01: cpu,
      diskUsed01: disk,
      inodeUsed01: inode,
      loadPressure01: loadPressure,
      loadLine: loadParts?.map((e) => e.toStringAsFixed(2)).join(', '),
      dfSpaceLine: dfP.isEmpty ? null : dfP.replaceAll('|', ' '),
      dfInodeLine: dfPi.isEmpty ? null : dfPi.replaceAll('|', ' '),
      uptimeLine: uptime.isEmpty ? null : uptime,
    );
  }
}

double? _parseMeminfo(String block) {
  if (block.isEmpty) return null;
  int? kb(String prefix) {
    for (final line in block.split('\n')) {
      final t = line.trim();
      if (!t.startsWith(prefix)) continue;
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length >= 2) return int.tryParse(parts[1]);
    }
    return null;
  }

  final total = kb('MemTotal:');
  final avail = kb('MemAvailable:');
  if (total != null && total > 0 && avail != null) {
    return ((total - avail) / total).clamp(0.0, 1.0);
  }
  final free = kb('MemFree:');
  final buffers = kb('Buffers:') ?? 0;
  final cached = kb('Cached:') ?? 0;
  if (total != null && total > 0 && free != null) {
    final approxAvail = free + buffers + cached;
    return ((total - approxAvail) / total).clamp(0.0, 1.0);
  }
  return null;
}

double? _parseVmstatIdle(String block) {
  if (block.isEmpty) return null;
  String? lastNumeric;
  for (final line in block.split('\n')) {
    final t = line.trimLeft();
    if (t.isEmpty) continue;
    if (RegExp(r'^\d').hasMatch(t)) lastNumeric = line;
  }
  if (lastNumeric == null) return null;
  final fields = lastNumeric.trim().split(RegExp(r'\s+'));
  if (fields.length < 15) return null;
  // 常见 Linux vmstat 数据行：… us sy id wa [st]，id 在 0-based 第 14 列（15 列及以上）
  final idle = double.tryParse(fields[14]);
  if (idle == null) return null;
  return ((100 - idle) / 100).clamp(0.0, 1.0);
}

double? _parseDfPercent(String line) {
  if (line.isEmpty) return null;
  for (final part in line.split(RegExp(r'\s+'))) {
    if (part.endsWith('%')) {
      final n = double.tryParse(part.replaceAll('%', ''));
      if (n != null) return (n / 100).clamp(0.0, 1.0);
    }
  }
  return null;
}

List<double>? _parseLoadavg(String block) {
  final line = block.split('\n').first.trim();
  if (line.isEmpty) return null;
  final parts = line.split(RegExp(r'\s+'));
  if (parts.length < 3) return null;
  final a = double.tryParse(parts[0]);
  final b = double.tryParse(parts[1]);
  final c = double.tryParse(parts[2]);
  if (a == null || b == null || c == null) return null;
  return [a, b, c];
}

/// 多段输出：避免远端 awk 引号问题，在客户端解析。
const String _kRemoteStatusBundle = r'''
printf '__A__\n'
cat /proc/meminfo 2>/dev/null
printf '__B__\n'
vmstat 1 2 2>/dev/null
printf '__C__\n'
df -P / 2>/dev/null | tail -n 1
printf '__D__\n'
df -Pi / 2>/dev/null | tail -n 1
printf '__E__\n'
cat /proc/loadavg 2>/dev/null
printf '__F__\n'
nproc 2>/dev/null || echo 1
printf '__G__\n'
uptime 2>/dev/null || true
printf '__Z__\n'
''';

class _WorkbenchStatusBarState extends State<WorkbenchStatusBar> {
  Timer? _pollTimer;
  Timer? _clockTimer;
  String? _uptimeSnippet;
  _ParsedRemoteSnapshot? _snap;

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(seconds: 22), (_) => _poll());
    scheduleMicrotask(_poll);
  }

  @override
  void didUpdateWidget(covariant WorkbenchStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
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

    final bundle = await c.runRemoteForStatus(_kRemoteStatusBundle.replaceAll('\n', ';'));
    if (!mounted) return;

    final snap = _ParsedRemoteSnapshot.parse(bundle ?? '');
    final uptime = snap?.uptimeLine;
    setState(() {
      _snap = snap;
      if (uptime != null && uptime.isNotEmpty) {
        _uptimeSnippet = uptime.length > 96 ? '${uptime.substring(0, 93)}…' : uptime;
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
    final tail = (up != null && up.isNotEmpty) ? l10n.statusRemoteUptimeLine(up) : l10n.statusNoRemoteInfo;
    if (lang == 'zh') {
      return '北京时间 $clock · $tail';
    }
    return '$clock · $tail';
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
        height: 56,
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

String _tooltipMem(AppLocalizations l, _ParsedRemoteSnapshot? s) {
  if (s?.memUsed01 == null) return l.tooltipMemNoData;
  final p = (s!.memUsed01! * 100).toStringAsFixed(1);
  return l.tooltipMem(p);
}

String _tooltipCpu(AppLocalizations l, _ParsedRemoteSnapshot? s) {
  if (s?.cpuUsed01 == null) return l.tooltipCpuNoData;
  final p = (s!.cpuUsed01! * 100).toStringAsFixed(1);
  return l.tooltipCpu(p);
}

String _tooltipDisk(AppLocalizations l, _ParsedRemoteSnapshot? s) {
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

String _tooltipInode(AppLocalizations l, _ParsedRemoteSnapshot? s) {
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

String _tooltipLoad(AppLocalizations l, _ParsedRemoteSnapshot? s) {
  final buf = StringBuffer(l.tooltipLoadTitle);
  if (s?.loadLine != null && s!.loadLine!.isNotEmpty) {
    buf.write(l.tooltipLoadLine(s.loadLine!));
  } else {
    buf.write(l.tooltipLoadNoData);
  }
  if (s?.loadPressure01 != null) {
    buf.write(l.tooltipLoadPressure((s!.loadPressure01! * 100).toStringAsFixed(0)));
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
