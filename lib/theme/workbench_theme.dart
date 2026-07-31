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
    bg: Color(0xFF111113),
    topBar: Color(0xFF1B1B1F),
    panel: Color(0xFF16171A),
    panelElevated: Color(0xFF202126),
    border: Color(0xFF303139),
    accentBlue: Color(0xFF0A84FF),
    folder: Color(0xFFD4A72E),
    terminalBg: Color(0xFF090A0C),
    textMuted: Color(0xFFA1A1AA),
    online: Color(0xFF32D74B),
    offline: Color(0xFF73737D),
    primaryText: Color(0xFFFFFFFF),
    secondaryText: Color(0xFFE7E7EC),
    topBarDivider: Color(0x14FFFFFF),
  );

  static const WorkbenchColors light = WorkbenchColors(
    bg: Color(0xFFEDEFF2),
    topBar: Color(0xFFF7F8FA),
    panel: Color(0xFFF1F2F5),
    panelElevated: Color(0xFFFFFFFF),
    border: Color(0xFFD4D7DE),
    accentBlue: Color(0xFF006FE6),
    folder: Color(0xFFB45309),
    terminalBg: Color(0xFF0D0D0F),
    textMuted: Color(0xFF626B7A),
    online: Color(0xFF1F9D4C),
    offline: Color(0xFF9AA1AD),
    primaryText: Color(0xFF15171C),
    secondaryText: Color(0xFF3C4452),
    topBarDivider: Color(0x1A000000),
  );
}

extension WorkbenchColorsContext on BuildContext {
  WorkbenchColors get wb => Theme.of(this).brightness == Brightness.light
      ? WorkbenchColors.light
      : WorkbenchColors.dark;
}

/// 与 [WorkbenchColors] 配套的 Material 3 主题（浅色 / 深色各一套）。
ThemeData buildWorkbenchMaterialTheme(
  WorkbenchColors c,
  Brightness brightness,
) {
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
    splashFactory: InkSparkle.splashFactory,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    hoverColor: c.primaryText.withValues(alpha: 0.06),
    highlightColor: c.primaryText.withValues(alpha: 0.05),
    splashColor: c.accentBlue.withValues(alpha: 0.12),
    dividerTheme: DividerThemeData(color: c.border),
    appBarTheme: AppBarTheme(
      backgroundColor: c.panelElevated,
      foregroundColor: c.primaryText,
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.panelElevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.panelElevated,
      contentTextStyle: TextStyle(color: c.primaryText),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.panelElevated,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: c.accentBlue, width: 1.5),
      ),
      labelStyle: TextStyle(color: c.textMuted),
      hintStyle: TextStyle(color: c.textMuted.withValues(alpha: 0.75)),
    ),
    cardTheme: CardThemeData(
      color: c.panelElevated,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: c.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        fixedSize: const Size.square(34),
        minimumSize: const Size.square(34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.panelElevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: c.border),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.textMuted,
      textColor: c.primaryText,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );
}
