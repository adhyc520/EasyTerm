import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'screens/main_shell_screen.dart';
import 'theme/workbench_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final bool isDesktop = !kIsWeb &&
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1280, 800),
        center: true,
        minimumSize: Size(900, 560),
        backgroundColor: Colors.transparent,
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: true,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(const SshWorkbenchApp());
}

class SshWorkbenchApp extends StatelessWidget {
  const SshWorkbenchApp({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: WorkbenchPalette.bg,
      colorScheme: ColorScheme.dark(
        surface: WorkbenchPalette.panel,
        primary: WorkbenchPalette.accentBlue,
        onPrimary: Colors.white,
        onSurface: Colors.white,
        outline: WorkbenchPalette.border,
      ),
      dividerTheme: const DividerThemeData(color: WorkbenchPalette.border),
      appBarTheme: const AppBarTheme(
        backgroundColor: WorkbenchPalette.panelElevated,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: WorkbenchPalette.panelElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: WorkbenchPalette.panelElevated,
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: WorkbenchPalette.panelElevated,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: WorkbenchPalette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: WorkbenchPalette.accentBlue, width: 1.5),
        ),
        labelStyle: const TextStyle(color: WorkbenchPalette.textMuted),
        hintStyle: TextStyle(color: WorkbenchPalette.textMuted.withValues(alpha: 0.7)),
      ),
      cardTheme: CardThemeData(
        color: WorkbenchPalette.panelElevated,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: WorkbenchPalette.border),
        ),
      ),
    );

    return MaterialApp(
      title: 'SSH Workbench',
      debugShowCheckedModeBanner: false,
      theme: dark,
      darkTheme: dark,
      themeMode: ThemeMode.dark,
      home: const MainShellScreen(),
    );
  }
}
