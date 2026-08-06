import 'package:easyterm/util/editor_highlight.dart';
import 'package:easyterm/util/editor_syntax.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const base = TextStyle(color: Color(0xFFFFFFFF), fontSize: 13);
  const theme = EditorHighlightTheme.dark;

  List<String> kindsOf(String source, EditorLanguage language) {
    final span = buildHighlightedSpan(
      source,
      language: language,
      baseStyle: base,
      theme: theme,
    );
    final out = <String>[];
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        if (s.text != null && s.text!.isNotEmpty) {
          final c = s.style?.color;
          String kind = 'plain';
          if (c == theme.comment) {
            kind = 'comment';
          } else if (c == theme.string) {
            kind = 'string';
          } else if (c == theme.number) {
            kind = 'number';
          } else if (c == theme.keyword) {
            kind = 'keyword';
          } else if (c == theme.key) {
            kind = 'key';
          } else if (c == theme.punctuation) {
            kind = 'punctuation';
          } else if (c == theme.boolean) {
            kind = 'boolean';
          } else if (c == theme.variable) {
            kind = 'variable';
          }
          out.add('$kind:${s.text}');
        }
        final children = s.children;
        if (children != null) {
          for (final child in children) {
            walk(child);
          }
        }
      }
    }

    walk(span);
    return out;
  }

  group('json highlight', () {
    test('colors keys strings numbers booleans', () {
      final kinds = kindsOf(
        '{"a": 1, "b": true, "c": "hi"}',
        EditorLanguage.json,
      );
      expect(kinds.any((k) => k.startsWith('key:')), isTrue);
      expect(kinds.any((k) => k.startsWith('string:') && k.contains('hi')), isTrue);
      expect(kinds.any((k) => k.startsWith('number:')), isTrue);
      expect(kinds.any((k) => k.startsWith('boolean:')), isTrue);
      expect(kinds.any((k) => k.startsWith('punctuation:')), isTrue);
    });
  });

  group('yaml highlight', () {
    test('colors keys comments and list dashes', () {
      final kinds = kindsOf(
        '# hi\nname: alice\n- item\n',
        EditorLanguage.yaml,
      );
      expect(kinds.any((k) => k.startsWith('comment:')), isTrue);
      expect(kinds.any((k) => k.startsWith('key:') && k.contains('name')), isTrue);
      expect(kinds.any((k) => k == 'punctuation:-'), isTrue);
    });
  });

  group('javascript highlight', () {
    test('colors keywords comments and strings', () {
      final kinds = kindsOf(
        "// c\nconst x = 'hi';\nfunction f() { return 1; }\n",
        EditorLanguage.javascript,
      );
      expect(kinds.any((k) => k.startsWith('comment:')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('const')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('function')), isTrue);
      expect(kinds.any((k) => k.startsWith('string:')), isTrue);
      expect(kinds.any((k) => k.startsWith('number:')), isTrue);
    });
  });

  group('bash highlight', () {
    test('colors keywords comments and variables', () {
      final kinds = kindsOf(
        '# setup\nif true; then echo \$HOME; fi\n',
        EditorLanguage.bash,
      );
      expect(kinds.any((k) => k.startsWith('comment:')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('if')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('fi')), isTrue);
      expect(kinds.any((k) => k.startsWith('variable:')), isTrue);
    });
  });

  test('plain language stays uncolored beyond base', () {
    final span = buildHighlightedSpan(
      'hello',
      language: EditorLanguage.plain,
      baseStyle: base,
      theme: theme,
    );
    expect(span.children, isNotNull);
    final child = span.children!.single as TextSpan;
    expect(child.style?.color, base.color);
    expect(child.style?.color, isNot(theme.keyword));
  });
}
