import 'package:flutter_test/flutter_test.dart';

import 'package:easyterm/services/remote_cron.dart';
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
      expect(snap.accounts.firstWhere((a) => a.name == 'root').isSystem, isTrue);
      expect(snap.accounts.firstWhere((a) => a.name == 'alice').isSystem, isFalse);
    });
  });
}
