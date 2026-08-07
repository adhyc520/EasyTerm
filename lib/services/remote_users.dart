import 'ssh_workspace_controller.dart';

class RemoteLoggedInUser {
  const RemoteLoggedInUser({
    required this.user,
    required this.tty,
    required this.host,
    required this.since,
  });

  final String user;
  final String tty;
  final String host;
  final String since;
}

class RemoteLoginRecord {
  const RemoteLoginRecord({
    required this.user,
    required this.tty,
    required this.host,
    required this.when,
  });

  final String user;
  final String tty;
  final String host;
  final String when;
}

class RemotePasswdEntry {
  const RemotePasswdEntry({
    required this.name,
    required this.uid,
    required this.gid,
    required this.home,
    required this.shell,
    this.gecos = '',
  });

  final String name;
  final int uid;
  final int gid;
  final String home;
  final String shell;
  final String gecos;

  bool get isSystem => uid < 1000;
}

class RemoteUsersSnapshot {
  const RemoteUsersSnapshot({
    required this.loggedIn,
    required this.recent,
    required this.accounts,
    this.error,
  });

  final List<RemoteLoggedInUser> loggedIn;
  final List<RemoteLoginRecord> recent;
  final List<RemotePasswdEntry> accounts;
  final String? error;
}

RemoteUsersSnapshot parseRemoteUsersBundle(String raw) {
  final who = <String>[];
  final last = <String>[];
  final passwd = <String>[];
  var section = '';
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    if (line == '__WHO__') {
      section = 'who';
      continue;
    }
    if (line == '__LAST__') {
      section = 'last';
      continue;
    }
    if (line == '__PASSWD__') {
      section = 'passwd';
      continue;
    }
    switch (section) {
      case 'who':
        who.add(line);
      case 'last':
        last.add(line);
      case 'passwd':
        passwd.add(line);
    }
  }
  return RemoteUsersSnapshot(
    loggedIn: _parseWho(who),
    recent: _parseLast(last),
    accounts: _parsePasswd(passwd),
  );
}

List<RemoteLoggedInUser> _parseWho(List<String> lines) {
  final out = <RemoteLoggedInUser>[];
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final user = parts[0];
    final tty = parts[1];
    String host = '';
    String since = '';
    final paren = RegExp(r'\(([^)]*)\)').firstMatch(t);
    if (paren != null) host = paren.group(1) ?? '';
    // 常见: user tty date time (host) 或 user pts/0 ...
    if (parts.length >= 4) {
      since = parts.sublist(2).where((p) => !p.startsWith('(')).join(' ');
    }
    out.add(RemoteLoggedInUser(user: user, tty: tty, host: host, since: since));
  }
  return out;
}

List<RemoteLoginRecord> _parseLast(List<String> lines) {
  final out = <RemoteLoginRecord>[];
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty || t.toLowerCase().startsWith('wtmp') || t.startsWith('reboot')) {
      continue;
    }
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 3) continue;
    final user = parts[0];
    final tty = parts[1];
    var host = '';
    var whenStart = 2;
    if (parts.length > 3 && !RegExp(r'^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$').hasMatch(parts[2])) {
      host = parts[2];
      whenStart = 3;
    }
    final when = parts.length > whenStart ? parts.sublist(whenStart).join(' ') : '';
    out.add(RemoteLoginRecord(user: user, tty: tty, host: host, when: when));
  }
  return out;
}

List<RemotePasswdEntry> _parsePasswd(List<String> lines) {
  final out = <RemotePasswdEntry>[];
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final parts = t.split(':');
    if (parts.length < 7) continue;
    final uid = int.tryParse(parts[2]) ?? -1;
    final gid = int.tryParse(parts[3]) ?? -1;
    if (uid < 0) continue;
    out.add(
      RemotePasswdEntry(
        name: parts[0],
        uid: uid,
        gid: gid,
        gecos: parts[4],
        home: parts[5],
        shell: parts[6],
      ),
    );
  }
  out.sort((a, b) => a.uid.compareTo(b.uid));
  return out;
}

Future<RemoteUsersSnapshot?> fetchRemoteUsers(SshWorkspaceController c) async {
  const cmd = r'''
echo __WHO__
who 2>/dev/null || true
echo __LAST__
last -n 25 2>/dev/null || last -25 2>/dev/null || true
echo __PASSWD__
getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null || true
''';
  final raw = await c.runQueued(cmd);
  if (raw == null) return null;
  return parseRemoteUsersBundle(raw);
}
