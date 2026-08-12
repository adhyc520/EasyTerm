import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

/// A single match in the terminal buffer text (char offsets as in [Buffer.getText]).
@immutable
class TerminalMatch {
  const TerminalMatch({required this.start, required this.length});

  final int start;
  final int length;

  int get end => start + length;
}

/// Searches terminal buffer lines with case / regex options and next/prev navigation.
///
/// xterm 4.0 has no public [Terminal.search] API — walks [Buffer.getText] offsets.
class TerminalSearchController extends ChangeNotifier {
  TerminalSearchController(this.terminal);

  Terminal terminal;

  String _query = '';
  bool _caseSensitive = false;
  bool _regex = false;
  bool _regexInvalid = false;
  List<TerminalMatch> _matches = const [];
  int _index = -1;

  String get query => _query;
  bool get caseSensitive => _caseSensitive;
  bool get regex => _regex;
  bool get regexInvalid => _regexInvalid;
  List<TerminalMatch> get matches => _matches;
  int get index => _index;
  int get matchCount => _matches.length;
  TerminalMatch? get current =>
      (_index >= 0 && _index < _matches.length) ? _matches[_index] : null;

  void setTerminal(Terminal value) {
    if (identical(terminal, value)) return;
    terminal = value;
    rebuild();
  }

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    rebuild();
  }

  void setCaseSensitive(bool value) {
    if (_caseSensitive == value) return;
    _caseSensitive = value;
    rebuild();
  }

  void setRegex(bool value) {
    if (_regex == value) return;
    _regex = value;
    rebuild();
  }

  void rebuild() {
    _matches = search(
      terminal,
      _query,
      caseSensitive: _caseSensitive,
      regex: _regex,
    );
    _regexInvalid = _regex && _query.isNotEmpty && _matches.isEmpty
        ? !_isValidRegex(_query)
        : false;
    if (_matches.isEmpty) {
      _index = -1;
    } else if (_index < 0 || _index >= _matches.length) {
      _index = 0;
    }
    notifyListeners();
  }

  /// Returns match char offsets for [pattern] in [term]'s buffer text.
  static List<TerminalMatch> search(
    Terminal term,
    String pattern, {
    bool caseSensitive = false,
    bool regex = false,
  }) {
    if (pattern.isEmpty) return const [];
    final text = term.buffer.getText();
    if (text.isEmpty) return const [];

    if (regex) {
      try {
        final re = RegExp(
          pattern,
          caseSensitive: caseSensitive,
          multiLine: true,
        );
        final out = <TerminalMatch>[];
        for (final m in re.allMatches(text)) {
          if (m.end > m.start) {
            out.add(TerminalMatch(start: m.start, length: m.end - m.start));
          }
        }
        return out;
      } on FormatException {
        return const [];
      }
    }

    final haystack = caseSensitive ? text : text.toLowerCase();
    final needle = caseSensitive ? pattern : pattern.toLowerCase();
    final out = <TerminalMatch>[];
    var from = 0;
    while (true) {
      final i = haystack.indexOf(needle, from);
      if (i < 0) break;
      out.add(TerminalMatch(start: i, length: pattern.length));
      from = i + 1;
    }
    return out;
  }

  void navigateNext({bool reverse = false}) {
    if (_matches.isEmpty) {
      rebuild();
      if (_matches.isEmpty) return;
    }
    if (reverse) {
      _index = (_index - 1 + _matches.length) % _matches.length;
    } else {
      _index = (_index + 1) % _matches.length;
    }
    notifyListeners();
  }

  void clear() {
    _query = '';
    _matches = const [];
    _index = -1;
    _regexInvalid = false;
    notifyListeners();
  }

  static bool _isValidRegex(String pattern) {
    try {
      RegExp(pattern);
      return true;
    } on FormatException {
      return false;
    }
  }
}
