/// Scans PTY stdout between the SSH stream and [Terminal.write].
///
/// - OSC 7 (`ESC ] 7 ; file://… BEL/ST`) → [onCwd]
/// - Mouse reporting CSI (`ESC [ ? 1000/1002/1003 h|l`) → [onMouseMode]
///   Encoding modes 1006/1015 are tracked but do not alone enable reporting.
///
/// All bytes are passed through unchanged (xterm ignores OSC 7).
class PtyInterceptor {
  PtyInterceptor({this.onCwd, this.onMouseMode});

  final void Function(String cwd)? onCwd;
  final void Function(bool active)? onMouseMode;

  /// Incomplete escape sequence carried across chunks.
  final StringBuffer _pending = StringBuffer();

  /// Active DEC private modes we care about (tracking + encoding).
  final Set<int> _modes = {};

  /// Modes that mean the app is consuming mouse events (vs encoding only).
  static const Set<int> _trackingModes = {1000, 1002, 1003};

  /// Encoding / protocol variants kept for accurate enable/disable bookkeeping.
  static const Set<int> _encodingModes = {1006, 1015};

  static const Set<int> _watchedModes = {..._trackingModes, ..._encodingModes};

  bool get mouseMode => _modes.any(_trackingModes.contains);

  /// Feed decoded stdout; return the same content for [Terminal.write].
  String process(String input) {
    if (input.isEmpty && _pending.isEmpty) return input;

    final src = _pending.isEmpty ? input : '$_pending$input';
    _pending.clear();

    final out = StringBuffer();
    var i = 0;
    while (i < src.length) {
      final c = src.codeUnitAt(i);
      if (c != 0x1B) {
        // Fast path: copy run of non-ESC bytes.
        final start = i;
        i++;
        while (i < src.length && src.codeUnitAt(i) != 0x1B) {
          i++;
        }
        out.write(src.substring(start, i));
        continue;
      }

      // ESC at end of chunk — wait for more.
      if (i + 1 >= src.length) {
        _pending.write(src.substring(i));
        break;
      }

      final next = src.codeUnitAt(i + 1);
      if (next == 0x5D /* ] */) {
        final consumed = _tryOsc(src, i, out);
        if (consumed < 0) {
          _pending.write(src.substring(i));
          break;
        }
        i += consumed;
        continue;
      }
      if (next == 0x5B /* [ */) {
        final consumed = _tryCsi(src, i, out);
        if (consumed < 0) {
          _pending.write(src.substring(i));
          break;
        }
        i += consumed;
        continue;
      }

      // Other ESC sequences: pass through one ESC and continue.
      out.writeCharCode(c);
      i++;
    }

    return out.toString();
  }

  /// Returns bytes consumed from [i], or -1 if incomplete.
  int _tryOsc(String src, int i, StringBuffer out) {
    // ESC ] … BEL | ESC \
    var j = i + 2;
    while (j < src.length) {
      final c = src.codeUnitAt(j);
      if (c == 0x07 /* BEL */) {
        final body = src.substring(i + 2, j);
        _handleOscBody(body);
        out.write(src.substring(i, j + 1));
        return j + 1 - i;
      }
      if (c == 0x1B && j + 1 < src.length && src.codeUnitAt(j + 1) == 0x5C) {
        final body = src.substring(i + 2, j);
        _handleOscBody(body);
        out.write(src.substring(i, j + 2));
        return j + 2 - i;
      }
      // Guard runaway OSC (no terminator).
      if (j - i > 8192) {
        out.write(src.substring(i, j));
        return j - i;
      }
      j++;
    }
    return -1;
  }

  void _handleOscBody(String body) {
    // "7;file://…"
    if (!body.startsWith('7;')) return;
    final uriPart = body.substring(2);
    final cwd = parseOsc7FileUri(uriPart);
    if (cwd != null && cwd.isNotEmpty) {
      onCwd?.call(cwd);
    }
  }

  /// Returns bytes consumed from [i], or -1 if incomplete.
  int _tryCsi(String src, int i, StringBuffer out) {
    // ESC [ ? <digits>(;<digits>)* h|l   or other CSI — scan to final byte.
    var j = i + 2;
    while (j < src.length) {
      final c = src.codeUnitAt(j);
      // CSI final bytes are 0x40–0x7E.
      if (c >= 0x40 && c <= 0x7E) {
        final seq = src.substring(i, j + 1);
        _handleCsi(seq);
        out.write(seq);
        return j + 1 - i;
      }
      if (j - i > 256) {
        out.write(src.substring(i, j));
        return j - i;
      }
      j++;
    }
    return -1;
  }

  void _handleCsi(String seq) {
    // ESC [ ? 1000 ; 1003 h
    if (seq.length < 5) return;
    if (seq.codeUnitAt(2) != 0x3F /* ? */) return;
    final finalByte = seq.codeUnitAt(seq.length - 1);
    if (finalByte != 0x68 /* h */ && finalByte != 0x6C /* l */) return;

    final params = seq.substring(3, seq.length - 1);
    final enable = finalByte == 0x68;
    final wasActive = mouseMode;
    for (final part in params.split(';')) {
      final n = int.tryParse(part.trim());
      if (n == null || !_watchedModes.contains(n)) continue;
      if (enable) {
        _modes.add(n);
      } else {
        _modes.remove(n);
      }
    }
    final nowActive = mouseMode;
    if (nowActive != wasActive) {
      onMouseMode?.call(nowActive);
    }
  }

  /// Reset pending buffer and mouse mode (e.g. on reconnect).
  void reset() {
    _pending.clear();
    final wasActive = mouseMode;
    _modes.clear();
    if (wasActive) {
      onMouseMode?.call(false);
    }
  }
}

/// Parse `file://host/path` or `file:///path` into a Unix absolute path.
///
/// Returns null if [uriPart] is not a `file://` URL.
String? parseOsc7FileUri(String uriPart) {
  final trimmed = uriPart.trim();
  if (trimmed.isEmpty) return null;

  Uri uri;
  try {
    uri = Uri.parse(trimmed);
  } catch (_) {
    return null;
  }
  if (uri.scheme != 'file') return null;

  var path = uri.path;
  if (path.isEmpty) return null;

  // Uri.parse('file://host/var/log') → path=/var/log
  // Uri.parse('file:///var/log') → path=/var/log
  // Uri.parse('file://localhost/home/x') → path=/home/x
  try {
    path = Uri.decodeFull(path);
  } catch (_) {
    // Keep raw path if decode fails.
  }

  if (!path.startsWith('/')) {
    path = '/$path';
  }
  return path;
}
