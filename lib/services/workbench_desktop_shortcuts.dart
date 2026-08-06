import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
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

/// Whether the host OS uses ⌘ (meta) as the primary chord modifier.
bool workbenchUsesMetaPrimaryModifier() =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Platform-native clipboard shortcuts for the terminal (local OS clipboard).
///
/// - macOS / iOS: ⌘C / ⌘V / ⌘A
/// - Windows / Linux: Ctrl+Shift+C / Ctrl+V / Ctrl+A
///
/// Windows/Linux Ctrl+C is intentionally omitted so an empty selection still
/// sends SIGINT; [TerminalSurface] copies on Ctrl+C only when text is selected.
Map<ShortcutActivator, Intent> workbenchTerminalClipboardShortcuts() {
  if (workbenchUsesMetaPrimaryModifier()) {
    return {
      const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
          CopySelectionTextIntent.copy,
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
          const PasteTextIntent(SelectionChangedCause.keyboard),
      const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
          const SelectAllTextIntent(SelectionChangedCause.keyboard),
    };
  }
  return {
    const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
        CopySelectionTextIntent.copy,
    const SingleActivator(LogicalKeyboardKey.keyV, control: true):
        const PasteTextIntent(SelectionChangedCause.keyboard),
    const SingleActivator(LogicalKeyboardKey.keyA, control: true):
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
  };
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
    ...workbenchBindIntents(
      workbenchMetaOrControl(LogicalKeyboardKey.keyQ),
      const WorkbenchQuitIntent(),
    ),
    const SingleActivator(LogicalKeyboardKey.f4, alt: true):
        const WorkbenchQuitIntent(),
    ...workbenchBindIntents(
      workbenchMetaOrControl(LogicalKeyboardKey.keyM),
      const WorkbenchMinimizeIntent(),
    ),
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
