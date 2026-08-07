import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easyterm/services/remote_stream.dart';

void main() {
  group('RemoteStream', () {
    test('joins half-lines across chunks', () {
      final s = RemoteStream.forTest();
      var notifies = 0;
      s.addListener(() => notifies++);

      s.injectChunk('hel');
      s.injectChunk('lo\nwor');
      s.injectChunk('ld\n');

      expect(s.lines, ['hello', 'world']);
      expect(notifies, greaterThanOrEqualTo(3));
    });

    test('trims ring buffer beyond maxLines', () {
      final s = RemoteStream.forTest(maxLines: 3);
      s.injectChunk('a\nb\nc\nd\ne\n');
      expect(s.lines, ['c', 'd', 'e']);
    });

    test('stop closes and markDone flushes pending', () async {
      final s = RemoteStream.forTest();
      s.injectChunk('partial');
      s.markDone(exitCode: 0);
      expect(s.lines, ['partial']);
      expect(s.closed, isTrue);
      expect(s.exitCode, 0);

      final s2 = RemoteStream.forTest();
      s2.injectChunk('x\n');
      await s2.stop();
      expect(s2.closed, isTrue);
      // stop 后再注入应被忽略
      s2.injectChunk('y\n');
      expect(s2.lines, ['x']);
    });
  });
}
