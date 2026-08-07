import 'package:easyterm/util/editor_syntax.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('editorLanguageFromPath', () {
    test('maps common extensions', () {
      expect(editorLanguageFromPath('/a/b.json'), EditorLanguage.json);
      expect(editorLanguageFromPath('c.yaml'), EditorLanguage.yaml);
      expect(editorLanguageFromPath(r'D:\x\y.yml'), EditorLanguage.yaml);
      expect(editorLanguageFromPath('app.js'), EditorLanguage.javascript);
      expect(editorLanguageFromPath('mod.mjs'), EditorLanguage.javascript);
      expect(editorLanguageFromPath('app.ts'), EditorLanguage.javascript);
      expect(editorLanguageFromPath('App.tsx'), EditorLanguage.javascript);
      expect(editorLanguageFromPath('index.html'), EditorLanguage.html);
      expect(editorLanguageFromPath('page.HTM'), EditorLanguage.html);
      expect(editorLanguageFromPath('styles.css'), EditorLanguage.css);
      expect(editorLanguageFromPath('main.py'), EditorLanguage.python);
      expect(editorLanguageFromPath('script.pyw'), EditorLanguage.python);
      expect(editorLanguageFromPath('run.sh'), EditorLanguage.bash);
      expect(editorLanguageFromPath('init.bash'), EditorLanguage.bash);
      expect(editorLanguageFromPath('Dockerfile'), EditorLanguage.dockerfile);
      expect(editorLanguageFromPath('dockerfile'), EditorLanguage.dockerfile);
      expect(editorLanguageFromPath('app.dockerfile'), EditorLanguage.dockerfile);
      expect(editorLanguageFromPath('readme.md'), EditorLanguage.markdown);
      expect(editorLanguageFromPath('NOTES.markdown'), EditorLanguage.markdown);
      expect(editorLanguageFromPath('app.ini'), EditorLanguage.ini);
      expect(editorLanguageFromPath('nginx.conf'), EditorLanguage.ini);
      expect(editorLanguageFromPath('local.cfg'), EditorLanguage.ini);
      expect(editorLanguageFromPath('pom.xml'), EditorLanguage.xml);
      expect(editorLanguageFromPath('icon.svg'), EditorLanguage.xml);
    });
  });

  group('validateEditorSyntax json', () {
    test('accepts valid json', () {
      expect(validateEditorSyntax(EditorLanguage.json, '{"a":1}'), isNull);
    });

    test('rejects invalid json with line', () {
      final issue = validateEditorSyntax(EditorLanguage.json, '{\n  a: 1\n}');
      expect(issue, isNotNull);
      expect(issue!.message, contains('JSON'));
      expect(issue.line, isNotNull);
    });
  });

  group('validateEditorSyntax yaml', () {
    test('accepts valid yaml', () {
      expect(
        validateEditorSyntax(EditorLanguage.yaml, 'a:\n  b: 1\n'),
        isNull,
      );
    });

    test('rejects invalid yaml', () {
      final issue = validateEditorSyntax(
        EditorLanguage.yaml,
        'a: [1, 2\nb: 3',
      );
      expect(issue, isNotNull);
      expect(issue!.message, contains('YAML'));
    });
  });

  group('validateEditorSyntax javascript', () {
    test('accepts balanced script', () {
      expect(
        validateEditorSyntax(
          EditorLanguage.javascript,
          'function f(x) { return x + 1; }\n',
        ),
        isNull,
      );
    });

    test('rejects unclosed brace', () {
      final issue = validateEditorSyntax(
        EditorLanguage.javascript,
        'function f() {\n  return 1;\n',
      );
      expect(issue, isNotNull);
      expect(issue!.line, 1);
    });

    test('rejects unclosed string', () {
      final issue = validateEditorSyntax(
        EditorLanguage.javascript,
        "const s = 'hello;\n",
      );
      expect(issue, isNotNull);
      expect(issue!.message, contains('字符串'));
    });

    test('ignores braces inside strings', () {
      expect(
        validateEditorSyntax(
          EditorLanguage.javascript,
          "const s = '{';\n",
        ),
        isNull,
      );
    });
  });

  group('validateEditorSyntax html', () {
    test('accepts nested tags', () {
      expect(
        validateEditorSyntax(
          EditorLanguage.html,
          '<div><span>ok</span></div>',
        ),
        isNull,
      );
    });

    test('accepts void tags', () {
      expect(
        validateEditorSyntax(EditorLanguage.html, '<br><img src="a"/>'),
        isNull,
      );
    });

    test('rejects mismatched tags', () {
      final issue = validateEditorSyntax(
        EditorLanguage.html,
        '<div><span></div>',
      );
      expect(issue, isNotNull);
      expect(issue!.message, contains('不匹配'));
    });

    test('rejects unclosed tags', () {
      final issue = validateEditorSyntax(EditorLanguage.html, '<div><p>x');
      expect(issue, isNotNull);
      expect(issue!.message, contains('未闭合'));
    });
  });

  group('validateEditorSyntax bash', () {
    test('accepts if/fi', () {
      expect(
        validateEditorSyntax(
          EditorLanguage.bash,
          'if true; then\n  echo hi\nfi\n',
        ),
        isNull,
      );
    });

    test('rejects missing fi', () {
      final issue = validateEditorSyntax(
        EditorLanguage.bash,
        'if true; then\n  echo hi\n',
      );
      expect(issue, isNotNull);
      expect(issue!.message, contains('fi'));
    });

    test('rejects unclosed quote', () {
      final issue = validateEditorSyntax(
        EditorLanguage.bash,
        "echo 'hello\n",
      );
      expect(issue, isNotNull);
    });

    test('accepts for/do/done', () {
      expect(
        validateEditorSyntax(
          EditorLanguage.bash,
          'for i in 1 2; do echo \$i; done\n',
        ),
        isNull,
      );
    });
  });
}
