import 'package:flutter/material.dart';

import '../theme/workbench_theme.dart';
import 'editor_syntax.dart';

/// Token roles used by the remote editor highlighter.
enum EditorHighlightKind {
  plain,
  comment,
  string,
  number,
  keyword,
  key,
  punctuation,
  boolean,
  variable,
}

/// Theme colors for syntax highlighting (light / dark).
@immutable
class EditorHighlightTheme {
  const EditorHighlightTheme({
    required this.comment,
    required this.string,
    required this.number,
    required this.keyword,
    required this.key,
    required this.punctuation,
    required this.boolean,
    required this.variable,
  });

  final Color comment;
  final Color string;
  final Color number;
  final Color keyword;
  final Color key;
  final Color punctuation;
  final Color boolean;
  final Color variable;

  static const EditorHighlightTheme dark = EditorHighlightTheme(
    comment: Color(0xFF6A9955),
    string: Color(0xFFCE9178),
    number: Color(0xFFB5CEA8),
    keyword: Color(0xFFC586C0),
    key: Color(0xFF9CDCFE),
    punctuation: Color(0xFFD4D4D4),
    boolean: Color(0xFF569CD6),
    variable: Color(0xFF4EC9B0),
  );

  static const EditorHighlightTheme light = EditorHighlightTheme(
    comment: Color(0xFF008000),
    string: Color(0xFFA31515),
    number: Color(0xFF098658),
    keyword: Color(0xFFAF00DB),
    key: Color(0xFF0451A5),
    punctuation: Color(0xFF383A42),
    boolean: Color(0xFF0000FF),
    variable: Color(0xFF267F99),
  );

  static EditorHighlightTheme forBrightness(Brightness brightness) =>
      brightness == Brightness.light ? light : dark;

  Color colorFor(EditorHighlightKind kind) {
    switch (kind) {
      case EditorHighlightKind.plain:
        return const Color(0x00000000); // unused — caller keeps base
      case EditorHighlightKind.comment:
        return comment;
      case EditorHighlightKind.string:
        return string;
      case EditorHighlightKind.number:
        return number;
      case EditorHighlightKind.keyword:
        return keyword;
      case EditorHighlightKind.key:
        return key;
      case EditorHighlightKind.punctuation:
        return punctuation;
      case EditorHighlightKind.boolean:
        return boolean;
      case EditorHighlightKind.variable:
        return variable;
    }
  }
}

/// [TextEditingController] that paints syntax colors for supported languages.
class SyntaxEditingController extends TextEditingController {
  SyntaxEditingController({
    super.text,
    EditorLanguage language = EditorLanguage.plain,
  }) : _language = language;

  EditorLanguage _language;

  EditorLanguage get language => _language;

  set language(EditorLanguage value) {
    if (_language == value) return;
    _language = value;
    invalidateHighlightCache();
    notifyListeners();
  }

  List<TextRange> _hitRanges = const [];
  int _currentHitIndex = -1;

  void setFindHits(List<TextRange> ranges, {int currentIndex = -1}) {
    _hitRanges = List.unmodifiable(ranges);
    _currentHitIndex = currentIndex;
    invalidateHighlightCache();
    notifyListeners();
  }

  void clearFindHits() {
    if (_hitRanges.isEmpty && _currentHitIndex < 0) return;
    _hitRanges = const [];
    _currentHitIndex = -1;
    invalidateHighlightCache();
    notifyListeners();
  }

  String? _cacheText;
  EditorLanguage? _cacheLanguage;
  Brightness? _cacheBrightness;
  TextStyle? _cacheBase;
  int? _cacheHitFingerprint;
  TextSpan? _cacheSpan;

  int _hitFingerprint() {
    if (_hitRanges.isEmpty) return 0;
    var h = _currentHitIndex + 1;
    for (final r in _hitRanges) {
      h = Object.hash(h, r.start, r.end);
    }
    return h;
  }

  void invalidateHighlightCache() {
    _cacheText = null;
    _cacheSpan = null;
    _cacheHitFingerprint = null;
  }

  @override
  set value(TextEditingValue newValue) {
    if (newValue.text != text) invalidateHighlightCache();
    super.value = newValue;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // Keep IME composing underline correct; skip colors briefly.
    if (withComposing &&
        value.composing.isValid &&
        !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final base = style ?? const TextStyle();

    // Skip heavy highlight on huge buffers — keep editing responsive.
    if (text.length > 120000) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final brightness = Theme.of(context).brightness;
    final hitFp = _hitFingerprint();
    if (_cacheSpan != null &&
        _cacheText == text &&
        _cacheLanguage == _language &&
        _cacheBrightness == brightness &&
        _cacheBase == base &&
        _cacheHitFingerprint == hitFp) {
      return _cacheSpan!;
    }

    TextSpan span;
    if (_language == EditorLanguage.plain || text.isEmpty) {
      span = TextSpan(text: text, style: base);
    } else {
      final theme = EditorHighlightTheme.forBrightness(brightness);
      span = buildHighlightedSpan(
        text,
        language: _language,
        baseStyle: base,
        theme: theme,
      );
    }

    if (_hitRanges.isNotEmpty) {
      span = applyFindHitBackgrounds(
        span,
        _hitRanges,
        _currentHitIndex,
        WorkbenchColors.findHitBg,
        WorkbenchColors.findHitCurrentBg,
      );
    }

    _cacheText = text;
    _cacheLanguage = _language;
    _cacheBrightness = brightness;
    _cacheBase = base;
    _cacheHitFingerprint = hitFp;
    _cacheSpan = span;
    return span;
  }
}

List<({String text, TextStyle style})> _flattenTextSpan(TextSpan span) {
  final out = <({String text, TextStyle style})>[];
  void rec(TextSpan s, TextStyle? parent) {
    final st = s.style ?? parent ?? const TextStyle();
    if (s.text != null && s.text!.isNotEmpty) {
      out.add((text: s.text!, style: st));
    }
    for (final c in s.children ?? const <InlineSpan>[]) {
      if (c is TextSpan) rec(c, st);
    }
  }

  rec(span, span.style);
  return out;
}

Color? _backgroundForHit(
  int pos,
  List<TextRange> hits,
  int currentIndex,
  Color hitBg,
  Color currentBg,
) {
  for (var i = 0; i < hits.length; i++) {
    final r = hits[i];
    if (pos >= r.start && pos < r.end) {
      return i == currentIndex ? currentBg : hitBg;
    }
  }
  return null;
}

/// Overlay find-hit backgrounds onto an existing highlighted [TextSpan].
TextSpan applyFindHitBackgrounds(
  TextSpan span,
  List<TextRange> hits,
  int currentIndex,
  Color hitBg,
  Color currentBg,
) {
  final flat = _flattenTextSpan(span);
  final children = <InlineSpan>[];
  var offset = 0;
  for (final piece in flat) {
    var local = 0;
    while (local < piece.text.length) {
      final bg = _backgroundForHit(
        offset + local,
        hits,
        currentIndex,
        hitBg,
        currentBg,
      );
      var end = local + 1;
      while (end < piece.text.length) {
        if (_backgroundForHit(
              offset + end,
              hits,
              currentIndex,
              hitBg,
              currentBg,
            ) !=
            bg) {
          break;
        }
        end++;
      }
      final chunk = piece.text.substring(local, end);
      final style =
          bg != null ? piece.style.copyWith(backgroundColor: bg) : piece.style;
      children.add(TextSpan(text: chunk, style: style));
      local = end;
    }
    offset += piece.text.length;
  }
  return TextSpan(style: span.style, children: children);
}

/// Build a highlighted [TextSpan] tree for [source].
TextSpan buildHighlightedSpan(
  String source, {
  required EditorLanguage language,
  required TextStyle baseStyle,
  required EditorHighlightTheme theme,
}) {
  final spans = <InlineSpan>[];
  void emit(String chunk, EditorHighlightKind kind) {
    if (chunk.isEmpty) return;
    if (kind == EditorHighlightKind.plain) {
      spans.add(TextSpan(text: chunk, style: baseStyle));
      return;
    }
    spans.add(
      TextSpan(
        text: chunk,
        style: baseStyle.copyWith(color: theme.colorFor(kind)),
      ),
    );
  }

  switch (language) {
    case EditorLanguage.json:
      _highlightJson(source, emit);
    case EditorLanguage.yaml:
      _highlightYaml(source, emit);
    case EditorLanguage.javascript:
      _highlightJavascript(source, emit);
    case EditorLanguage.bash:
      _highlightBash(source, emit);
    case EditorLanguage.html:
    case EditorLanguage.xml:
      _highlightHtml(source, emit);
    case EditorLanguage.css:
      _highlightCss(source, emit);
    case EditorLanguage.python:
      _highlightPython(source, emit);
    case EditorLanguage.dockerfile:
      _highlightDockerfile(source, emit);
    case EditorLanguage.markdown:
      _highlightMarkdown(source, emit);
    case EditorLanguage.ini:
      _highlightIni(source, emit);
    case EditorLanguage.go:
      _highlightGo(source, emit);
    case EditorLanguage.sql:
      _highlightSql(source, emit);
    case EditorLanguage.plain:
      emit(source, EditorHighlightKind.plain);
  }

  return TextSpan(style: baseStyle, children: spans);
}

typedef _Emit = void Function(String chunk, EditorHighlightKind kind);

void _highlightJson(String text, _Emit emit) {
  var i = 0;
  while (i < text.length) {
    final c = text.codeUnitAt(i);

    if (_isSpace(c)) {
      final start = i;
      while (i < text.length && _isSpace(text.codeUnitAt(i))) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.plain);
      continue;
    }

    if (c == 0x22 /* " */) {
      final start = i;
      i = _consumeJsonString(text, i);
      final lit = text.substring(start, i);
      // Key if next non-space is ':'
      var j = i;
      while (j < text.length && _isSpace(text.codeUnitAt(j))) {
        j++;
      }
      final isKey = j < text.length && text.codeUnitAt(j) == 0x3A /* : */;
      emit(
        lit,
        isKey ? EditorHighlightKind.key : EditorHighlightKind.string,
      );
      continue;
    }

    if (c == 0x2D /* - */ || (c >= 0x30 && c <= 0x39)) {
      final start = i;
      i = _consumeNumber(text, i);
      emit(text.substring(start, i), EditorHighlightKind.number);
      continue;
    }

    if (_isIdentStart(c)) {
      final start = i;
      i++;
      while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
        i++;
      }
      final word = text.substring(start, i);
      if (word == 'true' || word == 'false' || word == 'null') {
        emit(word, EditorHighlightKind.boolean);
      } else {
        emit(word, EditorHighlightKind.plain);
      }
      continue;
    }

    if (_isJsonPunct(c)) {
      emit(text.substring(i, i + 1), EditorHighlightKind.punctuation);
      i++;
      continue;
    }

    emit(text.substring(i, i + 1), EditorHighlightKind.plain);
    i++;
  }
}

void _highlightYaml(String text, _Emit emit) {
  var i = 0;
  while (i < text.length) {
    final c = text.codeUnitAt(i);

    // Line-leading --- / ...
    if ((c == 0x2D || c == 0x2E) && _atLineStart(text, i)) {
      final run = c;
      var j = i;
      while (j < text.length && text.codeUnitAt(j) == run) {
        j++;
      }
      if (j - i >= 3 &&
          (j >= text.length ||
              text.codeUnitAt(j) == 0x0A ||
              text.codeUnitAt(j) == 0x0D ||
              _isSpace(text.codeUnitAt(j)))) {
        emit(text.substring(i, j), EditorHighlightKind.keyword);
        i = j;
        continue;
      }
    }

    if (c == 0x23 /* # */ && _yamlCommentAllowed(text, i)) {
      final start = i;
      while (i < text.length && text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.comment);
      continue;
    }

    if (c == 0x27 || c == 0x22) {
      final start = i;
      i = _consumeQuoted(text, i, allowEscape: true);
      emit(text.substring(start, i), EditorHighlightKind.string);
      continue;
    }

    // Key: unquoted identifier/path before ':' at roughly key position
    if (_yamlMaybeKeyStart(text, i)) {
      final start = i;
      final keyEnd = _consumeYamlKey(text, i);
      if (keyEnd > i) {
        var j = keyEnd;
        while (j < text.length &&
            (text.codeUnitAt(j) == 0x20 || text.codeUnitAt(j) == 0x09)) {
          j++;
        }
        if (j < text.length && text.codeUnitAt(j) == 0x3A /* : */) {
          emit(text.substring(start, keyEnd), EditorHighlightKind.key);
          i = keyEnd;
          continue;
        }
      }
    }

    if (c == 0x2D /* - */ || (c >= 0x30 && c <= 0x39)) {
      // list dash at line start / after indent
      if (c == 0x2D &&
          _yamlListDash(text, i) &&
          (i + 1 >= text.length ||
              _isSpace(text.codeUnitAt(i + 1)) ||
              text.codeUnitAt(i + 1) == 0x0A)) {
        emit('-', EditorHighlightKind.punctuation);
        i++;
        continue;
      }
      if (c == 0x2D /* - */ &&
          i + 1 < text.length &&
          text.codeUnitAt(i + 1) >= 0x30 &&
          text.codeUnitAt(i + 1) <= 0x39) {
        final start = i;
        i = _consumeNumber(text, i);
        emit(text.substring(start, i), EditorHighlightKind.number);
        continue;
      }
      if (c >= 0x30 && c <= 0x39) {
        final start = i;
        i = _consumeNumber(text, i);
        emit(text.substring(start, i), EditorHighlightKind.number);
        continue;
      }
    }

    if (_isIdentStart(c)) {
      final start = i;
      i++;
      while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
        i++;
      }
      final word = text.substring(start, i);
      if (word == 'true' ||
          word == 'false' ||
          word == 'null' ||
          word == 'yes' ||
          word == 'no' ||
          word == 'on' ||
          word == 'off') {
        emit(word, EditorHighlightKind.boolean);
      } else {
        emit(word, EditorHighlightKind.plain);
      }
      continue;
    }

    if (c == 0x3A /* : */ ||
        c == 0x2C /* , */ ||
        c == 0x5B ||
        c == 0x5D ||
        c == 0x7B ||
        c == 0x7D ||
        c == 0x7C /* | */ ||
        c == 0x3E /* > */) {
      emit(text.substring(i, i + 1), EditorHighlightKind.punctuation);
      i++;
      continue;
    }

    emit(text.substring(i, i + 1), EditorHighlightKind.plain);
    i++;
  }
}

void _highlightJavascript(String text, _Emit emit) {
  var i = 0;
  var prevSignificant = 0;
  while (i < text.length) {
    final c = text.codeUnitAt(i);

    if (c == 0x2F && i + 1 < text.length) {
      final n = text.codeUnitAt(i + 1);
      if (n == 0x2F) {
        final start = i;
        i += 2;
        while (i < text.length && text.codeUnitAt(i) != 0x0A) {
          i++;
        }
        emit(text.substring(start, i), EditorHighlightKind.comment);
        continue;
      }
      if (n == 0x2A) {
        final start = i;
        i += 2;
        while (i + 1 < text.length &&
            !(text.codeUnitAt(i) == 0x2A && text.codeUnitAt(i + 1) == 0x2F)) {
          i++;
        }
        if (i + 1 < text.length) i += 2;
        emit(text.substring(start, i), EditorHighlightKind.comment);
        continue;
      }
      if (_canStartRegex(prevSignificant)) {
        final start = i;
        i = _consumeRegex(text, i);
        emit(text.substring(start, i), EditorHighlightKind.string);
        prevSignificant = 0x2F;
        continue;
      }
    }

    if (c == 0x27 || c == 0x22 || c == 0x60) {
      final start = i;
      i = _consumeJsString(text, i);
      emit(text.substring(start, i), EditorHighlightKind.string);
      prevSignificant = c;
      continue;
    }

    if (c == 0x2E /* . */ &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) >= 0x30 &&
        text.codeUnitAt(i + 1) <= 0x39) {
      final start = i;
      i = _consumeNumber(text, i);
      emit(text.substring(start, i), EditorHighlightKind.number);
      prevSignificant = 0x30;
      continue;
    }

    if (c >= 0x30 && c <= 0x39) {
      final start = i;
      i = _consumeNumber(text, i);
      emit(text.substring(start, i), EditorHighlightKind.number);
      prevSignificant = 0x30;
      continue;
    }

    if (_isIdentStart(c) || c == 0x24 /* $ */) {
      final start = i;
      i++;
      while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
        i++;
      }
      final word = text.substring(start, i);
      if (_jsKeywords.contains(word)) {
        emit(word, EditorHighlightKind.keyword);
      } else if (word == 'true' || word == 'false' || word == 'null') {
        emit(word, EditorHighlightKind.boolean);
      } else {
        emit(word, EditorHighlightKind.plain);
      }
      prevSignificant = 0x61; // letter
      continue;
    }

    if (_isJsPunct(c)) {
      emit(text.substring(i, i + 1), EditorHighlightKind.punctuation);
      if (!_isSpace(c)) prevSignificant = c;
      i++;
      continue;
    }

    if (!_isSpace(c)) prevSignificant = c;
    emit(text.substring(i, i + 1), EditorHighlightKind.plain);
    i++;
  }
}

void _highlightBash(String text, _Emit emit) {
  var i = 0;
  while (i < text.length) {
    final c = text.codeUnitAt(i);

    if (c == 0x23 /* # */) {
      final start = i;
      while (i < text.length && text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.comment);
      continue;
    }

    if (c == 0x27 || c == 0x22) {
      final start = i;
      i = _consumeQuoted(text, i, allowEscape: c == 0x22);
      emit(text.substring(start, i), EditorHighlightKind.string);
      continue;
    }

    if (c == 0x24 /* $ */) {
      final start = i;
      i++;
      if (i < text.length && text.codeUnitAt(i) == 0x7B /* { */) {
        i++;
        while (i < text.length && text.codeUnitAt(i) != 0x7D) {
          if (text.codeUnitAt(i) == 0x0A) break;
          i++;
        }
        if (i < text.length && text.codeUnitAt(i) == 0x7D) i++;
      } else if (i < text.length &&
          (text.codeUnitAt(i) == 0x24 ||
              text.codeUnitAt(i) == 0x3F ||
              text.codeUnitAt(i) == 0x21 ||
              text.codeUnitAt(i) == 0x23 ||
              text.codeUnitAt(i) == 0x2A ||
              text.codeUnitAt(i) == 0x40 ||
              (text.codeUnitAt(i) >= 0x30 && text.codeUnitAt(i) <= 0x39))) {
        i++;
      } else {
        while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
          i++;
        }
      }
      emit(text.substring(start, i), EditorHighlightKind.variable);
      continue;
    }

    if (c >= 0x30 && c <= 0x39) {
      final start = i;
      while (i < text.length &&
          text.codeUnitAt(i) >= 0x30 &&
          text.codeUnitAt(i) <= 0x39) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.number);
      continue;
    }

    if (_isIdentStart(c)) {
      final start = i;
      i++;
      while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
        i++;
      }
      final word = text.substring(start, i);
      if (_bashKeywords.contains(word)) {
        emit(word, EditorHighlightKind.keyword);
      } else {
        emit(word, EditorHighlightKind.plain);
      }
      continue;
    }

    if (c == 0x7C ||
        c == 0x26 ||
        c == 0x3B ||
        c == 0x28 ||
        c == 0x29 ||
        c == 0x7B ||
        c == 0x7D ||
        c == 0x3C ||
        c == 0x3E) {
      emit(text.substring(i, i + 1), EditorHighlightKind.punctuation);
      i++;
      continue;
    }

    emit(text.substring(i, i + 1), EditorHighlightKind.plain);
    i++;
  }
}

void _highlightHtml(String text, _Emit emit) {
  var i = 0;
  while (i < text.length) {
    // Comment <!-- ... -->
    if (text.startsWith('<!--', i)) {
      final start = i;
      final end = text.indexOf('-->', i + 4);
      i = end < 0 ? text.length : end + 3;
      emit(text.substring(start, i), EditorHighlightKind.comment);
      continue;
    }

    final c = text.codeUnitAt(i);
    if (c != 0x3C /* < */) {
      // Text node until next tag
      final start = i;
      while (i < text.length && text.codeUnitAt(i) != 0x3C) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.plain);
      continue;
    }

    // Tag: <...>, </...>, <!...>, <?...>
    final tagStart = i;
    i++; // <
    if (i < text.length &&
        (text.codeUnitAt(i) == 0x21 /* ! */ ||
            text.codeUnitAt(i) == 0x3F /* ? */)) {
      while (i < text.length && text.codeUnitAt(i) != 0x3E) {
        i++;
      }
      if (i < text.length) i++;
      emit(text.substring(tagStart, i), EditorHighlightKind.keyword);
      continue;
    }

    var closing = false;
    if (i < text.length && text.codeUnitAt(i) == 0x2F /* / */) {
      closing = true;
      i++;
    }

    emit('<${closing ? '/' : ''}', EditorHighlightKind.punctuation);

    // Tag name
    final nameStart = i;
    while (i < text.length && _isHtmlNameChar(text.codeUnitAt(i))) {
      i++;
    }
    if (i > nameStart) {
      emit(text.substring(nameStart, i), EditorHighlightKind.keyword);
    }

    // Attributes until >
    while (i < text.length) {
      final ac = text.codeUnitAt(i);
      if (ac == 0x3E /* > */) {
        emit('>', EditorHighlightKind.punctuation);
        i++;
        break;
      }
      if (ac == 0x2F /* / */ &&
          i + 1 < text.length &&
          text.codeUnitAt(i + 1) == 0x3E) {
        emit('/>', EditorHighlightKind.punctuation);
        i += 2;
        break;
      }
      if (_isSpace(ac)) {
        final start = i;
        while (i < text.length && _isSpace(text.codeUnitAt(i))) {
          i++;
        }
        emit(text.substring(start, i), EditorHighlightKind.plain);
        continue;
      }
      if (ac == 0x27 || ac == 0x22) {
        final start = i;
        i = _consumeQuoted(text, i, allowEscape: false);
        emit(text.substring(start, i), EditorHighlightKind.string);
        continue;
      }
      if (_isHtmlNameStart(ac)) {
        final start = i;
        i++;
        while (i < text.length && _isHtmlNameChar(text.codeUnitAt(i))) {
          i++;
        }
        emit(text.substring(start, i), EditorHighlightKind.key);
        continue;
      }
      if (ac == 0x3D /* = */) {
        emit('=', EditorHighlightKind.punctuation);
        i++;
        continue;
      }
      emit(text.substring(i, i + 1), EditorHighlightKind.plain);
      i++;
    }
  }
}

void _highlightCss(String text, _Emit emit) {
  var i = 0;
  var inBlock = 0;
  while (i < text.length) {
    final c = text.codeUnitAt(i);

    if (c == 0x2F && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x2A) {
      final start = i;
      i += 2;
      while (i + 1 < text.length &&
          !(text.codeUnitAt(i) == 0x2A && text.codeUnitAt(i + 1) == 0x2F)) {
        i++;
      }
      if (i + 1 < text.length) i += 2;
      emit(text.substring(start, i), EditorHighlightKind.comment);
      continue;
    }

    if (c == 0x27 || c == 0x22) {
      final start = i;
      i = _consumeQuoted(text, i, allowEscape: true);
      emit(text.substring(start, i), EditorHighlightKind.string);
      continue;
    }

    if (c == 0x7B /* { */) {
      inBlock++;
      emit('{', EditorHighlightKind.punctuation);
      i++;
      continue;
    }
    if (c == 0x7D /* } */) {
      if (inBlock > 0) inBlock--;
      emit('}', EditorHighlightKind.punctuation);
      i++;
      continue;
    }

    if (c == 0x3A /* : */ ||
        c == 0x3B /* ; */ ||
        c == 0x2C /* , */ ||
        c == 0x28 ||
        c == 0x29) {
      emit(text.substring(i, i + 1), EditorHighlightKind.punctuation);
      i++;
      continue;
    }

    if (c >= 0x30 && c <= 0x39) {
      final start = i;
      i = _consumeNumber(text, i);
      // trailing unit like px/em/%
      while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
        i++;
      }
      if (i < text.length && text.codeUnitAt(i) == 0x25 /* % */) i++;
      emit(text.substring(start, i), EditorHighlightKind.number);
      continue;
    }

    if (_isIdentStart(c) ||
        c == 0x2E /* . */ ||
        c == 0x23 /* # */ ||
        c == 0x40 /* @ */ ||
        c == 0x2D /* - */) {
      final start = i;
      i++;
      while (i < text.length) {
        final cc = text.codeUnitAt(i);
        if (_isIdentChar(cc) || cc == 0x2D || cc == 0x2E) {
          i++;
          continue;
        }
        break;
      }
      final word = text.substring(start, i);
      if (inBlock > 0) {
        // property name if next non-space is :
        var j = i;
        while (j < text.length && _isSpace(text.codeUnitAt(j))) {
          j++;
        }
        if (j < text.length && text.codeUnitAt(j) == 0x3A) {
          emit(word, EditorHighlightKind.key);
        } else {
          emit(word, EditorHighlightKind.plain);
        }
      } else {
        emit(word, EditorHighlightKind.keyword); // selector / at-rule
      }
      continue;
    }

    emit(text.substring(i, i + 1), EditorHighlightKind.plain);
    i++;
  }
}

void _highlightPython(String text, _Emit emit) {
  var i = 0;
  while (i < text.length) {
    final c = text.codeUnitAt(i);

    if (c == 0x23 /* # */) {
      final start = i;
      while (i < text.length && text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.comment);
      continue;
    }

    // Triple-quoted strings
    if ((c == 0x27 || c == 0x22) &&
        i + 2 < text.length &&
        text.codeUnitAt(i + 1) == c &&
        text.codeUnitAt(i + 2) == c) {
      final start = i;
      final quote = c;
      i += 3;
      while (i + 2 < text.length &&
          !(text.codeUnitAt(i) == quote &&
              text.codeUnitAt(i + 1) == quote &&
              text.codeUnitAt(i + 2) == quote)) {
        if (text.codeUnitAt(i) == 0x5C) {
          i += 2;
          continue;
        }
        i++;
      }
      if (i + 2 < text.length) i += 3;
      emit(text.substring(start, i), EditorHighlightKind.string);
      continue;
    }

    if (c == 0x27 || c == 0x22) {
      final start = i;
      i = _consumeQuoted(text, i, allowEscape: true);
      emit(text.substring(start, i), EditorHighlightKind.string);
      continue;
    }

    if (c == 0x2E /* . */ &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) >= 0x30 &&
        text.codeUnitAt(i + 1) <= 0x39) {
      final start = i;
      i = _consumeNumber(text, i);
      emit(text.substring(start, i), EditorHighlightKind.number);
      continue;
    }

    if (c >= 0x30 && c <= 0x39) {
      final start = i;
      i = _consumeNumber(text, i);
      emit(text.substring(start, i), EditorHighlightKind.number);
      continue;
    }

    if (_isIdentStart(c)) {
      final start = i;
      i++;
      while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
        i++;
      }
      final word = text.substring(start, i);
      if (_pythonKeywords.contains(word)) {
        emit(word, EditorHighlightKind.keyword);
      } else if (word == 'True' || word == 'False' || word == 'None') {
        emit(word, EditorHighlightKind.boolean);
      } else {
        emit(word, EditorHighlightKind.plain);
      }
      continue;
    }

    if (_isJsPunct(c)) {
      emit(text.substring(i, i + 1), EditorHighlightKind.punctuation);
      i++;
      continue;
    }

    emit(text.substring(i, i + 1), EditorHighlightKind.plain);
    i++;
  }
}

void _highlightDockerfile(String text, _Emit emit) {
  var i = 0;
  var atLineStart = true;
  while (i < text.length) {
    final c = text.codeUnitAt(i);

    if (c == 0x0A) {
      emit('\n', EditorHighlightKind.plain);
      i++;
      atLineStart = true;
      continue;
    }

    if (atLineStart && (c == 0x20 || c == 0x09)) {
      final start = i;
      while (i < text.length &&
          (text.codeUnitAt(i) == 0x20 || text.codeUnitAt(i) == 0x09)) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.plain);
      continue;
    }

    if (atLineStart && c == 0x23 /* # */) {
      final start = i;
      while (i < text.length && text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.comment);
      continue;
    }

    if (atLineStart && _isIdentStart(c)) {
      final start = i;
      i++;
      while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
        i++;
      }
      final word = text.substring(start, i);
      if (_dockerfileKeywords.contains(word.toUpperCase())) {
        emit(word, EditorHighlightKind.keyword);
      } else {
        emit(word, EditorHighlightKind.plain);
      }
      atLineStart = false;
      continue;
    }

    // Strings
    if (c == 0x27 || c == 0x22) {
      final start = i;
      i = _consumeQuoted(text, i, allowEscape: true);
      emit(text.substring(start, i), EditorHighlightKind.string);
      atLineStart = false;
      continue;
    }

    emit(text.substring(i, i + 1), EditorHighlightKind.plain);
    atLineStart = false;
    i++;
  }
}

void _highlightMarkdown(String text, _Emit emit) {
  var i = 0;
  var atLineStart = true;
  while (i < text.length) {
    final c = text.codeUnitAt(i);

    if (c == 0x0A) {
      emit('\n', EditorHighlightKind.plain);
      i++;
      atLineStart = true;
      continue;
    }

    // Fenced code block ```...```
    if (atLineStart && text.startsWith('```', i)) {
      final start = i;
      i += 3;
      // rest of opening line
      while (i < text.length && text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      if (i < text.length) i++; // newline
      while (i < text.length) {
        if (text.startsWith('```', i)) {
          i += 3;
          while (i < text.length && text.codeUnitAt(i) != 0x0A) {
            i++;
          }
          break;
        }
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.string);
      atLineStart = false;
      continue;
    }

    // Headings: # ... at line start
    if (atLineStart && c == 0x23 /* # */) {
      var j = i;
      while (j < text.length &&
          text.codeUnitAt(j) == 0x23 &&
          j - i < 6) {
        j++;
      }
      if (j < text.length &&
          (text.codeUnitAt(j) == 0x20 || text.codeUnitAt(j) == 0x09)) {
        final start = i;
        while (i < text.length && text.codeUnitAt(i) != 0x0A) {
          i++;
        }
        emit(text.substring(start, i), EditorHighlightKind.keyword);
        atLineStart = false;
        continue;
      }
    }

    // Bold **...** or __...__
    if ((c == 0x2A /* * */ || c == 0x5F /* _ */) &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) == c) {
      final mark = c;
      final start = i;
      i += 2;
      var closed = false;
      while (i < text.length && text.codeUnitAt(i) != 0x0A) {
        if (text.codeUnitAt(i) == mark &&
            i + 1 < text.length &&
            text.codeUnitAt(i + 1) == mark) {
          i += 2;
          closed = true;
          break;
        }
        i++;
      }
      emit(
        text.substring(start, i),
        closed ? EditorHighlightKind.key : EditorHighlightKind.plain,
      );
      atLineStart = false;
      continue;
    }

    // Emit plain until next special or newline
    final start = i;
    while (i < text.length) {
      final cc = text.codeUnitAt(i);
      if (cc == 0x0A) break;
      if (cc == 0x2A || cc == 0x5F) break;
      if (atLineStart && cc == 0x23) break;
      if (atLineStart && text.startsWith('```', i)) break;
      i++;
      atLineStart = false;
    }
    if (i > start) {
      emit(text.substring(start, i), EditorHighlightKind.plain);
    } else {
      emit(text.substring(i, i + 1), EditorHighlightKind.plain);
      i++;
      atLineStart = false;
    }
  }
}

void _highlightIni(String text, _Emit emit) {
  var i = 0;
  var atLineStart = true;
  while (i < text.length) {
    final c = text.codeUnitAt(i);

    if (c == 0x0A) {
      emit('\n', EditorHighlightKind.plain);
      i++;
      atLineStart = true;
      continue;
    }

    if (atLineStart && (c == 0x20 || c == 0x09)) {
      final start = i;
      while (i < text.length &&
          (text.codeUnitAt(i) == 0x20 || text.codeUnitAt(i) == 0x09)) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.plain);
      continue;
    }

    // Comments # or ;
    if (atLineStart && (c == 0x23 /* # */ || c == 0x3B /* ; */)) {
      final start = i;
      while (i < text.length && text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.comment);
      continue;
    }

    // [section]
    if (atLineStart && c == 0x5B /* [ */) {
      final start = i;
      i++;
      while (i < text.length &&
          text.codeUnitAt(i) != 0x5D &&
          text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      if (i < text.length && text.codeUnitAt(i) == 0x5D) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.keyword);
      atLineStart = false;
      continue;
    }

    // key=value
    if (atLineStart) {
      final keyStart = i;
      while (i < text.length) {
        final kc = text.codeUnitAt(i);
        if (kc == 0x0A || kc == 0x3D /* = */) break;
        i++;
      }
      if (i > keyStart) {
        emit(text.substring(keyStart, i), EditorHighlightKind.key);
      }
      if (i < text.length && text.codeUnitAt(i) == 0x3D) {
        emit('=', EditorHighlightKind.punctuation);
        i++;
        final valStart = i;
        while (i < text.length && text.codeUnitAt(i) != 0x0A) {
          i++;
        }
        if (i > valStart) {
          emit(text.substring(valStart, i), EditorHighlightKind.string);
        }
      }
      atLineStart = false;
      continue;
    }

    emit(text.substring(i, i + 1), EditorHighlightKind.plain);
    atLineStart = false;
    i++;
  }
}

void _highlightGo(String text, _Emit emit) {
  var i = 0;
  while (i < text.length) {
    final c = text.codeUnitAt(i);

    if (c == 0x2F /* / */ && i + 1 < text.length) {
      final n = text.codeUnitAt(i + 1);
      if (n == 0x2F) {
        final start = i;
        i += 2;
        while (i < text.length && text.codeUnitAt(i) != 0x0A) {
          i++;
        }
        emit(text.substring(start, i), EditorHighlightKind.comment);
        continue;
      }
      if (n == 0x2A) {
        final start = i;
        i += 2;
        while (i + 1 < text.length &&
            !(text.codeUnitAt(i) == 0x2A && text.codeUnitAt(i + 1) == 0x2F)) {
          i++;
        }
        if (i + 1 < text.length) i += 2;
        emit(text.substring(start, i), EditorHighlightKind.comment);
        continue;
      }
    }

    if (c == 0x27 || c == 0x22 || c == 0x60 /* ` */) {
      final start = i;
      if (c == 0x60) {
        i++;
        while (i < text.length && text.codeUnitAt(i) != 0x60) {
          i++;
        }
        if (i < text.length) i++;
      } else {
        i = _consumeQuoted(text, i, allowEscape: true);
      }
      emit(text.substring(start, i), EditorHighlightKind.string);
      continue;
    }

    if (c == 0x2D /* - */ || (c >= 0x30 && c <= 0x39)) {
      final start = i;
      i = _consumeNumber(text, i);
      emit(text.substring(start, i), EditorHighlightKind.number);
      continue;
    }

    if (_isIdentStart(c)) {
      final start = i;
      i++;
      while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
        i++;
      }
      final word = text.substring(start, i);
      if (_goKeywords.contains(word)) {
        emit(word, EditorHighlightKind.keyword);
      } else if (word == 'true' || word == 'false' || word == 'nil') {
        emit(word, EditorHighlightKind.boolean);
      } else {
        emit(word, EditorHighlightKind.plain);
      }
      continue;
    }

    emit(text.substring(i, i + 1), EditorHighlightKind.plain);
    i++;
  }
}

void _highlightSql(String text, _Emit emit) {
  var i = 0;
  while (i < text.length) {
    final c = text.codeUnitAt(i);

    if (c == 0x2D && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x2D) {
      final start = i;
      i += 2;
      while (i < text.length && text.codeUnitAt(i) != 0x0A) {
        i++;
      }
      emit(text.substring(start, i), EditorHighlightKind.comment);
      continue;
    }

    if (c == 0x2F /* / */ &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) == 0x2A) {
      final start = i;
      i += 2;
      while (i + 1 < text.length &&
          !(text.codeUnitAt(i) == 0x2A && text.codeUnitAt(i + 1) == 0x2F)) {
        i++;
      }
      if (i + 1 < text.length) i += 2;
      emit(text.substring(start, i), EditorHighlightKind.comment);
      continue;
    }

    if (c == 0x27 || c == 0x22) {
      final start = i;
      i = _consumeQuoted(text, i, allowEscape: true);
      emit(text.substring(start, i), EditorHighlightKind.string);
      continue;
    }

    if (c >= 0x30 && c <= 0x39) {
      final start = i;
      i = _consumeNumber(text, i);
      emit(text.substring(start, i), EditorHighlightKind.number);
      continue;
    }

    if (_isIdentStart(c)) {
      final start = i;
      i++;
      while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
        i++;
      }
      final word = text.substring(start, i);
      if (_sqlKeywords.contains(word.toUpperCase())) {
        emit(word, EditorHighlightKind.keyword);
      } else {
        emit(word, EditorHighlightKind.plain);
      }
      continue;
    }

    emit(text.substring(i, i + 1), EditorHighlightKind.plain);
    i++;
  }
}

bool _isHtmlNameStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

bool _isHtmlNameChar(int c) =>
    _isHtmlNameStart(c) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x2D /* - */ ||
    c == 0x3A /* : */;

// --- scanners ----------------------------------------------------------------

int _consumeJsonString(String text, int i) {
  // i points at opening "
  i++;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c == 0x5C /* \ */) {
      i += 2;
      continue;
    }
    if (c == 0x22) {
      return i + 1;
    }
    if (c == 0x0A) return i;
    i++;
  }
  return i;
}

int _consumeQuoted(String text, int i, {required bool allowEscape}) {
  final quote = text.codeUnitAt(i);
  i++;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (allowEscape && c == 0x5C) {
      i += 2;
      continue;
    }
    if (c == quote) return i + 1;
    if (c == 0x0A && quote != 0x60) return i;
    i++;
  }
  return i;
}

int _consumeJsString(String text, int i) {
  final quote = text.codeUnitAt(i);
  i++;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c == 0x5C) {
      i += 2;
      continue;
    }
    if (quote == 0x60 /* ` */ && c == 0x24 && i + 1 < text.length &&
        text.codeUnitAt(i + 1) == 0x7B) {
      // ${ ... } — keep string color through simple brace skip
      i += 2;
      var depth = 1;
      while (i < text.length && depth > 0) {
        final x = text.codeUnitAt(i);
        if (x == 0x7B) depth++;
        if (x == 0x7D) depth--;
        if (x == 0x5C) {
          i += 2;
          continue;
        }
        if (x == 0x27 || x == 0x22) {
          i = _consumeQuoted(text, i, allowEscape: true);
          continue;
        }
        i++;
      }
      continue;
    }
    if (c == quote) return i + 1;
    if (c == 0x0A && quote != 0x60) return i;
    i++;
  }
  return i;
}

int _consumeNumber(String text, int i) {
  if (text.codeUnitAt(i) == 0x2D || text.codeUnitAt(i) == 0x2B) i++;
  while (i < text.length &&
      text.codeUnitAt(i) >= 0x30 &&
      text.codeUnitAt(i) <= 0x39) {
    i++;
  }
  if (i < text.length && text.codeUnitAt(i) == 0x2E /* . */) {
    i++;
    while (i < text.length &&
        text.codeUnitAt(i) >= 0x30 &&
        text.codeUnitAt(i) <= 0x39) {
      i++;
    }
  }
  if (i < text.length &&
      (text.codeUnitAt(i) == 0x65 || text.codeUnitAt(i) == 0x45)) {
    i++;
    if (i < text.length &&
        (text.codeUnitAt(i) == 0x2B || text.codeUnitAt(i) == 0x2D)) {
      i++;
    }
    while (i < text.length &&
        text.codeUnitAt(i) >= 0x30 &&
        text.codeUnitAt(i) <= 0x39) {
      i++;
    }
  }
  return i;
}

int _consumeRegex(String text, int i) {
  // i at /
  i++;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c == 0x0A) return i;
    if (c == 0x5C) {
      i += 2;
      continue;
    }
    if (c == 0x5B) {
      i++;
      while (i < text.length) {
        final cc = text.codeUnitAt(i);
        if (cc == 0x0A) break;
        if (cc == 0x5C) {
          i += 2;
          continue;
        }
        if (cc == 0x5D) {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (c == 0x2F) {
      i++;
      while (i < text.length && _isIdentChar(text.codeUnitAt(i))) {
        i++;
      }
      return i;
    }
    i++;
  }
  return i;
}

int _consumeYamlKey(String text, int i) {
  // Allow letters, digits, _, -, ., /, *
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (_isIdentChar(c) ||
        c == 0x2D ||
        c == 0x2E ||
        c == 0x2F ||
        c == 0x2A) {
      i++;
      continue;
    }
    break;
  }
  return i;
}

bool _atLineStart(String text, int i) {
  if (i == 0) return true;
  final p = text.codeUnitAt(i - 1);
  return p == 0x0A || p == 0x0D;
}

bool _yamlCommentAllowed(String text, int i) {
  if (i == 0) return true;
  final p = text.codeUnitAt(i - 1);
  return p == 0x0A ||
      p == 0x0D ||
      p == 0x20 ||
      p == 0x09;
}

bool _yamlMaybeKeyStart(String text, int i) {
  if (!_isIdentStart(text.codeUnitAt(i)) &&
      text.codeUnitAt(i) != 0x2D &&
      text.codeUnitAt(i) != 0x2E &&
      !(text.codeUnitAt(i) >= 0x30 && text.codeUnitAt(i) <= 0x39)) {
    return false;
  }
  // After indent / list dash / start
  if (i == 0) return true;
  final p = text.codeUnitAt(i - 1);
  if (p == 0x0A || p == 0x0D || p == 0x20 || p == 0x09) return true;
  // after "- "
  if (p == 0x2D) {
    if (i >= 2) {
      final pp = text.codeUnitAt(i - 2);
      if (pp == 0x0A || pp == 0x0D || pp == 0x20 || pp == 0x09 || i == 1) {
        return false; // the dash itself handled elsewhere
      }
    }
  }
  return false;
}

bool _yamlListDash(String text, int i) {
  if (i == 0) return true;
  final p = text.codeUnitAt(i - 1);
  return p == 0x0A || p == 0x0D || p == 0x20 || p == 0x09;
}

bool _canStartRegex(int prev) {
  if (prev == 0) return true;
  const ok = {
    0x28, 0x5B, 0x7B, 0x3D, 0x3A, 0x2C, 0x3B, 0x21, 0x26, 0x7C, 0x3F, 0x2B,
    0x2D, 0x2A, 0x25, 0x5E, 0x7E, 0x3C, 0x3E,
  };
  return ok.contains(prev);
}

bool _isSpace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A;

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x5F;

bool _isIdentChar(int c) =>
    _isIdentStart(c) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x24;

bool _isJsonPunct(int c) =>
    c == 0x7B ||
    c == 0x7D ||
    c == 0x5B ||
    c == 0x5D ||
    c == 0x3A ||
    c == 0x2C;

bool _isJsPunct(int c) =>
    c == 0x7B ||
    c == 0x7D ||
    c == 0x5B ||
    c == 0x5D ||
    c == 0x28 ||
    c == 0x29 ||
    c == 0x3B ||
    c == 0x2C ||
    c == 0x2E ||
    c == 0x3A ||
    c == 0x3F ||
    c == 0x21 ||
    c == 0x3D ||
    c == 0x3C ||
    c == 0x3E ||
    c == 0x2B ||
    c == 0x2D ||
    c == 0x2A ||
    c == 0x25 ||
    c == 0x26 ||
    c == 0x7C ||
    c == 0x5E ||
    c == 0x7E;

const _jsKeywords = {
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'debugger',
  'default',
  'delete',
  'do',
  'else',
  'export',
  'extends',
  'finally',
  'for',
  'function',
  'if',
  'import',
  'in',
  'instanceof',
  'let',
  'new',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'try',
  'typeof',
  'var',
  'void',
  'while',
  'with',
  'yield',
  'async',
  'await',
  'of',
  'static',
  'get',
  'set',
  'from',
  'as',
};

const _bashKeywords = {
  'if',
  'then',
  'else',
  'elif',
  'fi',
  'case',
  'esac',
  'for',
  'while',
  'until',
  'select',
  'do',
  'done',
  'in',
  'function',
  'time',
  'coproc',
  'export',
  'local',
  'return',
  'exit',
  'shift',
  'source',
  'declare',
  'readonly',
  'unset',
  'typeset',
};

const _pythonKeywords = {
  'and',
  'as',
  'assert',
  'async',
  'await',
  'break',
  'class',
  'continue',
  'def',
  'del',
  'elif',
  'else',
  'except',
  'finally',
  'for',
  'from',
  'global',
  'if',
  'import',
  'in',
  'is',
  'lambda',
  'nonlocal',
  'not',
  'or',
  'pass',
  'raise',
  'return',
  'try',
  'while',
  'with',
  'yield',
};

const _dockerfileKeywords = {
  'FROM',
  'RUN',
  'CMD',
  'ENTRYPOINT',
  'COPY',
  'ADD',
  'WORKDIR',
  'ENV',
  'EXPOSE',
  'USER',
  'VOLUME',
  'LABEL',
  'ARG',
  'ONBUILD',
  'STOPSIGNAL',
  'HEALTHCHECK',
  'SHELL',
  'MAINTAINER',
};

const _goKeywords = {
  'break',
  'case',
  'chan',
  'const',
  'continue',
  'default',
  'defer',
  'else',
  'fallthrough',
  'for',
  'func',
  'go',
  'goto',
  'if',
  'import',
  'interface',
  'map',
  'package',
  'range',
  'return',
  'select',
  'struct',
  'switch',
  'type',
  'var',
};

const _sqlKeywords = {
  'SELECT',
  'FROM',
  'WHERE',
  'AND',
  'OR',
  'NOT',
  'INSERT',
  'INTO',
  'VALUES',
  'UPDATE',
  'SET',
  'DELETE',
  'CREATE',
  'TABLE',
  'DROP',
  'ALTER',
  'INDEX',
  'JOIN',
  'LEFT',
  'RIGHT',
  'INNER',
  'OUTER',
  'ON',
  'AS',
  'ORDER',
  'BY',
  'GROUP',
  'HAVING',
  'LIMIT',
  'OFFSET',
  'DISTINCT',
  'NULL',
  'TRUE',
  'FALSE',
  'IN',
  'IS',
  'LIKE',
  'BETWEEN',
  'EXISTS',
  'UNION',
  'ALL',
  'PRIMARY',
  'KEY',
  'FOREIGN',
  'REFERENCES',
  'CONSTRAINT',
  'DEFAULT',
  'CASCADE',
  'WITH',
};
