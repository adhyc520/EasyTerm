import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/workbench_theme.dart';
import 'desktop_widget.dart';

class ClockDesktopWidget extends DesktopWidgetKind {
  @override
  String get id => 'clock';

  @override
  String get name => '时钟';

  @override
  IconData get icon => Icons.access_time_rounded;

  @override
  DesktopWidgetConfig defaultConfig() => DesktopWidgetConfig(
        position: const Offset(32, 32),
        size: const Size(200, 120),
      );

  @override
  Widget build(BuildContext context, DesktopWidgetConfig config) {
    return const _ClockBody();
  }
}

class _ClockBody extends StatefulWidget {
  const _ClockBody();

  @override
  State<_ClockBody> createState() => _ClockBodyState();
}

class _ClockBodyState extends State<_ClockBody> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final hh = _now.hour.toString().padLeft(2, '0');
    final mm = _now.minute.toString().padLeft(2, '0');
    final date =
        '${_now.year}-${_now.month.toString().padLeft(2, '0')}-${_now.day.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: FittedBox(
        alignment: Alignment.centerLeft,
        fit: BoxFit.scaleDown,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$hh:$mm',
              style: TextStyle(
                color: wb.primaryText,
                fontSize: 36,
                fontWeight: FontWeight.w300,
                letterSpacing: 1.5,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              date,
              style: TextStyle(color: wb.textMuted, fontSize: 13, height: 1.2),
            ),
          ],
        ),
      ),
    );
  }
}
