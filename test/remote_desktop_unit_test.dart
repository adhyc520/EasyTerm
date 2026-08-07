import 'package:easyterm/services/browser_gateway_rewrite.dart';
import 'package:easyterm/services/desktop_window_size_store.dart';
import 'package:easyterm/services/remote_browser_backend.dart';
import 'package:easyterm/services/remote_containers.dart';
import 'package:easyterm/services/remote_disk_usage.dart';
import 'package:easyterm/services/remote_gpu.dart';
import 'package:easyterm/services/remote_host_metrics.dart';
import 'package:easyterm/services/remote_logs.dart';
import 'package:easyterm/services/remote_network.dart';
import 'package:easyterm/services/remote_process_list.dart';
import 'package:easyterm/util/remote_paths.dart';
import 'package:flutter_test/flutter_test.dart';

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

  group('isSshTunneledBrowserHost', () {
    test('localhost private and single-label are tunneled', () {
      expect(isSshTunneledBrowserHost('localhost'), isTrue);
      expect(isSshTunneledBrowserHost('127.0.0.1'), isTrue);
      expect(isSshTunneledBrowserHost('10.0.0.5'), isTrue);
      expect(isSshTunneledBrowserHost('192.168.1.1'), isTrue);
      expect(isSshTunneledBrowserHost('172.16.0.1'), isTrue);
      expect(isSshTunneledBrowserHost('api'), isTrue);
      expect(isSshTunneledBrowserHost('svc.internal'), isTrue);
      expect(isSshTunneledBrowserHost('printer.local'), isTrue);
    });

    test('public domains are not tunneled', () {
      expect(isSshTunneledBrowserHost('www.baidu.com'), isFalse);
      expect(isSshTunneledBrowserHost('google.com'), isFalse);
      expect(isSshTunneledBrowserHost('cdn.jsdelivr.net'), isFalse);
      expect(isSshTunneledBrowserHost('8.8.8.8'), isFalse);
    });
  });

  group('buildDirectBrowserNavigationUri', () {
    test('https omits default port', () {
      final u = buildDirectBrowserNavigationUri(
        const BrowserAddressTarget(
          host: 'www.example.com',
          port: 443,
          pathAndQuery: '/a?q=1',
          https: true,
        ),
      );
      expect(u.toString(), 'https://www.example.com/a?q=1');
    });
  });

  group('externalBrowserNavigationUri', () {
    test('public hosts return real http(s) uri', () {
      final u = externalBrowserNavigationUri('https://www.example.com/a?q=1&b=2');
      expect(u, isNotNull);
      expect(u!.scheme, 'https');
      expect(u.host, 'www.example.com');
      expect(u.query, contains('q=1'));
      expect(u.query, contains('b=2'));
    });

    test('tunneled hosts return null (no gateway leak)', () {
      expect(externalBrowserNavigationUri('localhost:3000'), isNull);
      expect(externalBrowserNavigationUri('10.0.0.5:8080'), isNull);
      expect(externalBrowserNavigationUri('api.internal/health'), isNull);
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

      // Public CDN must stay absolute so WebView loads it locally.
      expect(
        rewriteRemoteAbsoluteUrl(
          'https://cdn.jsdelivr.net/npm/x.js',
          gatewayPort: 9,
          token: 'tok',
        ),
        isNull,
      );
    });

    test('rewriteGatewayResponseBody rewrites attrs and injects shim', () {
      const html = '''
<html><head><title>t</title></head>
<body>
<a href="http://api:8080/v1">link</a>
<script src="/assets/app.js"></script>
<link rel="stylesheet" href="/static/app.css"/>
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
      // Root-relative SPA assets must keep the gateway prefix (else white screen).
      expect(out, contains('127.0.0.1:9/tok/app/80/assets/app.js'));
      expect(out, contains('127.0.0.1:9/tok/app/80/static/app.css'));
      expect(out, contains('$kGatewaySchemeQueryKey=https'));
      expect(out, contains('data-et-gw-shim'));
      expect(out, contains('XMLHttpRequest'));
      expect(out, contains('REMOTE_HOST'));
    });

    test('rewriteGatewayRootRelativeUrl prefixes token path', () {
      final u = rewriteGatewayRootRelativeUrl(
        '/api/v1?x=1',
        gatewayPort: 9,
        token: 'tok',
        currentRemoteHost: 'app.internal',
        currentRemotePort: 3000,
        currentHttps: true,
      );
      expect(u, contains('127.0.0.1:9/tok/app.internal/3000/api/v1'));
      expect(u, contains('$kGatewaySchemeQueryKey=https'));
      expect(u, contains('x=1'));
      expect(
        rewriteGatewayRootRelativeUrl(
          'relative',
          gatewayPort: 9,
          token: 'tok',
          currentRemoteHost: 'app',
          currentRemotePort: 80,
          currentHttps: false,
        ),
        isNull,
      );
    });

    test('injectGatewayFetchShim is idempotent', () {
      const html = '<html><head></head><body></body></html>';
      final once = injectGatewayFetchShim(
        html,
        gatewayPort: 1,
        token: 't',
        currentRemoteHost: 'app',
        currentRemotePort: 80,
        currentHttps: false,
      );
      final twice = injectGatewayFetchShim(
        once,
        gatewayPort: 1,
        token: 't',
        currentRemoteHost: 'app',
        currentRemotePort: 80,
        currentHttps: false,
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

    test('isRemoteAbsolutePath / normalizeRemotePath', () {
      expect(isRemoteAbsolutePath('/etc/passwd'), isTrue);
      expect(isRemoteAbsolutePath(r'C:\Windows'), isTrue);
      expect(isRemoteAbsolutePath('C:/Windows'), isTrue);
      expect(isRemoteAbsolutePath('relative/path'), isFalse);
      expect(isRemoteAbsolutePath(''), isFalse);
      expect(normalizeRemotePath(r'C:/Users/a'), r'C:\Users\a');
      expect(normalizeRemotePath(r'/var\www'), '/var/www');
    });

    test('isRemotePathUnderOrEqual', () {
      expect(isRemotePathUnderOrEqual('/a', '/a/b'), isTrue);
      expect(isRemotePathUnderOrEqual('/a/b', '/a/b copy'), isFalse);
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
__WD__
C:|100000000000|61000000000|39000000000|0.61
D:|50000000000|10000000000|40000000000|0.2
__WG__
2d 5h 10m
__WH__
WIN-BOX · Windows Server 2022 · 10.0.20348
__WZ__
''';
      final snap = RemoteHostSnapshot.parseWindows(raw);
      expect(snap, isNotNull);
      expect(snap!.memUsed01, closeTo(0.4321, 0.0001));
      expect(snap.cpuUsed01, closeTo(0.25, 0.0001));
      expect(snap.diskUsed01, closeTo(0.61, 0.0001));
      expect(snap.uptimeLine, '2d 5h 10m');
      expect(snap.hostInfoLine, contains('WIN-BOX'));
      expect(snap.mounts, hasLength(2));
      expect(snap.mounts.first.mountPoint, 'C:');
      expect(snap.mounts.first.used01, closeTo(0.61, 0.0001));
    });

    test('parseDfMounts skips virtual mounts', () {
      const raw = '''
/dev/sda1       10485760  5242880  5242880  50% /
tmpfs             102400     100   102300   1% /run
/dev/sdb1       20971520 18874368  2097152  90% /data
''';
      final mounts = parseDfMounts(raw);
      expect(mounts.map((m) => m.mountPoint).toList(), ['/data', '/']);
      expect(mounts.first.used01, closeTo(0.9, 0.001));
    });

    test('isSafeRemoteServiceName', () {
      expect(isSafeRemoteServiceName('nginx.service'), isTrue);
      expect(isSafeRemoteServiceName('user@1000.service'), isTrue);
      expect(isSafeRemoteServiceName('Spooler'), isTrue);
      expect(isSafeRemoteServiceName('bad;rm -rf'), isFalse);
      expect(isSafeRemoteServiceName('a b'), isFalse);
    });
  });

  group('remote network', () {
    test('parseProcNetDev', () {
      const raw = '''
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0
  eth0: 5000000 100 0 0 0 0 0 0 8000000 200 0 0 0 0 0 0
''';
      final list = parseProcNetDev(raw);
      expect(list, hasLength(2));
      expect(list.first.name, 'eth0');
      expect(list.first.rxBytes, 5000000);
      expect(list.first.txBytes, 8000000);
      expect(list.last.isLoopback, isTrue);
    });

    test('parseLinuxListenSockets ss and netstat', () {
      const ss = '''
LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
LISTEN 0 511 *:80 *:*
UNCONN 0 0 127.0.0.1:323 0.0.0.0:*
''';
      final a = parseLinuxListenSockets(ss);
      expect(a.map((s) => s.port).toList(), [22, 80, 323]);
      expect(a.first.protocol, 'tcp');
      expect(a.firstWhere((s) => s.port == 323).protocol, 'udp');
      expect(a.first.browserTarget, 'localhost:22');
      expect(
        a.firstWhere((s) => s.port == 323).browserTarget,
        isNull,
      );

      expect(
        const RemoteListenSocket(
          protocol: 'tcp6',
          address: '2001:db8::1',
          port: 8080,
        ).browserTarget,
        '[2001:db8::1]:8080',
      );
      expect(
        const RemoteListenSocket(
          protocol: 'tcp6',
          address: '::',
          port: 443,
        ).browserTarget,
        'localhost:443',
      );
      final v6Target = const RemoteListenSocket(
        protocol: 'tcp6',
        address: '2001:db8::1',
        port: 8080,
      ).browserTarget!;
      final parsed = parseBrowserAddressBar(v6Target);
      expect(parsed.host, '2001:db8::1');
      expect(parsed.port, 8080);

      const netstat = '''
Active Internet connections
Proto Recv-Q Send-Q Local Address Foreign Address State
tcp        0      0 0.0.0.0:443           0.0.0.0:*               LISTEN
udp        0      0 0.0.0.0:53            0.0.0.0:*
''';
      final b = parseLinuxListenSockets(netstat);
      expect(b.any((s) => s.port == 443 && s.protocol.startsWith('tcp')), isTrue);
      expect(b.any((s) => s.port == 53 && s.protocol.startsWith('udp')), isTrue);
    });

    test('parseWindows network bundle', () {
      const raw = '''
__IF__
Ethernet|1000000|2000000
Loopback Pseudo-Interface 1|100|200
__LISTEN__
tcp|0.0.0.0|22|1234
tcp|127.0.0.1|3389|5678
udp|0.0.0.0|53|90
__SUM__
Established=12 Listen=4 TimeWait=3
__Z__
''';
      final snap = parseWindowsNetworkBundle(raw);
      expect(snap, isNotNull);
      expect(snap!.interfaces.first.name, 'Ethernet');
      expect(snap.listeners, hasLength(3));
      expect(snap.tcpEstablished, 12);
      expect(snap.tcpListen, 4);
      expect(snap.tcpTimeWait, 3);
    });

    test('ratesAgainst needs prior sample', () {
      final t0 = DateTime.utc(2026, 1, 1, 0, 0, 0);
      final t1 = DateTime.utc(2026, 1, 1, 0, 0, 2);
      final a = RemoteNetworkSnapshot(
        os: RemoteOsKind.linux,
        interfaces: const [
          RemoteNetIface(name: 'eth0', rxBytes: 1000, txBytes: 2000),
        ],
        listeners: const [],
        sampledAt: t0,
      );
      final b = RemoteNetworkSnapshot(
        os: RemoteOsKind.linux,
        interfaces: const [
          RemoteNetIface(name: 'eth0', rxBytes: 3000, txBytes: 6000),
        ],
        listeners: const [],
        sampledAt: t1,
      );
      final rates = b.ratesAgainst(a);
      expect(rates, hasLength(1));
      expect(rates.first.rxBytesPerSec, closeTo(1000, 0.1));
      expect(rates.first.txBytesPerSec, closeTo(2000, 0.1));
      expect(formatNetRate(1024), '1.0 KB/s');
      expect(formatNetBytes(5 * 1024 * 1024), '5.0 MB');
    });

    test('parseLinuxNetworkBundle listen + summary', () {
      const raw = '''
__IF__
eth0: 1000 1 0 0 0 0 0 0 2000 2 0 0 0 0 0 0
__LISTEN__
LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
__SUM__
TCP:   12 (estab 3, closed 4, orphaned 0, synrecv 0, timewait 2/0), ports 0
Listen       8      20
__Z__
''';
      final snap = parseLinuxNetworkBundle(raw)!;
      expect(snap.listeners, hasLength(1));
      expect(snap.tcpEstablished, 3);
      expect(snap.tcpListen, 8);
      expect(formatNetBytes(500), '500 B');
      expect(formatNetRate(null), '—');
    });
  });

  group('remote logs', () {
    test('isSafeLogUnit and isSafeLogPath', () {
      expect(isSafeLogUnit('nginx.service'), isTrue);
      expect(isSafeLogUnit('System'), isTrue);
      expect(isSafeLogUnit('bad;rm'), isFalse);
      expect(isSafeLogPath('/var/log/syslog'), isTrue);
      expect(isSafeLogPath('../etc/passwd'), isFalse);
      expect(isSafeLogPath(r'C:\Windows\Logs\x.log'), isTrue);
    });

    test('parseLinuxJournal', () {
      const raw = '''
2026-08-06T12:00:00+08:00 host sshd[1]: Accepted publickey
2026-08-06T12:00:01+08:00 host nginx: error: upstream timed out
''';
      final snap = parseLinuxJournal(raw, unit: 'sshd');
      expect(snap.error, isNull);
      expect(snap.lines, hasLength(2));
      expect(snap.lines.last.isError, isTrue);
      expect(snap.label, 'sshd');
    });

    test('parseWindowsEventLog', () {
      const raw = '''
2026-08-06T12:00:00|Error|Something failed
2026-08-06T12:00:01|Warning|Disk almost full
''';
      final snap = parseWindowsEventLog(raw, logName: 'System');
      expect(snap.lines, hasLength(2));
      expect(snap.lines.first.level, 'Error');
      expect(snap.lines.first.isError, isTrue);
      expect(snap.lines.last.isWarn, isTrue);
    });

    test('journal error marker', () {
      final snap = parseLinuxJournal('__ET_LOG_ERR__ journalctl unavailable');
      expect(snap.lines, isEmpty);
      expect(snap.error, contains('unavailable'));
    });
  });

  group('remote containers', () {
    test('isSafeContainerRef', () {
      expect(isSafeContainerRef('abc123def456'), isTrue);
      expect(isSafeContainerRef('my_app-1'), isTrue);
      expect(isSafeContainerRef('bad;rm'), isFalse);
    });

    test('parseDockerPs and stats merge', () {
      const ps = '''
CONTAINER ID|NAMES|IMAGE|STATUS|STATE|PORTS
a1b2c3d4e5f6|web|nginx:latest|Up 2 hours|running|0.0.0.0:80->80/tcp
deadbeefcafe|db|postgres:15|Exited (0) 1h|exited|
''';
      final list = parseDockerPs(ps);
      expect(list, hasLength(2));
      expect(list.first.name, 'web');
      expect(list.first.isRunning, isTrue);
      expect(list.last.isRunning, isFalse);

      const stats = '''
a1b2c3d4e5f6|12.5%|40.0%|100MiB / 1GiB|1kB / 2kB
''';
      final merged = mergeDockerStats(list, parseDockerStats(stats));
      expect(merged.first.cpuPercent, closeTo(12.5, 0.01));
      expect(merged.first.memPercent, closeTo(40.0, 0.01));
      expect(merged.first.memUsage, contains('100MiB'));
    });
  });

  group('remote gpu', () {
    test('parseNvidiaSmiCsv', () {
      const raw = '''
0, NVIDIA GeForce RTX 4090, 45 %, 8192, 24576, 62
1, Tesla T4, 12, 1024, 15360, 41
''';
      final list = parseNvidiaSmiCsv(raw);
      expect(list, hasLength(2));
      expect(list.first.index, 0);
      expect(list.first.name, contains('4090'));
      expect(list.first.util01, closeTo(0.45, 0.001));
      expect(list.first.memUsed01, closeTo(8192 / 24576, 0.001));
      expect(list.first.tempC, 62);
      expect(list.last.util01, closeTo(0.12, 0.001));
    });

    test('parseNvidiaSmiCsv ignores junk', () {
      expect(parseNvidiaSmiCsv('NVIDIA-SMI has failed'), isEmpty);
      expect(parseNvidiaSmiCsv(''), isEmpty);
    });
  });

  group('remote disk usage', () {
    test('isSafeDiskUsagePath', () {
      expect(isSafeDiskUsagePath('/var/www'), isTrue);
      expect(isSafeDiskUsagePath(r'C:\Users'), isTrue);
      expect(isSafeDiskUsagePath('../etc'), isFalse);
      expect(isSafeDiskUsagePath('bad;rm'), isFalse);
    });

    test('parseLinuxDu', () {
      const raw = '''
1024\t/var/www/a
4096\t/var/www/b
8192\t/var/www
''';
      final snap = parseLinuxDu(raw, path: '/var/www');
      expect(snap.error, isNull);
      expect(snap.entries.any((e) => e.isTotal && e.bytes == 8192), isTrue);
      expect(snap.entries.first.name, 'b');
      expect(snap.entries.first.bytes, 4096);
      expect(snap.totalBytes, 8192);
    });

    test('parseWindowsDu', () {
      const raw = '''
1048576|Logs
2097152|Data
''';
      final snap = parseWindowsDu(raw, path: r'C:\app');
      expect(snap.entries, hasLength(3)); // + total
      expect(snap.totalBytes, 1048576 + 2097152);
      expect(snap.entries.first.name, 'Data');
    });
  });

  group('desktop window size store', () {
    test('round-trips fractions and clamps', () {
      final encoded = DesktopWindowSizeStore.encodeSizesJson({
        'terminal': (w: 0.6, h: 0.4),
        'files': (w: 2.0, h: 0.01),
      });
      final parsed = DesktopWindowSizeStore.parseSizesJson(encoded);
      expect(parsed['terminal']!.w, closeTo(0.6, 1e-9));
      expect(parsed['terminal']!.h, closeTo(0.4, 1e-9));
      expect(parsed['files']!.w, 1.0);
      expect(parsed['files']!.h, 0.05);
    });

    test('ignores corrupt payload', () {
      expect(DesktopWindowSizeStore.parseSizesJson('not-json'), isEmpty);
      expect(DesktopWindowSizeStore.parseSizesJson('{"x":1}'), isEmpty);
    });
  });
}
