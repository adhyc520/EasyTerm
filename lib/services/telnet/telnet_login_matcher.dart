import 'dart:convert';

/// Matches classic Telnet login prompts and injects credentials.
class TelnetLoginMatcher {
  TelnetLoginMatcher({
    required this.username,
    required this.password,
    this.enabled = true,
    Encoding encoding = const Utf8Codec(allowMalformed: true),
  })  : _encoding = encoding,
        // Password-only consoles never show a username prompt.
        _userSent = username.isEmpty;

  final String username;
  final String password;
  final bool enabled;
  final Encoding _encoding;

  final StringBuffer _window = StringBuffer();
  static const int _maxWindow = 512;

  bool _userSent;
  bool _passSent = false;
  bool _sawLoginPrompt = false;
  bool _sawPasswordPrompt = false;

  /// True after a login or password prompt was observed.
  bool get sawCredentialPrompt => _sawLoginPrompt || _sawPasswordPrompt;

  /// Credentials have been injected (or inject is disabled / empty).
  bool get injectComplete =>
      !enabled ||
      (username.isEmpty && password.isEmpty) ||
      (_userSent && (password.isEmpty || _passSent));

  /// Alias for [injectComplete] (legacy callers).
  bool get done => injectComplete;

  /// Whether auto-inject has credentials to send.
  bool get hasCredentials =>
      enabled && (username.isNotEmpty || password.isNotEmpty);

  /// Feed decoded display text; returns bytes to send (may be empty).
  List<int> feedText(String text) {
    if (text.isEmpty) return const [];
    _window.write(text);
    var s = _window.toString();
    if (s.length > _maxWindow) {
      s = s.substring(s.length - _maxWindow);
      _window
        ..clear()
        ..write(s);
    }
    final plain = _stripAnsi(s).toLowerCase();
    if (_looksLikeLoginPrompt(plain)) _sawLoginPrompt = true;
    if (_looksLikePasswordPrompt(plain)) _sawPasswordPrompt = true;

    if (!enabled || injectComplete) return const [];
    final out = <int>[];

    if (!_userSent && username.isNotEmpty) {
      if (_sawLoginPrompt || _looksLikeLoginPrompt(plain)) {
        _userSent = true;
        out.addAll(_encoding.encode('$username\r'));
      }
    }
    if (_userSent && !_passSent && password.isNotEmpty) {
      if (_sawPasswordPrompt || _looksLikePasswordPrompt(plain)) {
        _passSent = true;
        out.addAll(_encoding.encode('$password\r'));
      }
    }
    return out;
  }

  /// Rough shell-prompt detection for readiness (exec / secondary shell).
  static bool looksLikeShellPrompt(String text) {
    if (text.isEmpty) return false;
    final lines = text.split(RegExp(r'[\r\n]+'));
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i].trimRight();
      if (line.isEmpty) continue;
      // Strip crude ANSI CSI sequences for matching.
      final plain = line.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '');
      final t = plain.trimRight();
      if (t.isEmpty) continue;
      if (RegExp(r'[\$#%>]\s*$').hasMatch(t)) return true;
      if (RegExp(r'\[[^\]]+\][\$#]\s*$').hasMatch(t)) return true;
      return false;
    }
    return false;
  }

  static String _stripAnsi(String text) {
    return text
        .replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '')
        .replaceAll(RegExp(r'\x1B\][^\x07]*\x07'), '')
        .replaceAll(RegExp(r'\x1B.'), '');
  }

  /// Last non-empty line, or the whole buffer when it has no newlines yet.
  static String _tailLine(String lower) {
    final lines = lower.split(RegExp(r'[\r\n]+'));
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i].trimRight();
      if (line.trim().isNotEmpty) return line;
    }
    return lower.trimRight();
  }

  static bool _looksLikeLoginPrompt(String lower) {
    // Require the prompt at end-of-line so MOTD prose like
    // "invalid login: see admin" (text after colon) does not match.
    // Allow prefixes: "Please login:", "host login:", ANSI-stripped colors.
    final tail = _tailLine(lower).trimRight();
    return RegExp(r'(^|.*\s)(login|user(\s*name)?)\s*:\s*$').hasMatch(tail);
  }

  static bool _looksLikePasswordPrompt(String lower) {
    // End-anchored so "Change your password: see docs" does not match.
    // Allow prefixes: "root's password:", "Password for alice:".
    final tail = _tailLine(lower).trimRight();
    return RegExp(r'pass(word|wd)?\s*:\s*$').hasMatch(tail);
  }

  void reset() {
    _window.clear();
    _userSent = username.isEmpty;
    _passSent = false;
    _sawLoginPrompt = false;
    _sawPasswordPrompt = false;
  }
}

/// Wait until a Telnet session is ready for command injection.
///
/// - With auto-inject + credentials: wait for [TelnetLoginMatcher.injectComplete],
///   or proceed if no credential prompt appears but a shell prompt does.
/// - Abort only when a credential prompt was seen but inject never finished.
/// - With auto-inject off: wait for a shell prompt (or settle timeout).
Future<bool> waitForTelnetReady({
  required TelnetLoginMatcher login,
  required bool Function() isAlive,
  required bool Function() sawShellPrompt,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (!isAlive()) return false;
    if (login.hasCredentials) {
      if (login.injectComplete) return true;
      if (!login.sawCredentialPrompt && sawShellPrompt()) return true;
    } else if (sawShellPrompt()) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (!isAlive()) return false;
  if (login.hasCredentials &&
      login.sawCredentialPrompt &&
      !login.injectComplete) {
    return false;
  }
  // Timeout with no (or incomplete-without-prompt) login: best-effort ready.
  return true;
}
