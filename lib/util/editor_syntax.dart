import 'dart:convert';

import 'package:yaml/yaml.dart';

/// Languages the remote editor can syntax-check.
enum EditorLanguage {
  json,
  yaml,
  javascript,
  html,
  bash,
  plain,
}

/// One syntax problem found in editor text.
class EditorSyntaxIssue {
  const EditorSyntaxIssue({
    required this.message,
    this.line,
  });

  final String message;

  /// 1-based line number when known.
  final int? line;

  String get displayMessage {
    if (line == null) return message;
    return '第 $line 行：$message';
  }
}

/// Detect language from a remote file path / name (extension based).
EditorLanguage editorLanguageFromPath(String path) {
  final name = path.replaceAll('\\', '/');
  final base = name.contains('/') ? name.substring(name.lastIndexOf('/') + 1) : name;
  final dot = base.lastIndexOf('.');
  if (dot < 0 || dot == base.length - 1) {
    // Common bash scripts without extension.
    if (base == 'Dockerfile' || base.startsWith('.')) {
      return EditorLanguage.plain;
    }
    return EditorLanguage.plain;
  }
  final ext = base.substring(dot + 1).toLowerCase();
  switch (ext) {
    case 'json':
      return EditorLanguage.json;
    case 'yaml':
    case 'yml':
      return EditorLanguage.yaml;
    case 'js':
    case 'mjs':
    case 'cjs':
      return EditorLanguage.javascript;
    case 'html':
    case 'htm':
      return EditorLanguage.html;
    case 'sh':
    case 'bash':
    case 'zsh':
    case 'ksh':
      return EditorLanguage.bash;
    default:
      return EditorLanguage.plain;
  }
}

String editorLanguageLabel(EditorLanguage language) {
  switch (language) {
    case EditorLanguage.json:
      return 'JSON';
    case EditorLanguage.yaml:
      return 'YAML';
    case EditorLanguage.javascript:
      return 'JavaScript';
    case EditorLanguage.html:
      return 'HTML';
    case EditorLanguage.bash:
      return 'Bash';
    case EditorLanguage.plain:
      return '';
  }
}

/// Validate [text] for [language]. Returns the first issue, or null if OK / unsupported.
EditorSyntaxIssue? validateEditorSyntax(EditorLanguage language, String text) {
  switch (language) {
    case EditorLanguage.json:
      return _validateJson(text);
    case EditorLanguage.yaml:
      return _validateYaml(text);
    case EditorLanguage.javascript:
      return _validateJavascript(text);
    case EditorLanguage.html:
      return _validateHtml(text);
    case EditorLanguage.bash:
      return _validateBash(text);
    case EditorLanguage.plain:
      return null;
  }
}

EditorSyntaxIssue? _validateJson(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  try {
    jsonDecode(trimmed);
    return null;
  } on FormatException catch (e) {
    final line = e.offset != null ? _lineAtOffset(text, e.offset!) : null;
    final detail = e.message.trim();
    return EditorSyntaxIssue(
      message: detail.isEmpty ? 'JSON 语法错误' : 'JSON 语法错误：$detail',
      line: line,
    );
  }
}

EditorSyntaxIssue? _validateYaml(String text) {
  if (text.trim().isEmpty) return null;
  try {
    loadYaml(text);
    return null;
  } on YamlException catch (e) {
    final line = e.span?.start.line;
    // package:yaml uses 0-based lines.
    final oneBased = line == null ? null : line + 1;
    final detail = e.message.trim();
    return EditorSyntaxIssue(
      message: detail.isEmpty ? 'YAML 语法错误' : 'YAML 语法错误：$detail',
      line: oneBased,
    );
  }
}

EditorSyntaxIssue? _validateJavascript(String text) {
  return _validateDelimitedSource(
    text,
    languageLabel: 'JavaScript',
    allowTemplateLiterals: true,
    allowLineComments: true,
    allowBlockComments: true,
    allowRegexLiterals: true,
  );
}

EditorSyntaxIssue? _validateBash(String text) {
  final delim = _validateDelimitedSource(
    text,
    languageLabel: 'Bash',
    allowTemplateLiterals: false,
    allowLineComments: true,
    allowBlockComments: false,
    allowRegexLiterals: false,
    bashHashComments: true,
  );
  if (delim != null) return delim;
  return _validateBashKeywords(text);
}

EditorSyntaxIssue? _validateHtml(String text) {
  if (text.trim().isEmpty) return null;

  final voidTags = <String>{
    'area',
    'base',
    'br',
    'col',
    'embed',
    'hr',
    'img',
    'input',
    'link',
    'meta',
    'param',
    'source',
    'track',
    'wbr',
  };

  final stack = <({String name, int line})>[];
  var i = 0;
  var line = 1;

  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c == 0x0A) {
      line++;
      i++;
      continue;
    }

    // Comment <!-- ... -->
    if (text.startsWith('<!--', i)) {
      final end = text.indexOf('-->', i + 4);
      if (end < 0) {
        return EditorSyntaxIssue(message: 'HTML 注释未闭合', line: line);
      }
      line += _countNewlines(text, i, end + 3);
      i = end + 3;
      continue;
    }

    // Doctype / processing — skip to >
    if (text.startsWith('<!', i) || text.startsWith('<?', i)) {
      final end = text.indexOf('>', i + 2);
      if (end < 0) {
        return EditorSyntaxIssue(message: 'HTML 声明未闭合', line: line);
      }
      line += _countNewlines(text, i, end + 1);
      i = end + 1;
      continue;
    }

    if (c != 0x3C /* < */) {
      i++;
      continue;
    }

    // Closing tag </name>
    if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x2F /* / */) {
      final startLine = line;
      var j = i + 2;
      while (j < text.length && _isHtmlNameChar(text.codeUnitAt(j))) {
        j++;
      }
      if (j == i + 2) {
        return EditorSyntaxIssue(message: 'HTML 结束标签无效', line: startLine);
      }
      final name = text.substring(i + 2, j).toLowerCase();
      while (j < text.length && text.codeUnitAt(j) != 0x3E /* > */) {
        if (text.codeUnitAt(j) == 0x0A) line++;
        j++;
      }
      if (j >= text.length) {
        return EditorSyntaxIssue(message: 'HTML 结束标签未闭合', line: startLine);
      }
      j++; // >
      if (stack.isEmpty) {
        return EditorSyntaxIssue(
          message: '多余的结束标签 </$name>',
          line: startLine,
        );
      }
      final top = stack.removeLast();
      if (top.name != name) {
        return EditorSyntaxIssue(
          message: '标签不匹配：期望 </${top.name}>，实际 </$name>',
          line: startLine,
        );
      }
      line += _countNewlines(text, i, j);
      i = j;
      continue;
    }

    // Opening / self-closing tag
    if (i + 1 < text.length && _isHtmlNameStart(text.codeUnitAt(i + 1))) {
      final startLine = line;
      var j = i + 1;
      while (j < text.length && _isHtmlNameChar(text.codeUnitAt(j))) {
        j++;
      }
      final name = text.substring(i + 1, j).toLowerCase();

      var selfClosing = false;
      var inAttrQuote = 0;
      var foundClose = false;
      while (j < text.length) {
        final cj = text.codeUnitAt(j);
        if (cj == 0x0A) line++;
        if (inAttrQuote != 0) {
          if (cj == inAttrQuote) inAttrQuote = 0;
          j++;
          continue;
        }
        if (cj == 0x22 /* " */ || cj == 0x27 /* ' */) {
          inAttrQuote = cj;
          j++;
          continue;
        }
        if (cj == 0x3E /* > */) {
          var k = j - 1;
          while (k > i &&
              (text.codeUnitAt(k) == 0x20 ||
                  text.codeUnitAt(k) == 0x09 ||
                  text.codeUnitAt(k) == 0x0D ||
                  text.codeUnitAt(k) == 0x0A)) {
            k--;
          }
          if (k > i && text.codeUnitAt(k) == 0x2F /* / */) {
            selfClosing = true;
          }
          j++;
          foundClose = true;
          break;
        }
        j++;
      }
      if (!foundClose) {
        return EditorSyntaxIssue(
          message: 'HTML 标签 <$name 未闭合',
          line: startLine,
        );
      }

      if (!selfClosing && !voidTags.contains(name)) {
        if (name == 'script' || name == 'style') {
          final close = '</$name>';
          final closeIdx = text.toLowerCase().indexOf(close, j);
          if (closeIdx < 0) {
            return EditorSyntaxIssue(
              message: '未找到 </$name>',
              line: startLine,
            );
          }
          line += _countNewlines(text, j, closeIdx + close.length);
          i = closeIdx + close.length;
          continue;
        }
        stack.add((name: name, line: startLine));
      }
      i = j;
      continue;
    }

    i++;
  }

  if (stack.isNotEmpty) {
    final top = stack.last;
    return EditorSyntaxIssue(
      message: '未闭合的标签 <${top.name}>',
      line: top.line,
    );
  }
  return null;
}

bool _isHtmlNameStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

bool _isHtmlNameChar(int c) =>
    _isHtmlNameStart(c) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x2D /* - */ ||
    c == 0x3A /* : */;

/// Shared scanner for JS / Bash: strings, comments, delimiter balance.
EditorSyntaxIssue? _validateDelimitedSource(
  String text, {
  required String languageLabel,
  required bool allowTemplateLiterals,
  required bool allowLineComments,
  required bool allowBlockComments,
  required bool allowRegexLiterals,
  bool bashHashComments = false,
}) {
  if (text.trim().isEmpty) return null;

  final stack = <({int ch, int line})>[];
  var i = 0;
  var line = 1;
  var prevSignificant = 0; // last non-space code unit (for regex detection)

  while (i < text.length) {
    final c = text.codeUnitAt(i);

    if (c == 0x0A) {
      line++;
      i++;
      continue;
    }

    // Bash # comments
    if (bashHashComments && c == 0x23 /* # */) {
      while (i < text.length && text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      continue;
    }

    // Line comments //
    if (allowLineComments &&
        c == 0x2F /* / */ &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) == 0x2F) {
      i += 2;
      while (i < text.length && text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      continue;
    }

    // Block comments /* */
    if (allowBlockComments &&
        c == 0x2F &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) == 0x2A /* * */) {
      final startLine = line;
      i += 2;
      var closed = false;
      while (i < text.length) {
        if (text.codeUnitAt(i) == 0x0A) line++;
        if (text.codeUnitAt(i) == 0x2A &&
            i + 1 < text.length &&
            text.codeUnitAt(i + 1) == 0x2F) {
          i += 2;
          closed = true;
          break;
        }
        i++;
      }
      if (!closed) {
        return EditorSyntaxIssue(
          message: '$languageLabel 块注释未闭合',
          line: startLine,
        );
      }
      continue;
    }

    // Strings
    if (c == 0x27 /* ' */ ||
        c == 0x22 /* " */ ||
        (allowTemplateLiterals && c == 0x60 /* ` */)) {
      final quote = c;
      final startLine = line;
      i++;
      var closed = false;
      while (i < text.length) {
        final q = text.codeUnitAt(i);
        if (q == 0x0A) {
          if (quote != 0x60) {
            return EditorSyntaxIssue(
              message: '$languageLabel 字符串未闭合',
              line: startLine,
            );
          }
          line++;
          i++;
          continue;
        }
        if (q == 0x5C /* \ */) {
          i += 2;
          continue;
        }
        if (q == quote) {
          i++;
          closed = true;
          break;
        }
        i++;
      }
      if (!closed) {
        return EditorSyntaxIssue(
          message: '$languageLabel 字符串未闭合',
          line: startLine,
        );
      }
      prevSignificant = quote;
      continue;
    }

    // Regex literal (heuristic)
    if (allowRegexLiterals &&
        c == 0x2F &&
        _canStartRegex(prevSignificant)) {
      final startLine = line;
      i++;
      var closed = false;
      while (i < text.length) {
        final r = text.codeUnitAt(i);
        if (r == 0x0A) {
          return EditorSyntaxIssue(
            message: '$languageLabel 正则表达式未闭合',
            line: startLine,
          );
        }
        if (r == 0x5C) {
          i += 2;
          continue;
        }
        if (r == 0x2F) {
          i++;
          while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
            i++;
          }
          closed = true;
          break;
        }
        // Character class
        if (r == 0x5B /* [ */) {
          i++;
          while (i < text.length) {
            final cc = text.codeUnitAt(i);
            if (cc == 0x0A) break;
            if (cc == 0x5C) {
              i += 2;
              continue;
            }
            if (cc == 0x5D /* ] */) {
              i++;
              break;
            }
            i++;
          }
          continue;
        }
        i++;
      }
      if (!closed) {
        return EditorSyntaxIssue(
          message: '$languageLabel 正则表达式未闭合',
          line: startLine,
        );
      }
      prevSignificant = 0x2F;
      continue;
    }

    if (c == 0x28 /* ( */ || c == 0x5B /* [ */ || c == 0x7B /* { */) {
      stack.add((ch: c, line: line));
      prevSignificant = c;
      i++;
      continue;
    }

    if (c == 0x29 /* ) */ || c == 0x5D /* ] */ || c == 0x7D /* } */) {
      if (stack.isEmpty) {
        return EditorSyntaxIssue(
          message: '$languageLabel 多余的 ${_delimLabel(c)}',
          line: line,
        );
      }
      final top = stack.removeLast();
      if (!_delimsMatch(top.ch, c)) {
        return EditorSyntaxIssue(
          message:
              '$languageLabel 括号不匹配：期望 ${_closingLabel(top.ch)}，实际 ${_delimLabel(c)}',
          line: line,
        );
      }
      prevSignificant = c;
      i++;
      continue;
    }

    if (!_isSpace(c)) {
      prevSignificant = c;
    }
    i++;
  }

  if (stack.isNotEmpty) {
    final top = stack.last;
    return EditorSyntaxIssue(
      message: '$languageLabel 未闭合的 ${_delimLabel(top.ch)}',
      line: top.line,
    );
  }
  return null;
}

EditorSyntaxIssue? _validateBashKeywords(String text) {
  // Strip comments and strings roughly via the same scanner state — reuse a
  // light keyword stack on a comment/string-stripped view.
  final tokens = <({String word, int line})>[];
  var i = 0;
  var line = 1;
  final buf = StringBuffer();

  void flushWord() {
    if (buf.isEmpty) return;
    final w = buf.toString();
    buf.clear();
    if (_bashKeywords.contains(w)) {
      tokens.add((word: w, line: line));
    }
  }

  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c == 0x0A) {
      flushWord();
      line++;
      i++;
      continue;
    }
    if (c == 0x23 /* # */) {
      flushWord();
      while (i < text.length && text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      continue;
    }
    if (c == 0x27 || c == 0x22) {
      flushWord();
      final quote = c;
      i++;
      while (i < text.length) {
        final q = text.codeUnitAt(i);
        if (q == 0x0A) {
          line++;
          i++;
          continue;
        }
        if (q == 0x5C) {
          i += 2;
          continue;
        }
        if (q == quote) {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (_isIdentChar(c) || c == 0x21 /* ! */) {
      // allow if/! patterns — only letters for keywords
      if ((c >= 0x41 && c <= 0x5A) ||
          (c >= 0x61 && c <= 0x7A) ||
          c == 0x5F) {
        buf.writeCharCode(c);
      } else {
        flushWord();
      }
      i++;
      continue;
    }
    flushWord();
    i++;
  }
  flushWord();

  final stack = <({String word, int line})>[];
  for (final t in tokens) {
    switch (t.word) {
      case 'if':
      case 'case':
      case 'for':
      case 'while':
      case 'until':
      case 'select':
        stack.add(t);
        break;
      case 'then':
        if (stack.isEmpty || stack.last.word != 'if') {
          return EditorSyntaxIssue(
            message: 'Bash：then 缺少对应的 if',
            line: t.line,
          );
        }
        break;
      case 'do':
        if (stack.isEmpty ||
            !(stack.last.word == 'for' ||
                stack.last.word == 'while' ||
                stack.last.word == 'until' ||
                stack.last.word == 'select')) {
          // do can also follow for/while — soft check only when stack empty of loops
          // Allow loose: if there's an open for/while somewhere it's ok; otherwise warn
          final hasLoop = stack.any(
            (s) =>
                s.word == 'for' ||
                s.word == 'while' ||
                s.word == 'until' ||
                s.word == 'select',
          );
          if (!hasLoop) {
            return EditorSyntaxIssue(
              message: 'Bash：do 缺少对应的 for/while/until',
              line: t.line,
            );
          }
        }
        break;
      case 'fi':
        if (stack.isEmpty || stack.last.word != 'if') {
          return EditorSyntaxIssue(
            message: 'Bash：fi 缺少对应的 if',
            line: t.line,
          );
        }
        stack.removeLast();
        break;
      case 'done':
        if (stack.isEmpty ||
            !(stack.last.word == 'for' ||
                stack.last.word == 'while' ||
                stack.last.word == 'until' ||
                stack.last.word == 'select')) {
          return EditorSyntaxIssue(
            message: 'Bash：done 缺少对应的 for/while/until',
            line: t.line,
          );
        }
        stack.removeLast();
        break;
      case 'esac':
        if (stack.isEmpty || stack.last.word != 'case') {
          return EditorSyntaxIssue(
            message: 'Bash：esac 缺少对应的 case',
            line: t.line,
          );
        }
        stack.removeLast();
        break;
    }
  }

  if (stack.isNotEmpty) {
    final top = stack.last;
    final closer = switch (top.word) {
      'if' => 'fi',
      'case' => 'esac',
      _ => 'done',
    };
    return EditorSyntaxIssue(
      message: 'Bash：${top.word} 缺少对应的 $closer',
      line: top.line,
    );
  }
  return null;
}

const _bashKeywords = {
  'if',
  'then',
  'fi',
  'case',
  'esac',
  'for',
  'while',
  'until',
  'select',
  'do',
  'done',
};

bool _canStartRegex(int prev) {
  if (prev == 0) return true;
  // After these tokens a `/` is likely a regex, not division.
  const ok = {
    0x28, // (
    0x5B, // [
    0x7B, // {
    0x3D, // =
    0x3A, // :
    0x2C, // ,
    0x3B, // ;
    0x21, // !
    0x26, // &
    0x7C, // |
    0x3F, // ?
    0x2B, // +
    0x2D, // -
    0x2A, // *
    0x25, // %
    0x5E, // ^
    0x7E, // ~
    0x3C, // <
    0x3E, // >
  };
  return ok.contains(prev);
}

bool _isIdentChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x5F ||
    c == 0x24; // $

bool _isSpace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A;

bool _delimsMatch(int open, int close) {
  return (open == 0x28 && close == 0x29) ||
      (open == 0x5B && close == 0x5D) ||
      (open == 0x7B && close == 0x7D);
}

String _delimLabel(int c) {
  switch (c) {
    case 0x28:
      return '(';
    case 0x29:
      return ')';
    case 0x5B:
      return '[';
    case 0x5D:
      return ']';
    case 0x7B:
      return '{';
    case 0x7D:
      return '}';
    default:
      return String.fromCharCode(c);
  }
}

String _closingLabel(int open) {
  switch (open) {
    case 0x28:
      return ')';
    case 0x5B:
      return ']';
    case 0x7B:
      return '}';
    default:
      return '?';
  }
}

int _lineAtOffset(String text, int offset) {
  var line = 1;
  final end = offset.clamp(0, text.length);
  for (var i = 0; i < end; i++) {
    if (text.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}

int _countNewlines(String text, int from, int to) {
  var n = 0;
  final end = to.clamp(0, text.length);
  for (var i = from; i < end; i++) {
    if (text.codeUnitAt(i) == 0x0A) n++;
  }
  return n;
}
