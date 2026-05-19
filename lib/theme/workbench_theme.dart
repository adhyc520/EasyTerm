import 'package:flutter/material.dart';

/// 工作台 UI 色值（随浅色 / 深色切换）。
@immutable
final class WorkbenchColors {
  const WorkbenchColors({
    required this.bg,
    required this.topBar,
    required this.panel,
    required this.panelElevated,
    required this.border,
    required this.accentBlue,
    required this.folder,
    required this.terminalBg,
    required this.textMuted,
    required this.online,
    required this.offline,
    required this.primaryText,
    required this.secondaryText,
    required this.topBarDivider,
  });

  final Color bg;
  final Color topBar;
  final Color panel;
  final Color panelElevated;
  final Color border;
  final Color accentBlue;
  final Color folder;
  final Color terminalBg;
  final Color textMuted;
  final Color online;
  final Color offline;

  /// 侧栏、顶栏主标题等。
  final Color primaryText;

  /// 标签页未选中等。
  final Color secondaryText;

  final Color topBarDivider;

  static const WorkbenchColors dark = WorkbenchColors(
    bg: Color(0xFF0A0A0C),
    topBar: Color(0xFF000000),
    panel: Color(0xFF121215),
    panelElevated: Color(0xFF18181C),
    border: Color(0xFF2A2A32),
    accentBlue: Color(0xFF2563EB),
    folder: Color(0xFFD4A72E),
    terminalBg: Color(0xFF0D0D0F),
    textMuted: Color(0xFF9CA3AF),
    online: Color(0xFF22C55E),
    offline: Color(0xFF6B7280),
    primaryText: Color(0xFFFFFFFF),
    secondaryText: Color(0xFFE5E7EB),
    topBarDivider: Color(0x14FFFFFF),
  );

  static const WorkbenchColors light = WorkbenchColors(
    bg: Color(0xFFF3F4F6),
    topBar: Color(0xFFF9FAFB),
    panel: Color(0xFFE5E7EB),
    panelElevated: Color(0xFFFFFFFF),
    border: Color(0xFFD1D5DB),
    accentBlue: Color(0xFF2563EB),
    folder: Color(0xFFB45309),
    terminalBg: Color(0xFF0D0D0F),
    textMuted: Color(0xFF6B7280),
    online: Color(0xFF16A34A),
    offline: Color(0xFF9CA3AF),
    primaryText: Color(0xFF111827),
    secondaryText: Color(0xFF374151),
    topBarDivider: Color(0x1A000000),
  );
}

extension WorkbenchColorsContext on BuildContext {
  WorkbenchColors get wb =>
      Theme.of(this).brightness == Brightness.light ? WorkbenchColors.light : WorkbenchColors.dark;
}

/// 与 [WorkbenchColors] 配套的 Material 3 主题（浅色 / 深色各一套）。
ThemeData buildWorkbenchMaterialTheme(WorkbenchColors c, Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = isDark
      ? ColorScheme.dark(
          surface: c.panel,
          primary: c.accentBlue,
          onPrimary: Colors.white,
          onSurface: c.primaryText,
          outline: c.border,
        )
      : ColorScheme.light(
          surface: c.panel,
          primary: c.accentBlue,
          onPrimary: Colors.white,
          onSurface: c.primaryText,
          outline: c.border,
        );

  final typography = Typography.material2021();
  final textTheme = isDark
      ? typography.white.apply(
          bodyColor: c.primaryText,
          displayColor: c.primaryText,
        )
      : typography.black.apply(
          bodyColor: c.primaryText,
          displayColor: c.primaryText,
        );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: c.bg,
    colorScheme: scheme,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    dividerTheme: DividerThemeData(color: c.border),
    appBarTheme: AppBarTheme(
      backgroundColor: c.panelElevated,
      foregroundColor: c.primaryText,
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.panelElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.panelElevated,
      contentTextStyle: TextStyle(color: c.primaryText),
      behavior: SnackBarBehavior.floating,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.panelElevated,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: c.accentBlue, width: 1.5),
      ),
      labelStyle: TextStyle(color: c.textMuted),
      hintStyle: TextStyle(color: c.textMuted.withValues(alpha: 0.75)),
    ),
    cardTheme: CardThemeData(
      color: c.panelElevated,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.border),
      ),
    ),
  );
}
