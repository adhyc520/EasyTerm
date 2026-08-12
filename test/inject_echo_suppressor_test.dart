import 'package:easyterm/services/inject_echo_suppressor.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InjectEchoSuppressor', () {
    test('strips exact echo and keeps trailing output', () {
      final s = InjectEchoSuppressor();
      s.arm('hello\n');
      expect(s.filter('hello\n(world)'), '(world)');
      expect(s.isActive, isFalse);
    });

    test('strips across chunks', () {
      final s = InjectEchoSuppressor();
      s.arm('abcdef');
      expect(s.filter('abc'), isEmpty);
      expect(s.isActive, isTrue);
      expect(s.filter('defPROMPT'), 'PROMPT');
      expect(s.isActive, isFalse);
    });

    test('tolerates CR before LF echo', () {
      final s = InjectEchoSuppressor();
      s.arm('cmd\n');
      expect(s.filter('cmd\r\nok'), 'ok');
    });

    test('passes banner before echo starts', () {
      final s = InjectEchoSuppressor();
      s.arm('if [ -n');
      expect(s.filter('Last login\nif [ -n'), 'Last login\n');
      expect(s.isActive, isFalse);
    });

    test('timeout clears leftover suppress', () {
      fakeAsync((async) {
        final s = InjectEchoSuppressor();
        s.arm('long-snippet', timeout: const Duration(seconds: 2));
        expect(s.filter('lon'), isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(s.isActive, isFalse);
        expect(s.filter('g-snippetX'), 'g-snippetX');
      });
    });
  });
}
