import 'package:easyterm/widgets/editor_find_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeEditorFindHits', () {
    test('plain case-insensitive', () {
      final hits = computeEditorFindHits('Hello hello HELLO', 'hello');
      expect(hits.length, 3);
      expect(hits[0].start, 0);
      expect(hits[1].start, 6);
    });

    test('case sensitive', () {
      final hits = computeEditorFindHits(
        'Hello hello',
        'Hello',
        caseSensitive: true,
      );
      expect(hits.length, 1);
      expect(hits[0].start, 0);
    });

    test('whole word', () {
      final hits = computeEditorFindHits(
        'cat catastrophe cat',
        'cat',
        wholeWord: true,
      );
      expect(hits.length, 2);
      expect(hits[0].start, 0);
      expect(hits[1].start, 16);
    });

    test('regex', () {
      final hits = computeEditorFindHits(
        'a1 b2 c3',
        r'[a-c]\d',
        regex: true,
      );
      expect(hits.length, 3);
    });

    test('invalid regex throws', () {
      expect(
        () => computeEditorFindHits('abc', '[', regex: true),
        throwsFormatException,
      );
    });

    test('empty query', () {
      expect(computeEditorFindHits('abc', ''), isEmpty);
    });

    test('cross-line', () {
      final hits = computeEditorFindHits('foo\nbar\nfoo', 'foo');
      expect(hits.length, 2);
    });
  });

  group('EditorFindReplaceController', () {
    test('findNext cycles', () {
      final tec = TextEditingController(text: 'aa aa aa');
      final c = EditorFindReplaceController();
      c.getText = () => tec.text;
      c.onApplySelection = (_) {};
      c.findCtrl.text = 'aa';
      c.rebuildHits();
      expect(c.hits.length, 3);
      expect(c.index, 0);
      c.findNext();
      expect(c.index, 1);
      c.findNext();
      expect(c.index, 2);
      c.findNext();
      expect(c.index, 0);
      c.findNext(reverse: true);
      expect(c.index, 2);
      c.dispose();
      tec.dispose();
    });

    test('replaceOne and replaceAll', () {
      final tec = TextEditingController(text: 'one two one');
      final c = EditorFindReplaceController();
      c.getText = () => tec.text;
      c.onReplace = (hit, rep) {
        editorReplaceHit(tec, hit, rep);
      };
      c.onApplySelection = (_) {};
      c.findCtrl.text = 'one';
      c.replaceCtrl.text = 'X';
      c.rebuildHits();
      expect(c.hits.length, 2);
      c.replaceOne();
      expect(tec.text, 'X two one');
      c.replaceAll();
      expect(tec.text, 'X two X');
      expect(c.hits, isEmpty);
      c.dispose();
      tec.dispose();
    });

    test('regexInvalid flag', () {
      final tec = TextEditingController(text: 'abc');
      final c = EditorFindReplaceController();
      c.getText = () => tec.text;
      c.findCtrl.text = '[';
      c.regex = true;
      c.rebuildHits();
      expect(c.regexInvalid, isTrue);
      expect(c.hits, isEmpty);
      c.dispose();
      tec.dispose();
    });
  });

  group('editorLineStartOffset', () {
    test('basic', () {
      const text = 'a\nbb\nccc';
      expect(editorLineStartOffset(text, 1), 0);
      expect(editorLineStartOffset(text, 2), 2);
      expect(editorLineStartOffset(text, 3), 5);
      expect(editorLineStartOffset(text, 99), text.length);
    });
  });
}
