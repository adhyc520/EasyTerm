import 'package:easyterm/l10n/app_localizations.dart';
import 'package:easyterm/screens/remote_editor_screen.dart';
import 'package:easyterm/services/ssh_workspace_controller.dart';
import 'package:easyterm/services/workbench_settings_store.dart';
import 'package:easyterm/widgets/editor_find_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

SshWorkspaceController _fakeController() {
  return SshWorkspaceController(
    settings: WorkbenchSettingsStore(),
    host: 'test.local',
    port: 22,
    username: 'test',
    password: '',
  );
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  String text = 'line1\nline2\nhello\nhello\nend',
  String fileName = 'notes.txt',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: RemoteEditorScreen(
        controller: _fakeController(),
        fileName: fileName,
        initialText: text,
        initialRemoteMtime: 1,
      ),
    ),
  );
  await tester.pump();
}

TextEditingController _mainEditorController(WidgetTester tester) {
  final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
  // Last TextField is the editor body (find bar fields appear above when open).
  return fields.last.controller!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemoteEditorScreen', () {
    testWidgets('gutter line count matches text', (tester) async {
      await _pumpEditor(tester, text: 'a\nb\nc');
      expect(find.text('1\n2\n3'), findsOneWidget);
    });

    testWidgets('gutter updates when lines are added', (tester) async {
      await _pumpEditor(tester, text: 'only');
      expect(find.text('1'), findsOneWidget);

      final ctrl = _mainEditorController(tester);
      ctrl.text = 'only\ntwo\nthree';
      await tester.pump();
      expect(find.text('1\n2\n3'), findsOneWidget);
    });

    testWidgets('open find bar and cycle hits', (tester) async {
      await _pumpEditor(tester);

      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pump();
      expect(find.byType(EditorFindBar), findsOneWidget);

      final bar = tester.widget<EditorFindBar>(find.byType(EditorFindBar));
      final findFields = find.descendant(
        of: find.byType(EditorFindBar),
        matching: find.byType(TextField),
      );
      await tester.enterText(findFields.first, 'hello');
      await tester.pump();

      expect(bar.controller.hits.length, 2);
      expect(bar.controller.index, 0);
      expect(find.textContaining('1/2'), findsOneWidget);

      bar.controller.findNext();
      await tester.pump();
      expect(bar.controller.index, 1);
      expect(find.textContaining('2/2'), findsOneWidget);

      bar.controller.findNext();
      await tester.pump();
      expect(bar.controller.index, 0);
      expect(find.textContaining('1/2'), findsOneWidget);
    });

    testWidgets('replace one updates text', (tester) async {
      await _pumpEditor(tester, text: 'foo bar foo');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(find.byType(EditorFindBar), findsOneWidget);

      final fields = find.descendant(
        of: find.byType(EditorFindBar),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), 'foo');
      await tester.enterText(fields.at(1), 'X');
      await tester.pump();

      await tester.tap(find.text('替换'));
      await tester.pump();

      expect(_mainEditorController(tester).text, 'X bar foo');
    });

    testWidgets('goto line moves caret', (tester) async {
      await _pumpEditor(tester, text: 'a\nbb\nccc');

      await tester.tap(find.byIcon(Icons.unfold_more_rounded));
      await tester.pump();

      expect(find.text('跳转到行'), findsOneWidget);
      final dialogField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(dialogField, '3');
      await tester.tap(find.text('跳转'));
      await tester.pump();

      expect(_mainEditorController(tester).selection.baseOffset, 5);
    });

    testWidgets('Ctrl+F opens find via shortcut', (tester) async {
      await _pumpEditor(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(find.byType(EditorFindBar), findsOneWidget);
    });
  });
}
