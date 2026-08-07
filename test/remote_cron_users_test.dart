import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:easyterm/services/remote_cron.dart';
import 'package:easyterm/services/remote_sudo.dart';
import 'package:easyterm/services/remote_users.dart';

void main() {
  group('parseCrontab', () {
    test('parses jobs comments and specials', () {
      const raw = '''
# backup
0 2 * * * /usr/bin/backup.sh
@reboot /usr/local/bin/start.sh

''';
      final lines = parseCrontab(raw);
      expect(lines.where((l) => l.isComment).length, 1);
      expect(lines.where((l) => l.isJob).length, 2);
      final job = lines.firstWhere((l) => l.minute == '0');
      expect(job.command, '/usr/bin/backup.sh');
      expect(job.scheduleLabel, '0 2 * * *');
      final special = lines.firstWhere((l) => l.isSpecial);
      expect(special.command, '/usr/local/bin/start.sh');
      expect(special.scheduleLabel, '@reboot');
    });
  });

  group('parseRemoteUsersBundle', () {
    test('splits who last passwd sections', () {
      const raw = '''
__WHO__
alice pts/0 2026-08-07 10:00 (192.168.1.2)
__LAST__
alice pts/0 192.168.1.2 Fri Aug 7 10:00 still logged in
__PASSWD__
root:x:0:0:root:/root:/bin/bash
alice:x:1000:1000:Alice:/home/alice:/bin/bash
''';
      final snap = parseRemoteUsersBundle(raw);
      expect(snap.loggedIn.single.user, 'alice');
      expect(snap.loggedIn.single.host, '192.168.1.2');
      expect(snap.recent.single.user, 'alice');
      expect(snap.accounts.length, 2);
      expect(snap.accounts.firstWhere((a) => a.name == 'alice').home, '/home/alice');
      expect(snap.accounts.firstWhere((a) => a.name == 'root').isSystem(), isTrue);
      expect(snap.accounts.firstWhere((a) => a.name == 'alice').isSystem(), isFalse);
    });

    test('reads UID_MIN from login.defs', () {
      const raw = '''
__WHO__
__LAST__
__PASSWD__
svc:x:500:500:svc:/home/svc:/bin/bash
alice:x:1000:1000:Alice:/home/alice:/bin/bash
__GROUP__
__LOGINDEFS__
UID_MIN			500
''';
      final snap = parseRemoteUsersBundle(raw);
      expect(snap.uidMin, 500);
      expect(snap.accounts.firstWhere((a) => a.name == 'svc').isSystem(snap.uidMin), isFalse);
      expect(snap.accounts.firstWhere((a) => a.name == 'alice').isSystem(snap.uidMin), isFalse);
    });

    test('resolves group names and failed logins', () {
      const raw = '''
__WHO__
__LAST__
__LASTB__
bob ssh:notty 10.0.0.1 Fri Aug 7 09:00 - 09:00  (00:00)
__PASSWD__
alice:x:1000:1000:Alice:/home/alice:/bin/bash
__GROUP__
alice:x:1000:
sudo:x:27:alice
docker:x:999:alice,bob
''';
      final snap = parseRemoteUsersBundle(raw);
      final alice = snap.accounts.single;
      expect(alice.groupName, 'alice');
      expect(alice.groups, ['sudo', 'docker']);
      expect(snap.failedLogins.single.user, 'bob');
      expect(snap.failedLogins.single.host, '10.0.0.1');
    });
  });

  group('isSafeUsername', () {
    test('accepts common names', () {
      expect(isSafeUsername('alice'), isTrue);
      expect(isSafeUsername('_svc'), isTrue);
      expect(isSafeUsername('bob-1'), isTrue);
      expect(isSafeUsername('www-data'), isTrue);
    });

    test('rejects invalid', () {
      expect(isSafeUsername(''), isFalse);
      expect(isSafeUsername('Alice'), isFalse);
      expect(isSafeUsername('1bob'), isFalse);
      expect(isSafeUsername('a' * 33), isFalse);
      expect(isSafeUsername('bob;rm'), isFalse);
    });
  });

  group('user mutate commands', () {
    test('append __EC and use sudo -n; password stays off argv', () {
      expect(userAddCommand('alice'), contains("useradd -m 'alice'"));
      expect(userAddCommand('alice'), contains(r'__EC:$?'));
      expect(userAddCommand('alice'), isNot(contains('chpasswd')));

      final withPass = userAddCommand('alice', password: 's3cret');
      expect(withPass, contains('chpasswd'));
      expect(withPass, contains('useradd'));
      expect(withPass, isNot(contains('s3cret')));
      expect(withPass, isNot(contains('alice:s3cret')));

      expect(userSetPasswordCommand('alice'), contains('chpasswd'));
      expect(userSetPasswordCommand('alice'), isNot(contains('alice:')));
      expect(
        utf8.decode(chpasswdStdinPayload('alice', 's3cret')),
        'alice:s3cret\n',
      );

      expect(userDeleteCommand('alice'), contains('userdel -r'));
      expect(userLockCommand('alice'), contains('usermod -L'));
      expect(userUnlockCommand('alice'), contains('usermod -U'));
      expect(sessionKickByTtyCommand('pts/0'), contains("pkill -KILL -t 'pts/0'"));
    });

    test('sudo -S keeps chpasswd payload after sudo password line', () {
      final cmd = RemoteSudo.toStdinCommand(userSetPasswordCommand('alice'));
      expect(cmd, contains("sudo -S -p ''"));
      expect(cmd, isNot(contains('sudo -n')));
      final stdin = <int>[
        ...RemoteSudo.passwordStdin('sudo-secret'),
        ...chpasswdStdinPayload('alice', 'user-secret'),
      ];
      expect(utf8.decode(stdin), 'sudo-secret\nalice:user-secret\n');
    });
  });
}
