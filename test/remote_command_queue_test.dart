import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:easyterm/services/remote_command_queue.dart';

void main() {
  group('RemoteCommandQueue', () {
    test('caps concurrency and queues the rest', () async {
      var concurrent = 0;
      var maxSeen = 0;
      var runCount = 0;

      final q = RemoteCommandQueue.test(
        (cmd, timeout) async {
          runCount++;
          concurrent++;
          if (concurrent > maxSeen) maxSeen = concurrent;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          concurrent--;
          return 'ok:$cmd';
        },
        maxConcurrent: 2,
      );

      final f1 = q.run('a');
      final f2 = q.run('b');
      final f3 = q.run('c');

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(q.inFlight, 2);
      expect(q.pendingCount, 1);

      final results = await Future.wait([f1, f2, f3]);
      expect(results, ['ok:a', 'ok:b', 'ok:c']);
      expect(maxSeen, 2);
      expect(runCount, 3);
      q.dispose();
    });

    test('returns null when disconnected', () async {
      final q = RemoteCommandQueue(() => null, maxConcurrent: 2);
      final out = await q.run('echo hi');
      expect(out, isNull);
      q.dispose();
    });

    test('clearPending completes queued with null', () async {
      final gate = Completer<void>();
      final q = RemoteCommandQueue.test(
        (cmd, timeout) async {
          await gate.future;
          return 'ok';
        },
        maxConcurrent: 1,
      );
      final a = q.run('a');
      final b = q.run('b');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(q.pendingCount, 1);
      q.clearPending();
      expect(q.pendingCount, 0);
      expect(await b, isNull);
      gate.complete();
      expect(await a, 'ok');
      q.dispose();
    });

    test('dispose completes pending with null', () async {
      final q = RemoteCommandQueue.test(
        (cmd, timeout) async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return 'late';
        },
        maxConcurrent: 1,
      );
      final a = q.run('a');
      final b = q.run('b');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      q.dispose();
      expect(await b, isNull);
      // in-flight may still complete
      expect(await a, anyOf(isNull, 'late'));
    });
  });
}
