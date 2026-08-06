import 'package:easyterm/services/browser_gateway_rewrite.dart';
import 'package:easyterm/services/desktop_layout_store.dart';
import 'package:easyterm/services/remote_browser_backend.dart';
import 'package:easyterm/services/remote_host_metrics.dart';
import 'package:easyterm/services/remote_process_list.dart';
import 'package:easyterm/util/remote_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('parseBrowserAddressBar', () {
    test('empty defaults to localhost:80', () {
      final t = parseBrowserAddressBar('');
      expect(t.host, 'localhost');
      expect(t.port, 80);
      expect(t.pathAndQuery, '/');
      expect(t.https, isFalse);
    });

    test('host:port/path', () {
      final t = parseBrowserAddressBar('localhost:3000/app');
      expect(t.host, 'localhost');
      expect(t.port, 3000);
      expect(t.pathAndQuery, '/app');
      expect(t.https, isFalse);
    });

    test('https absolute URL', () {
      final t = parseBrowserAddressBar('https://svc.internal:8443/x?q=1');
      expect(t.host, 'svc.internal');
      expect(t.port, 8443);
      expect(t.pathAndQuery, '/x?q=1');
      expect(t.https, isTrue);
    });

    test('port 443 implies https flag', () {
      final t = parseBrowserAddressBar('http://box:443/');
      expect(t.port, 443);
      expect(t.https, isTrue);
    });
  });

  group('gateway rewrite', () {
    test('buildGatewayNavigationUri encodes host and https flag', () {
      final u = buildGatewayNavigationUri(
        gatewayPort: 9,
        token: 'abc',
        remoteHost: 'svc.internal',
        remotePort: 8443,
        pathAndQuery: '/api?x=1',
        https: true,
      );
      expect(u.host, '127.0.0.1');
      expect(u.port, 9);
      expect(u.pathSegments.take(3).toList(), ['abc', 'svc.internal', '8443']);
      expect(u.queryParameters[kGatewaySchemeQueryKey], 'https');
      expect(u.queryParameters['x'], '1');
    });

    test('rewriteRemoteAbsoluteUrl http and protocol-relative', () {
      final http = rewriteRemoteAbsoluteUrl(
        'http://db:5432/health',
        gatewayPort: 9,
        token: 'tok',
      );
      expect(http, contains('127.0.0.1:9/tok/db/5432/health'));
      expect(http, isNot(contains(kGatewaySchemeQueryKey)));

      final https = rewriteRemoteAbsoluteUrl(
        'https://db/health',
        gatewayPort: 9,
        token: 'tok',
      );
      expect(https, contains('/tok/db/443/health'));
      expect(https, contains('$kGatewaySchemeQueryKey=https'));

      final proto = rewriteRemoteAbsoluteUrl(
        '//cdn.internal/a.js',
        gatewayPort: 9,
        token: 'tok',
      );
      expect(proto, contains('/tok/cdn.internal/80/a.js'));

      expect(
        rewriteRemoteAbsoluteUrl('/relative', gatewayPort: 9, token: 'tok'),
        isNull,
      );
    });

    test('rewriteGatewayResponseBody rewrites attrs and injects shim', () {
      const html = '''
<html><head><title>t</title></head>
<body>
<a href="http://api:8080/v1">link</a>
<div style="background:url(https://cdn/x.png)"></div>
</body></html>
''';
      final out = rewriteGatewayResponseBody(
        html,
        gatewayPort: 9,
        token: 'tok',
        currentRemoteHost: 'app',
        currentRemotePort: 80,
        currentHttps: false,
        isHtml: true,
      );
      expect(out, contains('127.0.0.1:9/tok/api/8080/v1'));
      expect(out, contains('127.0.0.1:9/tok/cdn/443/x.png'));
      expect(out, contains('$kGatewaySchemeQueryKey=https'));
      expect(out, contains('data-et-gw-shim'));
      expect(out, contains('XMLHttpRequest'));
    });

    test('injectGatewayFetchShim is idempotent', () {
      const html = '<html><head></head><body></body></html>';
      final once = injectGatewayFetchShim(
        html,
        gatewayPort: 1,
        token: 't',
      );
      final twice = injectGatewayFetchShim(
        once,
        gatewayPort: 1,
        token: 't',
      );
      expect('data-et-gw-shim'.allMatches(twice).length, 1);
    });
  });

  group('remote paths', () {
    test('join / basename / dirname', () {
      expect(remoteJoin('/var', 'www'), '/var/www');
      expect(remoteJoin('/', 'etc'), '/etc');
      expect(remoteBasename('/var/www/a.txt'), 'a.txt');
      expect(remoteDirname('/var/www/a.txt'), '/var/www');
      expect(remoteDirname('/'), '/');
    });
  });

  group('remote process list', () {
    test('parseRemoteOsKind', () {
      expect(parseRemoteOsKind('linux\n'), RemoteOsKind.linux);
      expect(parseRemoteOsKind('windows'), RemoteOsKind.windows);
      expect(parseRemoteOsKind('Darwin'), RemoteOsKind.unknown);
      expect(parseRemoteOsKind(''), RemoteOsKind.unknown);
    });

    test('parseLinuxProcessList', () {
      const raw = '''
  1 root      0.0  0.1  1234 systemd
 42 alice    12.5  3.2 65536 chrome
  7 bob       0.1  0.0   512 bash
''';
      final list = parseLinuxProcessList(raw);
      expect(list, hasLength(3));
      expect(list[1].pid, 42);
      expect(list[1].user, 'alice');
      expect(list[1].cpuPercent, 12.5);
      expect(list[1].memPercent, 3.2);
      expect(list[1].memoryBytes, 65536 * 1024);
      expect(list[1].name, 'chrome');
    });

    test('parseWindowsTasklistCsv', () {
      const raw = '''
"chrome.exe","1234","Console","1","50,123 K"
"svchost.exe","568","Services","0","8,192 K"
"bad-line"
''';
      final list = parseWindowsTasklistCsv(raw);
      expect(list, hasLength(2));
      // sorted by memory desc
      expect(list[0].name, 'chrome.exe');
      expect(list[0].pid, 1234);
      expect(list[0].memoryBytes, 50123 * 1024);
      expect(list[0].session, 'Console');
      expect(list[1].name, 'svchost.exe');
      expect(list[1].pid, 568);
    });

    test('formatProcessMemory', () {
      expect(formatProcessMemory(null), '—');
      expect(formatProcessMemory(512), '512 B');
      expect(formatProcessMemory(2048), '2 KB');
      expect(formatProcessMemory(5 * 1024 * 1024), '5.0 MB');
    });

    test('parseLinuxServiceList', () {
      const raw = '''
ssh.service                  loaded active   running OpenBSD Secure Shell server
nginx.service                loaded inactive dead    A high performance web server
cron.service                 loaded active   running Regular background program processing daemon
''';
      final list = parseLinuxServiceList(raw);
      expect(list, hasLength(3));
      expect(list.first.isRunning, isTrue);
      expect(list.any((s) => s.name == 'nginx.service' && !s.isRunning), isTrue);
      final ssh = list.firstWhere((s) => s.name == 'ssh.service');
      expect(ssh.subState, 'running');
      expect(ssh.displayName, contains('OpenBSD'));
    });

    test('parseWindowsServiceList', () {
      const raw = '''
Spooler|Running|Automatic|Print Spooler
wuauserv|Stopped|Manual|Windows Update
Name|Status|StartType|DisplayName
''';
      final list = parseWindowsServiceList(raw);
      expect(list, hasLength(2));
      expect(list.first.name, 'Spooler');
      expect(list.first.isRunning, isTrue);
      expect(list.first.displayName, 'Print Spooler');
      expect(list.any((s) => s.name == 'wuauserv' && !s.isRunning), isTrue);
    });

    test('parseWindows host metrics', () {
      const raw = '''
__WA__
0.4321
__WB__
0.25
__WC__
0.61
__WG__
2d 5h 10m
__WZ__
''';
      final snap = RemoteHostSnapshot.parseWindows(raw);
      expect(snap, isNotNull);
      expect(snap!.memUsed01, closeTo(0.4321, 0.0001));
      expect(snap.cpuUsed01, closeTo(0.25, 0.0001));
      expect(snap.diskUsed01, closeTo(0.61, 0.0001));
      expect(snap.uptimeLine, '2d 5h 10m');
    });

    test('isSafeRemoteServiceName', () {
      expect(isSafeRemoteServiceName('nginx.service'), isTrue);
      expect(isSafeRemoteServiceName('user@1000.service'), isTrue);
      expect(isSafeRemoteServiceName('Spooler'), isTrue);
      expect(isSafeRemoteServiceName('bad;rm -rf'), isFalse);
      expect(isSafeRemoteServiceName('a b'), isFalse);
    });
  });

  group('DesktopLayoutStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('save and load round-trip', () async {
      final store = DesktopLayoutStore();
      const hostKey = 'u@h:22';
      final data = DesktopLayoutData(
        hostKey: hostKey,
        windows: [
          DesktopLayoutWindow(
            type: 'terminal',
            args: const {'usePrimary': true},
            rect: const [0.1, 0.1, 0.5, 0.5],
            state: 'normal',
            z: 1,
          ),
          DesktopLayoutWindow(
            type: 'browser',
            args: const {'url': 'localhost:3000', 'mode': 'gateway'},
            rect: const [0.4, 0.2, 0.4, 0.5],
            state: 'maximized',
            z: 2,
          ),
        ],
      );
      await store.save(data);
      final loaded = await store.load(hostKey);
      expect(loaded, isNotNull);
      expect(loaded!.hostKey, hostKey);
      expect(loaded.windows, hasLength(2));
      expect(loaded.windows[0].type, 'terminal');
      expect(loaded.windows[1].args['url'], 'localhost:3000');
      expect(loaded.windows[1].state, 'maximized');
    });

    test('corrupt JSON returns null', () async {
      SharedPreferences.setMockInitialValues({
        'desktop_layout_u@h:22': '{not-json',
      });
      final store = DesktopLayoutStore();
      expect(await store.load('u@h:22'), isNull);
    });

    test('hostKey mismatch returns null', () async {
      final store = DesktopLayoutStore();
      await store.save(
        const DesktopLayoutData(hostKey: 'a@b:22', windows: []),
      );
      expect(await store.load('other@b:22'), isNull);
    });
  });
}
