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

  group('html highlight', () {
    test('colors tags attributes strings comments', () {
      final kinds = kindsOf(
        '<!-- c --><div class="x">hi</div>\n',
        EditorLanguage.html,
      );
      expect(kinds.any((k) => k.startsWith('comment:')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('div')), isTrue);
      expect(kinds.any((k) => k.startsWith('key:') && k.contains('class')), isTrue);
      expect(kinds.any((k) => k.startsWith('string:') && k.contains('x')), isTrue);
    });
  });

  group('css highlight', () {
    test('colors selectors properties comments', () {
      final kinds = kindsOf(
        '/* c */\n.foo { color: red; }\n',
        EditorLanguage.css,
      );
      expect(kinds.any((k) => k.startsWith('comment:')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('foo')), isTrue);
      expect(kinds.any((k) => k.startsWith('key:') && k.contains('color')), isTrue);
    });
  });

  group('python highlight', () {
    test('colors keywords strings comments', () {
      final kinds = kindsOf(
        "# c\ndef f():\n  return 'hi'\n",
        EditorLanguage.python,
      );
      expect(kinds.any((k) => k.startsWith('comment:')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('def')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('return')), isTrue);
      expect(kinds.any((k) => k.startsWith('string:')), isTrue);
    });
  });

  group('dockerfile highlight', () {
    test('colors instructions and comments', () {
      final kinds = kindsOf(
        '# base\nFROM alpine\nRUN echo hi\nCMD ["sh"]\n',
        EditorLanguage.dockerfile,
      );
      expect(kinds.any((k) => k.startsWith('comment:')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('FROM')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('RUN')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('CMD')), isTrue);
    });
  });

  group('markdown highlight', () {
    test('colors headings fences and bold', () {
      final kinds = kindsOf(
        '# Title\n**bold**\n```\ncode\n```\n',
        EditorLanguage.markdown,
      );
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('Title')), isTrue);
      expect(kinds.any((k) => k.startsWith('key:') && k.contains('bold')), isTrue);
      expect(kinds.any((k) => k.startsWith('string:') && k.contains('code')), isTrue);
    });
  });

  group('ini highlight', () {
    test('colors sections keys values comments', () {
      final kinds = kindsOf(
        '; c\n[main]\nname=alice\n',
        EditorLanguage.ini,
      );
      expect(kinds.any((k) => k.startsWith('comment:')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('main')), isTrue);
      expect(kinds.any((k) => k.startsWith('key:') && k.contains('name')), isTrue);
      expect(kinds.any((k) => k.startsWith('string:') && k.contains('alice')), isTrue);
    });
  });

  group('xml highlight', () {
    test('reuses html tag coloring', () {
      final kinds = kindsOf(
        '<!-- c --><root attr="x"/>\n',
        EditorLanguage.xml,
      );
      expect(kinds.any((k) => k.startsWith('comment:')), isTrue);
      expect(kinds.any((k) => k.startsWith('keyword:') && k.contains('root')), isTrue);
      expect(kinds.any((k) => k.startsWith('key:') && k.contains('attr')), isTrue);
      expect(kinds.any((k) => k.startsWith('string:') && k.contains('x')), isTrue);
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
