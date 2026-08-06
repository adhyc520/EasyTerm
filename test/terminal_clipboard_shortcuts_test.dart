import 'package:easyterm/services/workbench_desktop_shortcuts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('terminal clipboard shortcuts', () {
    test('macOS uses meta chords', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      expect(workbenchUsesMetaPrimaryModifier(), isTrue);
      final shortcuts = workbenchTerminalClipboardShortcuts();
      expect(
        shortcuts.keys,
        containsAll([
          const SingleActivator(LogicalKeyboardKey.keyC, meta: true),
          const SingleActivator(LogicalKeyboardKey.keyV, meta: true),
        ]),
      );
      expect(
        shortcuts.keys,
        isNot(
          contains(const SingleActivator(LogicalKeyboardKey.keyV, control: true)),
        ),
      );
    });

    test('Windows uses control chords and shift+C for copy', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      expect(workbenchUsesMetaPrimaryModifier(), isFalse);
      final shortcuts = workbenchTerminalClipboardShortcuts();
      expect(
        shortcuts.keys,
        containsAll([
          const SingleActivator(
            LogicalKeyboardKey.keyC,
            control: true,
            shift: true,
          ),
          const SingleActivator(LogicalKeyboardKey.keyV, control: true),
        ]),
      );
      expect(
        shortcuts.keys,
        isNot(
          contains(const SingleActivator(LogicalKeyboardKey.keyC, control: true)),
        ),
      );
    });
  });
}
