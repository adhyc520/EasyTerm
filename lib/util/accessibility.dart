import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// 无障碍辅助：统一 Semantics 包装与状态播报。
Widget a11yButton({
  required String label,
  String? hint,
  required Widget child,
}) {
  return Semantics(
    label: label,
    hint: hint,
    button: true,
    child: child,
  );
}

Widget a11yTerminal({
  required String hostLabel,
  required bool connected,
  required Widget child,
}) {
  return Semantics(
    label: 'SSH Terminal - $hostLabel',
    value: connected ? 'Connected' : 'Disconnected',
    container: true,
    child: child,
  );
}

Widget a11yStatus({
  required String label,
  required String value,
  required Widget child,
}) {
  return Semantics(
    label: label,
    value: value,
    container: true,
    child: child,
  );
}

void a11yAnnounce(String message) {
  // ignore: deprecated_member_use
  SemanticsService.announce(message, TextDirection.ltr);
}
