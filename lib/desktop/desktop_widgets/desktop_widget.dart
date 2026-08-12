import 'package:flutter/material.dart';

/// 桌面小部件配置。
class DesktopWidgetConfig {
  DesktopWidgetConfig({
    required this.position,
    required this.size,
    this.visible = true,
  });

  Offset position;
  Size size;
  bool visible;

  Map<String, Object?> toJson() => {
        'x': position.dx,
        'y': position.dy,
        'w': size.width,
        'h': size.height,
        'visible': visible,
      };

  factory DesktopWidgetConfig.fromJson(Map<String, Object?> j) {
    return DesktopWidgetConfig(
      position: Offset(
        (j['x'] as num?)?.toDouble() ?? 24,
        (j['y'] as num?)?.toDouble() ?? 24,
      ),
      size: Size(
        (j['w'] as num?)?.toDouble() ?? 180,
        (j['h'] as num?)?.toDouble() ?? 120,
      ),
      visible: j['visible'] as bool? ?? true,
    );
  }
}

/// 桌面小部件抽象。
abstract class DesktopWidgetKind {
  String get id;
  String get name;
  IconData get icon;
  DesktopWidgetConfig defaultConfig();
  Widget build(BuildContext context, DesktopWidgetConfig config);
}
