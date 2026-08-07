import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/workbench_theme.dart';

/// 列表过滤输入框（/ 或 Ctrl+F 聚焦由调用方 Shortcuts 绑定）。
class FilterField extends StatelessWidget {
  const FilterField({
    super.key,
    required this.controller,
    this.hintText = '筛选…',
    this.onChanged,
    this.focusNode,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      style: TextStyle(fontSize: 12, color: wb.primaryText),
      decoration: InputDecoration(
        isDense: true,
        hintText: hintText,
        hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
        prefixIcon: Icon(Icons.search_rounded, size: 16, color: wb.textMuted),
        prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 0),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清除',
                iconSize: 16,
                onPressed: () {
                  controller.clear();
                  onChanged?.call('');
                },
                icon: Icon(Icons.clear_rounded, color: wb.textMuted),
              ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
      ),
      onChanged: onChanged,
    );
  }
}

/// 暂停/恢复轮询 + 间隔下拉。
class PauseToggle extends StatelessWidget {
  const PauseToggle({
    super.key,
    required this.paused,
    required this.onPausedChanged,
    required this.interval,
    required this.onIntervalChanged,
    this.intervals = const [
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
  });

  final bool paused;
  final ValueChanged<bool> onPausedChanged;
  final Duration interval;
  final ValueChanged<Duration> onIntervalChanged;
  final List<Duration> intervals;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (paused)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Chip(
              visualDensity: VisualDensity.compact,
              label:                 Text(
                  AppLocalizations.of(context)?.desktopPaused ?? '已暂停',
                  style: TextStyle(fontSize: 11, color: wb.secondaryText),
                ),
              backgroundColor: wb.panelElevated,
              side: BorderSide(color: wb.border),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        IconButton(
          tooltip: paused ? '恢复刷新' : '暂停刷新',
          iconSize: 18,
          onPressed: () => onPausedChanged(!paused),
          icon: Icon(
            paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            color: wb.textMuted,
          ),
        ),
        PopupMenuButton<Duration>(
          tooltip: '刷新间隔',
          initialValue: interval,
          onSelected: onIntervalChanged,
          itemBuilder: (ctx) => [
            for (final d in intervals)
              PopupMenuItem(
                value: d,
                child: Text('${d.inSeconds}s'),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${interval.inSeconds}s',
              style: TextStyle(fontSize: 11, color: wb.textMuted),
            ),
          ),
        ),
      ],
    );
  }
}

/// 「更新于 Ns 前」+ 活动呼吸点。
class LastUpdatedChip extends StatefulWidget {
  const LastUpdatedChip({
    super.key,
    required this.lastTickAt,
    this.live = true,
  });

  final DateTime? lastTickAt;
  final bool live;

  @override
  State<LastUpdatedChip> createState() => _LastUpdatedChipState();
}

class _LastUpdatedChipState extends State<LastUpdatedChip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final at = widget.lastTickAt;
    final label = at == null
        ? '尚未更新'
        : '更新于 ${_ago(DateTime.now().difference(at))}';
    final color = widget.live ? wb.accentBlue : wb.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: wb.textMuted),
        ),
      ],
    );
  }

  String _ago(Duration d) {
    if (d.inSeconds < 1) return '刚刚';
    if (d.inSeconds < 60) return '${d.inSeconds}s 前';
    if (d.inMinutes < 60) return '${d.inMinutes}m 前';
    return '${d.inHours}h 前';
  }
}

/// CPU/MEM/网络/GPU 趋势卡；网络 rx/tx 可共享刻度。
class SparklineCard extends StatelessWidget {
  const SparklineCard({
    super.key,
    required this.title,
    required this.valueLabel,
    required this.history,
    this.secondaryHistory,
    this.peakLabel,
    this.height = 56,
    this.sharedScale = false,
  });

  final String title;
  final String valueLabel;
  final List<double> history;
  final List<double>? secondaryHistory;
  final String? peakLabel;
  final double height;
  final bool sharedScale;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: wb.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: wb.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: wb.secondaryText,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                valueLabel,
                style: TextStyle(
                  fontSize: 13,
                  color: wb.primaryText,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (peakLabel != null) ...[
            const SizedBox(height: 2),
            Text(
              peakLabel!,
              style: TextStyle(fontSize: 10, color: wb.textMuted),
            ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            height: height,
            child: CustomPaint(
              painter: _SparkPainter(
                primary: history,
                secondary: secondaryHistory,
                sharedScale: sharedScale,
                primaryColor: wb.accentBlue,
                secondaryColor: wb.online,
                gridColor: wb.border,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.primary,
    required this.secondary,
    required this.sharedScale,
    required this.primaryColor,
    required this.secondaryColor,
    required this.gridColor,
  });

  final List<double> primary;
  final List<double>? secondary;
  final bool sharedScale;
  final Color primaryColor;
  final Color secondaryColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      grid,
    );

    double maxV = 1;
    void consider(List<double> xs) {
      for (final v in xs) {
        if (v > maxV) maxV = v;
      }
    }

    if (sharedScale) {
      consider(primary);
      if (secondary != null) consider(secondary!);
    }

    void drawSeries(List<double> xs, Color color, {required bool ownScale}) {
      if (xs.length < 2) return;
      var localMax = ownScale ? 1.0 : maxV;
      if (ownScale) {
        for (final v in xs) {
          if (v > localMax) localMax = v;
        }
      }
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..isAntiAlias = true;
      final path = Path();
      for (var i = 0; i < xs.length; i++) {
        final x = size.width * i / (xs.length - 1);
        final y = size.height * (1 - (xs[i] / localMax).clamp(0.0, 1.0));
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }

    drawSeries(primary, primaryColor, ownScale: !sharedScale);
    if (secondary != null) {
      drawSeries(secondary!, secondaryColor, ownScale: !sharedScale);
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) =>
      oldDelegate.primary != primary ||
      oldDelegate.secondary != secondary ||
      oldDelegate.sharedScale != sharedScale;
}

/// 右键菜单「复制」项。
PopupMenuItem<void> copyMenuItem({
  required String label,
  required String Function() valueBuilder,
}) {
  return PopupMenuItem<void>(
    onTap: () {
      final v = valueBuilder();
      if (v.isEmpty) return;
      Clipboard.setData(ClipboardData(text: v));
    },
    child: Text(label),
  );
}

/// 可点击复制的等宽文本。
class CopyableText extends StatelessWidget {
  const CopyableText(
    this.text, {
    super.key,
    this.style,
    this.tooltip = '点击复制',
  });

  final String text;
  final TextStyle? style;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () {
          if (text.isEmpty) return;
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text('已复制'),
              duration: Duration(seconds: 1),
            ),
          );
        },
        child: Text(text, style: style),
      ),
    );
  }
}

/// 解析防火墙端口规格中的端口号（如 `22/tcp` → 22）。
int? parseFirewallPortNumber(String spec) {
  final m = RegExp(r'^(\d+)').firstMatch(spec.trim());
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

double jointMax(Iterable<double> a, [Iterable<double>? b]) {
  var m = 1.0;
  for (final v in a) {
    m = math.max(m, v);
  }
  if (b != null) {
    for (final v in b) {
      m = math.max(m, v);
    }
  }
  return m;
}
