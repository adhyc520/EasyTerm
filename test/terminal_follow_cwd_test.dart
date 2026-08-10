import 'dart:async';

import 'package:easyterm/services/pty_interceptor.dart';
import 'package:easyterm/util/remote_paths.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lightweight stand-in for follow-cwd debounce / manual-priority logic.
class _FollowCwdLogic {
  _FollowCwdLogic({this.follow = false});

  bool follow;
  String remoteCwd = '/';
  String terminalCwd = '/';
  DateTime? lastManualNavAt;
  int navigateCount = 0;
  String? lastNavigated;
  Timer? _debounce;

  void markManual() => lastManualNavAt = DateTime.now();

  bool get manualRecent {
    final at = lastManualNavAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < const Duration(milliseconds: 1500);
  }

  void onTerminalCwd(String cwd) {
    final norm = normalizeRemotePath(cwd);
    if (norm == terminalCwd) return;
    terminalCwd = norm;
    if (follow) scheduleSync();
  }

  void scheduleSync() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _debounce = null;
      sync();
    });
  }

  void sync() {
    if (!follow) return;
    if (manualRecent) return;
    if (normalizeRemotePathForCompare(terminalCwd) ==
        normalizeRemotePathForCompare(remoteCwd)) {
      return;
    }
    navigateCount++;
    lastNavigated = terminalCwd;
    remoteCwd = terminalCwd;
  }

  void dispose() {
    _debounce?.cancel();
  }
}

void main() {
  group('follow terminal cwd logic', () {
    test('follows when enabled after debounce', () {
      fakeAsync((async) {
        final logic = _FollowCwdLogic(follow: true);
        logic.onTerminalCwd('/var/log');
        expect(logic.navigateCount, 0);
        async.elapse(const Duration(milliseconds: 400));
        expect(logic.remoteCwd, '/var/log');
        expect(logic.navigateCount, 1);
        logic.dispose();
      });
    });

    test('rapid cwd changes coalesce to one navigate', () {
      fakeAsync((async) {
        final logic = _FollowCwdLogic(follow: true);
        logic.onTerminalCwd('/a');
        async.elapse(const Duration(milliseconds: 100));
        logic.onTerminalCwd('/b');
        async.elapse(const Duration(milliseconds: 100));
        logic.onTerminalCwd('/c');
        expect(logic.navigateCount, 0);
        async.elapse(const Duration(milliseconds: 400));
        expect(logic.remoteCwd, '/c');
        expect(logic.navigateCount, 1);
        logic.dispose();
      });
    });

    test('ignores when disabled', () {
      fakeAsync((async) {
        final logic = _FollowCwdLogic(follow: false);
        logic.onTerminalCwd('/var/log');
        async.elapse(const Duration(milliseconds: 400));
        expect(logic.remoteCwd, '/');
        expect(logic.navigateCount, 0);
        expect(logic.terminalCwd, '/var/log');
        logic.dispose();
      });
    });

    test('manual priority blocks follow', () {
      fakeAsync((async) {
        final logic = _FollowCwdLogic(follow: true)..markManual();
        logic.onTerminalCwd('/tmp');
        async.elapse(const Duration(milliseconds: 400));
        expect(logic.remoteCwd, '/');
        expect(logic.navigateCount, 0);
        logic.dispose();
      });
    });

    test('same directory does not re-navigate', () {
      fakeAsync((async) {
        final logic = _FollowCwdLogic(follow: true)
          ..remoteCwd = '/home/x'
          ..terminalCwd = '/home/x';
        logic.onTerminalCwd('/home/x');
        async.elapse(const Duration(milliseconds: 400));
        expect(logic.navigateCount, 0);
        logic.dispose();
      });
    });
  });

  group('OSC 7 feeds follow source', () {
    test('interceptor cwd drives path', () {
      String? cwd;
      final p = PtyInterceptor(onCwd: (c) => cwd = c);
      p.process('\x1b]7;file://host/opt/app\x07');
      expect(cwd, '/opt/app');
      expect(normalizeRemotePath(cwd!), '/opt/app');
    });
  });
}
