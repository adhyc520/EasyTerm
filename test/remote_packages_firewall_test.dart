import 'package:flutter_test/flutter_test.dart';

import 'package:easyterm/services/remote_firewall.dart';
import 'package:easyterm/services/remote_packages.dart';

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

    test('mutate commands include sudo -n for apt', () {
      final cmd = mutatePackageCommand(
        RemotePackageManager.apt,
        name: 'curl',
        install: true,
      );
      expect(cmd, contains('sudo -n apt-get install'));
      expect(cmd, contains('curl'));
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
  });
}
