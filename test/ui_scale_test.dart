import 'package:easyterm/services/workbench_settings_store.dart';
import 'package:easyterm/theme/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkbenchSettingsStore defaults', () {
    test('uiScale clamp via load defaults', () {
      expect(WorkbenchSettingsStore.defaultUiScaleForDpr(1.0), 1.0);
      expect(WorkbenchSettingsStore.defaultUiScaleForDpr(1.5), 1.0);
      expect(WorkbenchSettingsStore.defaultUiScaleForDpr(2.0), 1.1);
    });

    test('font size defaults', () {
      expect(WorkbenchSettingsStore.defaultFontSizeForDpr(1.0), 14);
      expect(WorkbenchSettingsStore.defaultFontSizeForDpr(2.0), 16);
    });

    test('fontFamilyChoices non-empty', () {
      expect(WorkbenchSettingsStore.fontFamilyChoices, isNotEmpty);
      expect(
        WorkbenchSettingsStore.fontFamilyChoices,
        contains(WorkbenchSettingsStore.platformDefaultFontFamily),
      );
    });

    test('setUiScaleFactor clamps and notifies', () {
      final s = WorkbenchSettingsStore();
      var n = 0;
      s.addListener(() => n++);
      s.setUiScaleFactor(3.0);
      expect(s.uiScaleFactor, 2.0);
      expect(n, 1);
      s.setUiScaleFactor(0.5);
      expect(s.uiScaleFactor, 0.75);
      s.dispose();
    });
  });

  group('wbScale metrics', () {
    testWidgets('wbScaled multiplies by textScaler', (tester) async {
      late double scaled;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Builder(
            builder: (context) {
              scaled = context.wbScaled(20);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(scaled, 30);
    });

    testWidgets('MaterialApp builder textScaler reaches subtree', (
      tester,
    ) async {
      TextScaler? seen;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.25),
              ),
              child: child!,
            );
          },
          home: Builder(
            builder: (context) {
              seen = MediaQuery.textScalerOf(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen!.scale(1.0), 1.25);
    });

    testWidgets('uiScale multiplies system textScaler', (tester) async {
      TextScaler? seen;
      const uiScale = 1.25;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: Builder(
            builder: (outer) {
              final systemScale = MediaQuery.of(outer).textScaler.scale(1.0);
              return MediaQuery(
                data: MediaQuery.of(outer).copyWith(
                  textScaler: TextScaler.linear(systemScale * uiScale),
                ),
                child: Builder(
                  builder: (inner) {
                    seen = MediaQuery.textScalerOf(inner);
                    return const SizedBox();
                  },
                ),
              );
            },
          ),
        ),
      );
      expect(seen!.scale(1.0), 2.5);
    });
  });
}
