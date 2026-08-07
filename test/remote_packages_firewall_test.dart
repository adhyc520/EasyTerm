import 'package:flutter_test/flutter_test.dart';

import 'package:easyterm/services/remote_firewall.dart';
import 'package:easyterm/services/remote_packages.dart';
import 'package:easyterm/services/remote_sudo.dart';

void main() {
  group('remote packages', () {
    test('detect manager preference order', () {
      expect(parsePackageManagerDetect('apt-get'), RemotePackageManager.apt);
      expect(parsePackageManagerDetect('dnf'), RemotePackageManager.dnf);
      expect(parsePackageManagerDetect('pacman'), RemotePackageManager.pacman);
      expect(parsePackageManagerDetect('brew'), RemotePackageManager.brew);
      expect(parsePackageManagerDetect('none'), RemotePackageManager.unknown);
    });

    test('parse installed apt lines', () {
      const raw = 'curl\t8.5.0-2\nbash\t5.2.21-2';
      final list = parseInstalledPackages(RemotePackageManager.apt, raw);
      expect(list.map((e) => e.name), ['curl', 'bash']);
      expect(list.first.version, '8.5.0-2');
    });

    test('parse apt search', () {
      const raw = 'curl - command line tool\ngit - fast vcs';
      final list = parseSearchPackages(RemotePackageManager.apt, raw);
      expect(list.length, 2);
      expect(list.first.name, 'curl');
      expect(list.first.description, contains('command'));
    });

    test('safe package names', () {
      expect(isSafePackageName('curl'), isTrue);
      expect(isSafePackageName('libssl1.1'), isTrue);
      expect(isSafePackageName('foo;rm'), isFalse);
      expect(isSafePackageName('../x'), isFalse);
    });

    test('simulate remove apt dry-run', () {
      expect(
        simulateRemoveCommand(RemotePackageManager.apt, 'curl'),
        contains("apt-get -s remove 'curl'"),
      );
      expect(
        simulateRemoveCommand(RemotePackageManager.dnf, 'curl'),
        contains('dnf remove'),
      );
      expect(
        simulateRemoveCommand(RemotePackageManager.yum, 'curl'),
        contains('yum'),
      );
      expect(
        simulateRemoveCommand(RemotePackageManager.brew, 'curl'),
        contains("brew uninstall --dry-run 'curl'"),
      );
      expect(simulateRemoveCommand(RemotePackageManager.pacman, 'curl'), isNull);
      expect(simulateRemoveCommand(RemotePackageManager.zypper, 'curl'), isNull);
      const raw = '''
NOTE: This is only a simulation!
Remv curl [8.5.0-2]
Remv libcurl4 [8.5.0-2]
''';
      expect(
        parseRemoveSimulation(RemotePackageManager.apt, raw),
        ['curl', 'libcurl4'],
      );
      const brewRaw = '''
Would uninstall 2 formulae:
curl
gettext
''';
      expect(
        parseRemoveSimulation(RemotePackageManager.brew, brewRaw),
        ['curl', 'gettext'],
      );
    });

    test('install target with version', () {
      expect(isSafePackageVersion('8.5.0-2'), isTrue);
      expect(isSafePackageVersion('1.2.3~rc1'), isTrue);
      expect(isSafePackageVersion('bad;rm'), isFalse);
      expect(
        packageInstallTarget(RemotePackageManager.apt, 'curl', version: '8.5.0'),
        'curl=8.5.0',
      );
      expect(
        packageInstallTarget(RemotePackageManager.dnf, 'curl', version: '8.5.0'),
        'curl-8.5.0',
      );
      expect(
        packageInstallTarget(
          RemotePackageManager.brew,
          'curl',
          version: '8.5.0',
        ),
        'curl@8.5.0',
      );
      expect(
        packageInstallTarget(
          RemotePackageManager.pacman,
          'curl',
          version: '8.5.0',
        ),
        'curl',
      );
      final apt = mutatePackageStreamCommand(
        RemotePackageManager.apt,
        name: 'curl',
        install: true,
        version: '8.5.0-2',
      );
      expect(apt, contains("'curl=8.5.0-2'"));
      final dnf = mutatePackageStreamCommand(
        RemotePackageManager.dnf,
        name: 'curl',
        install: true,
        version: '8.5.0',
      );
      expect(dnf, contains("'curl-8.5.0'"));
      final brew = mutatePackageStreamCommand(
        RemotePackageManager.brew,
        name: 'curl',
        install: true,
        version: '8.5.0',
      );
      expect(brew, contains("'curl@8.5.0'"));
    });

    test('parse package version candidates', () {
      const madison = '''
curl | 8.5.0-2ubuntu2 | http://archive.ubuntu.com/ubuntu jammy/main amd64 Packages
curl | 7.81.0-1 | http://archive.ubuntu.com/ubuntu jammy/main amd64 Packages
''';
      expect(
        parsePackageVersions(RemotePackageManager.apt, madison),
        ['8.5.0-2ubuntu2', '7.81.0-1'],
      );
      const dnfRaw = '8.5.0-1.fc39\n8.4.0-1.fc39\n';
      expect(
        parsePackageVersions(RemotePackageManager.dnf, dnfRaw),
        ['8.5.0-1.fc39', '8.4.0-1.fc39'],
      );
      expect(
        packageVersionsCommand(RemotePackageManager.apt, 'curl'),
        contains('apt-cache madison'),
      );
      expect(
        packageVersionsCommand(RemotePackageManager.dnf, 'curl'),
        contains('repoquery'),
      );
      expect(packageVersionsCommand(RemotePackageManager.brew, 'curl'), isNull);
    });

    test('mutate commands include sudo -n for apt', () {
      final cmd = mutatePackageCommand(
        RemotePackageManager.apt,
        name: 'curl',
        install: true,
      );
      expect(cmd, contains('sudo -n apt-get install'));
      expect(cmd, contains('curl'));
    });

    test('list installed apt supports name filter', () {
      final cmd = listInstalledCommand(
        RemotePackageManager.apt,
        nameFilter: 'openjdk',
      );
      expect(cmd, contains("'*openjdk*'"));
      expect(cmd, contains('dpkg-query'));
    });

    test('list installed default limit is large', () {
      final cmd = listInstalledCommand(RemotePackageManager.apt);
      expect(cmd, contains('head -n 20000'));
    });

    test('unknown mutate command fails', () {
      final cmd = mutatePackageCommand(
        RemotePackageManager.unknown,
        name: 'x',
        install: true,
      );
      expect(cmd, contains('false'));
      expect(cmd, contains('__EC:'));
    });
  });

  group('remote firewall', () {
    test('detect backend', () {
      expect(parseFirewallBackendDetect('ufw'), RemoteFirewallBackend.ufw);
      expect(
        parseFirewallBackendDetect('firewalld'),
        RemoteFirewallBackend.firewalld,
      );
      expect(
        parseFirewallBackendDetect('iptables'),
        RemoteFirewallBackend.iptables,
      );
    });

    test('parse ufw status numbered', () {
      const raw = '''
Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 80/tcp                     ALLOW IN    Anywhere
''';
      expect(parseUfwActive(raw), isTrue);
      final rules = parseUfwStatus(raw);
      expect(rules.length, 2);
      expect(rules.first.number, 1);
      expect(rules.first.to, contains('22/tcp'));
      expect(rules.first.action.toUpperCase(), contains('ALLOW'));
    });

    test('safe port specs', () {
      expect(isSafeFirewallPortSpec('22/tcp'), isTrue);
      expect(isSafeFirewallPortSpec('OpenSSH'), isTrue);
      expect(isSafeFirewallPortSpec('80;rm'), isFalse);
    });

    test('parse firewalld --list-all zone', () {
      const raw = '''
public (active)
  target: default
  icmp-block-inversion: no
  interfaces: eth0
  sources:
  services: dhcpv6-client ssh http
  ports: 8080/tcp 9090/udp
  protocols:
  forward: yes
  masquerade: no
  forward-ports:
  source-ports:
  icmp-blocks:
  rich rules:
''';
      final zone = parseFirewalldZoneInfo(raw);
      expect(zone, isNotNull);
      expect(zone!.zone, 'public');
      expect(zone.services, ['dhcpv6-client', 'ssh', 'http']);
      expect(zone.ports, ['8080/tcp', '9090/udp']);
      final withZones = parseFirewalldZoneInfo(
        raw,
        availableZones: ['public', 'trusted', 'drop'],
      );
      expect(withZones!.availableZones, ['public', 'trusted', 'drop']);
    });

    test('parse firewalld zones list', () {
      expect(
        parseFirewalldZonesList('public trusted drop dmz'),
        ['public', 'trusted', 'drop', 'dmz'],
      );
      expect(isSafeFirewalldZoneName('public'), isTrue);
      expect(isSafeFirewalldZoneName('dmz'), isTrue);
      expect(isSafeFirewalldZoneName('pub;rm'), isFalse);
      expect(
        firewalldSetDefaultZoneCommand('trusted'),
        contains("--set-default-zone='trusted'"),
      );
    });

    test('safe firewalld service names', () {
      expect(isSafeFirewalldServiceName('http'), isTrue);
      expect(isSafeFirewalldServiceName('dhcpv6-client'), isTrue);
      expect(isSafeFirewalldServiceName('HTTP'), isFalse);
      expect(isSafeFirewalldServiceName('http;rm'), isFalse);
    });

    test('firewalld mutate helpers', () {
      expect(
        firewalldAddServiceCommand('http'),
        contains("--add-service='http'"),
      );
      expect(firewalldAddServiceCommand('http'), contains('--reload'));
      expect(
        firewalldAddPortCommand('8080/tcp'),
        contains("--add-port='8080/tcp'"),
      );
      expect(firewalldReloadCommand(), contains('--reload'));
    });

    test('toStdinCommand rewrites sudo -n', () {
      expect(
        RemoteSudo.toStdinCommand("sudo -n ufw allow '22' 2>&1; echo __EC:\$?"),
        "sudo -S -p '' ufw allow '22' 2>&1; echo __EC:\$?",
      );
    });
  });

  group('remote sudo interpret', () {
    test('password required from sudo -n', () {
      final err = RemoteSudo.interpretExit(
        'sudo: a password is required\n__EC:1',
        usedPassword: false,
      );
      expect(err, RemoteSudo.passwordRequired);
    });

    test('auth failed from sudo -S', () {
      final err = RemoteSudo.interpretExit(
        'Sorry, try again.\n__EC:1',
        usedPassword: true,
      );
      expect(err, RemoteSudo.authFailed);
    });

    test('success', () {
      expect(
        RemoteSudo.interpretExit('done\n__EC:0', usedPassword: false),
        isNull,
      );
    });
  });
}
