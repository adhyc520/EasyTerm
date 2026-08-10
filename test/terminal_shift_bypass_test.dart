import 'package:easyterm/services/pty_interceptor.dart';
import 'package:easyterm/util/editor_highlight.dart';
import 'package:easyterm/util/editor_syntax.dart';
import 'package:easyterm/widgets/editor_find_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mouse mode gating (shift bypass prerequisite)', () {
    test('mouse mode from interceptor', () {
      final modes = <bool>[];
      final p = PtyInterceptor(onMouseMode: modes.add);
      expect(p.mouseMode, isFalse);
      p.process('\x1b[?1003h');
      expect(p.mouseMode, isTrue);
      // Shift bypass is only required while mouseMode is true.
      expect(modes, [true]);
      p.process('\x1b[?1003l');
      expect(p.mouseMode, isFalse);
    });

    test('reset clears mouse mode', () {
      final p = PtyInterceptor();
      p.process('\x1b[?1000h');
      expect(p.mouseMode, isTrue);
      p.reset();
      expect(p.mouseMode, isFalse);
    });
  });

  group('find hit highlight', () {
    testWidgets('setFindHits paints background on matches', (tester) async {
      final ctrl = SyntaxEditingController(
        text: 'hello hello',
        language: EditorLanguage.javascript,
      );
      ctrl.setFindHits(
        const [TextRange(start: 0, end: 5), TextRange(start: 6, end: 11)],
        currentIndex: 0,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: TextField(controller: ctrl),
          ),
        ),
      );
      await tester.pump();

      final span = ctrl.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        style: const TextStyle(color: Colors.white),
        withComposing: false,
      );

      var sawCurrent = false;
      var sawOther = false;
      void walk(InlineSpan s) {
        if (s is TextSpan) {
          final bg = s.style?.backgroundColor;
          if (bg != null) {
            if (bg.a > 0.6) sawCurrent = true;
            if (bg.a > 0.2 && bg.a <= 0.6) sawOther = true;
          }
          s.children?.forEach(walk);
        }
      }
      walk(span);
      expect(sawCurrent || sawOther, isTrue,
          reason: 'expected find-hit background on span tree');
      ctrl.dispose();
    });
  });

  group('replaceAll single text set', () {
    test('onSetText used for bulk replace', () {
      final tec = TextEditingController(text: 'a a a');
      var setCount = 0;
      final c = EditorFindReplaceController();
      c.getText = () => tec.text;
      c.onSetText = (text, sel) {
        setCount++;
        tec.value = TextEditingValue(text: text, selection: sel);
      };
      c.onReplace = (hit, rep) {
        fail('should not call onReplace when onSetText is set');
      };
      c.findCtrl.text = 'a';
      c.replaceCtrl.text = 'b';
      c.replaceAll();
      expect(tec.text, 'b b b');
      expect(setCount, 1);
      c.dispose();
      tec.dispose();
    });
  });
}
