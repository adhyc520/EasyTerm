import 'package:easyterm/services/pty_interceptor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseOsc7FileUri', () {
    test('host path', () {
      expect(parseOsc7FileUri('file://host/var/log'), '/var/log');
    });

    test('localhost', () {
      expect(parseOsc7FileUri('file://localhost/home/x'), '/home/x');
    });

    test('triple slash', () {
      expect(parseOsc7FileUri('file:///tmp'), '/tmp');
    });

    test('percent encode', () {
      expect(parseOsc7FileUri('file://host/My%20Dir'), '/My Dir');
    });

    test('non-file rejected', () {
      expect(parseOsc7FileUri('https://example.com/x'), isNull);
    });
  });

  group('PtyInterceptor OSC 7', () {
    test('complete BEL', () {
      String? cwd;
      final p = PtyInterceptor(onCwd: (c) => cwd = c);
      final out = p.process('\x1b]7;file://host/var/log\x07');
      expect(cwd, '/var/log');
      expect(out, '\x1b]7;file://host/var/log\x07');
    });

    test('ST terminator', () {
      String? cwd;
      final p = PtyInterceptor(onCwd: (c) => cwd = c);
      p.process('\x1b]7;file://host/x\x1b\\');
      expect(cwd, '/x');
    });

    test('split across chunks', () {
      String? cwd;
      final p = PtyInterceptor(onCwd: (c) => cwd = c);
      expect(p.process('\x1b]7;file://host/va'), '');
      expect(cwd, isNull);
      final out = p.process('r/log\x07hello');
      expect(cwd, '/var/log');
      expect(out, '\x1b]7;file://host/var/log\x07hello');
    });

    test('ignores OSC 0 title', () {
      var called = false;
      final p = PtyInterceptor(onCwd: (_) => called = true);
      p.process('\x1b]0;title\x07');
      expect(called, isFalse);
    });

    test('plain text and colors pass through', () {
      final p = PtyInterceptor();
      const s = 'hello\x1b[31m红\x1b[0m';
      expect(p.process(s), s);
    });
  });

  group('PtyInterceptor mouse mode', () {
    test('1003h / 1003l', () {
      final modes = <bool>[];
      final p = PtyInterceptor(onMouseMode: modes.add);
      p.process('\x1b[?1003h');
      expect(p.mouseMode, isTrue);
      expect(modes, [true]);
      p.process('\x1b[?1003l');
      expect(p.mouseMode, isFalse);
      expect(modes, [true, false]);
    });

    test('split CSI', () {
      final modes = <bool>[];
      final p = PtyInterceptor(onMouseMode: modes.add);
      p.process('\x1b[?10');
      expect(p.mouseMode, isFalse);
      p.process('03h');
      expect(p.mouseMode, isTrue);
      expect(modes, [true]);
    });

    test('1000 and 1006', () {
      final p = PtyInterceptor();
      p.process('\x1b[?1000h');
      expect(p.mouseMode, isTrue);
      p.process('\x1b[?1000l');
      expect(p.mouseMode, isFalse);
      // 1006 alone is encoding, not tracking — must stay inactive.
      p.process('\x1b[?1006h');
      expect(p.mouseMode, isFalse);
    });

    test('disabling one tracking mode keeps others', () {
      final modes = <bool>[];
      final p = PtyInterceptor(onMouseMode: modes.add);
      p.process('\x1b[?1000;1002;1006h');
      expect(p.mouseMode, isTrue);
      expect(modes, [true]);
      p.process('\x1b[?1000l');
      expect(p.mouseMode, isTrue);
      expect(modes, [true]);
      p.process('\x1b[?1002l');
      expect(p.mouseMode, isFalse);
      expect(modes, [true, false]);
    });
  });
}
