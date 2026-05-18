import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// Whether this build targets a desktop OS that uses workbench window chrome.
bool workbenchDesktopShortcutsEnabled() =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// macOS ⌘ / Windows·Linux Ctrl pairs for the same letter key.
Iterable<SingleActivator> workbenchMetaOrControl(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
}) sync* {
  yield SingleActivator(key, meta: true, shift: shift, alt: alt);
  yield SingleActivator(key, control: true, shift: shift, alt: alt);
}

/// Merge [activators] into a [CallbackShortcuts] bindings map.
Map<ShortcutActivator, VoidCallback> workbenchBindActivators(
  Iterable<SingleActivator> activators,
  VoidCallback onInvoke,
) {
  return {for (final a in activators) a: onInvoke};
}

Future<void> workbenchQuitApplication() async {
  if (!workbenchDesktopShortcutsEnabled()) return;
  await windowManager.destroy();
}

Future<void> workbenchCloseWindow() async {
  if (!workbenchDesktopShortcutsEnabled()) return;
  await windowManager.close();
}

Future<void> workbenchMinimizeWindow() async {
  if (!workbenchDesktopShortcutsEnabled()) return;
  await windowManager.minimize();
}

// --- App-wide intents (registered on [MaterialApp.builder]) ---

class WorkbenchQuitIntent extends Intent {
  const WorkbenchQuitIntent();
}

class WorkbenchMinimizeIntent extends Intent {
  const WorkbenchMinimizeIntent();
}

Map<ShortcutActivator, Intent> workbenchGlobalShortcutIntents() {
  if (!workbenchDesktopShortcutsEnabled()) return const {};
  return {
    ...workbenchBindIntents(workbenchMetaOrControl(LogicalKeyboardKey.keyQ), const WorkbenchQuitIntent()),
    const SingleActivator(LogicalKeyboardKey.f4, alt: true): const WorkbenchQuitIntent(),
    ...workbenchBindIntents(workbenchMetaOrControl(LogicalKeyboardKey.keyM), const WorkbenchMinimizeIntent()),
  };
}

Map<ShortcutActivator, Intent> workbenchBindIntents(
  Iterable<SingleActivator> activators,
  Intent intent,
) {
  return {for (final a in activators) a: intent};
}

Map<Type, Action<Intent>> workbenchGlobalShortcutActions() {
  return {
    WorkbenchQuitIntent: CallbackAction<WorkbenchQuitIntent>(
      onInvoke: (_) {
        unawaited(workbenchQuitApplication());
        return null;
      },
    ),
    WorkbenchMinimizeIntent: CallbackAction<WorkbenchMinimizeIntent>(
      onInvoke: (_) {
        unawaited(workbenchMinimizeWindow());
        return null;
      },
    ),
  };
}
