import 'dart:async';
import 'dart:math' as math;

/// Drops PTY local-echo of a just-injected command from the display stream.
///
/// Remote line discipline still echoes typed bytes; we strip that echo on the
/// client so shell-integration snippets can be injected without flashing in the
/// terminal UI. OSC / command *output* is not part of [arm]'s payload and is
/// left untouched.
class InjectEchoSuppressor {
  final StringBuffer _hold = StringBuffer();
  String _needle = '';
  Timer? _timeout;

  bool get isActive => _needle.isNotEmpty;

  /// Expect the next stdout to locally-echo [echoedPayload]; strip the first
  /// occurrence (CR/LF tolerant).
  void arm(
    String echoedPayload, {
    Duration timeout = const Duration(seconds: 2),
  }) {
    clear();
    _needle = _normalizeNewlines(echoedPayload);
    if (_needle.isEmpty) return;
    _timeout = Timer(timeout, clear);
  }

  void clear() {
    _timeout?.cancel();
    _timeout = null;
    _needle = '';
    _hold.clear();
  }

  /// Remove armed echo from [input]; pass through everything else.
  String filter(String input) {
    if (_needle.isEmpty) return input;
    if (input.isEmpty && _hold.isEmpty) return input;

    _hold.write(_normalizeNewlines(input));
    final buf = _hold.toString();
    final idx = buf.indexOf(_needle);
    if (idx >= 0) {
      final out =
          buf.substring(0, idx) + buf.substring(idx + _needle.length);
      clear();
      return out;
    }

    // Echo not complete — emit only bytes that cannot be a prefix of needle.
    final keep = _suffixPrefixLength(buf, _needle);
    final emit = buf.substring(0, buf.length - keep);
    _hold
      ..clear()
      ..write(buf.substring(buf.length - keep));
    return emit;
  }

  /// Collapse CR/LF so PTY echo of `\n` as `\r\n` still matches.
  static String _normalizeNewlines(String s) =>
      s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  /// How many trailing chars of [s] are a prefix of [needle].
  static int _suffixPrefixLength(String s, String needle) {
    final max = math.min(s.length, needle.length);
    for (var len = max; len > 0; len--) {
      if (needle.startsWith(s.substring(s.length - len))) return len;
    }
    return 0;
  }
}
