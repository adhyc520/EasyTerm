import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'l10n/app_localizations.dart';
import 'screens/main_shell_screen.dart';
import 'services/performance_monitor.dart';
import 'services/workbench_desktop_shortcuts.dart';
import 'services/workbench_settings_store.dart';
import 'theme/workbench_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 开发模式可打开帧耗时采样（设置里也可扩展开关）。
  assert(() {
    PerformanceMonitor.instance.setEnabled(true);
    return true;
  }());

  final bool isDesktop =
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'EasyTerm',
        size: Size(1280, 800),
        center: true,
        minimumSize: Size(900, 560),
        backgroundColor: Colors.transparent,
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(const EasyTermApp());
}

class EasyTermApp extends StatefulWidget {
  const EasyTermApp({super.key});

  @override
  State<EasyTermApp> createState() => _EasyTermAppState();
}

class _EasyTermAppState extends State<EasyTermApp> {
  final WorkbenchSettingsStore _settings = WorkbenchSettingsStore();

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    unawaited(
      _settings.load().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  void _onSettingsChanged() => setState(() {});

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lightTheme = buildWorkbenchMaterialTheme(
      WorkbenchColors.light,
      Brightness.light,
    );
    final darkTheme = buildWorkbenchMaterialTheme(
      WorkbenchColors.dark,
      Brightness.dark,
    );

    return MaterialApp(
      onGenerateTitle: (ctx) =>
          AppLocalizations.of(ctx)?.appTitle ??
          lookupAppLocalizations(Locale(_settings.appLocaleCode)).appTitle,
      debugShowCheckedModeBanner: false,
      locale: Locale(_settings.appLocaleCode),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: _settings.materialThemeMode,
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        final scale = _settings.uiScaleFactor;
        Widget wrapped = child;
        if (scale != 1.0) {
          final mq = MediaQuery.of(context);
          final systemScale = mq.textScaler.scale(1.0);
          wrapped = MediaQuery(
            data: mq.copyWith(
              textScaler: TextScaler.linear(systemScale * scale),
            ),
            child: child,
          );
        }
        if (!workbenchDesktopShortcutsEnabled()) return wrapped;
        return Shortcuts(
          shortcuts: workbenchGlobalShortcutIntents(),
          child: Actions(
            actions: workbenchGlobalShortcutActions(),
            child: wrapped,
          ),
        );
      },
      home: MainShellScreen(settings: _settings),
    );
  }
}
