import 'dart:convert';

import 'remote_sudo.dart';
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
    this.groupName,
    this.groups = const [],
  });

  final String name;
  final int uid;
  final int gid;
  final String home;
  final String shell;
  final String gecos;

  /// Primary group name from `/etc/group` (resolved via [gid]).
  final String? groupName;

  /// Supplementary groups (membership lists in `/etc/group`).
  final List<String> groups;

  /// 系统账号：`uid < [uidMin]`（默认 1000，可由 `/etc/login.defs` 覆盖）。
  bool isSystem([int uidMin = 1000]) => uid < uidMin;
}

class RemoteUsersSnapshot {
  const RemoteUsersSnapshot({
    required this.loggedIn,
    required this.recent,
    required this.accounts,
    this.failedLogins = const [],
    this.uidMin = 1000,
    this.error,
  });

  final List<RemoteLoggedInUser> loggedIn;
  final List<RemoteLoginRecord> recent;
  final List<RemotePasswdEntry> accounts;
  final List<RemoteLoginRecord> failedLogins;

  /// From `/etc/login.defs` `UID_MIN` (fallback 1000).
  final int uidMin;
  final String? error;
}

final _usernameRe = RegExp(r'^[a-z_][a-z0-9_-]*\$?$');

/// Linux username: `^[a-z_][a-z0-9_-]*$?$`, length ≤ 32.
bool isSafeUsername(String name) {
  if (name.isEmpty || name.length > 32) return false;
  return _usernameRe.hasMatch(name);
}

String _shellSingleQuote(String value) => value.replaceAll("'", "'\\''");

int parseUidMin(List<String> lines, {int fallback = 1000}) {
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final m = RegExp(r'^UID_MIN\s+(\d+)\s*$').firstMatch(t);
    if (m != null) {
      final v = int.tryParse(m.group(1)!);
      if (v != null && v > 0) return v;
    }
  }
  return fallback;
}

RemoteUsersSnapshot parseRemoteUsersBundle(String raw) {
  final who = <String>[];
  final last = <String>[];
  final lastb = <String>[];
  final passwd = <String>[];
  final group = <String>[];
  final loginDefs = <String>[];
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
    if (line == '__LASTB__') {
      section = 'lastb';
      continue;
    }
    if (line == '__PASSWD__') {
      section = 'passwd';
      continue;
    }
    if (line == '__GROUP__') {
      section = 'group';
      continue;
    }
    if (line == '__LOGINDEFS__') {
      section = 'logindefs';
      continue;
    }
    switch (section) {
      case 'who':
        who.add(line);
      case 'last':
        last.add(line);
      case 'lastb':
        lastb.add(line);
      case 'passwd':
        passwd.add(line);
      case 'group':
        group.add(line);
      case 'logindefs':
        loginDefs.add(line);
    }
  }
  final groupMeta = _parseGroup(group);
  return RemoteUsersSnapshot(
    loggedIn: _parseWho(who),
    recent: _parseLast(last),
    failedLogins: _parseLast(lastb),
    accounts: _parsePasswd(passwd, groupMeta),
    uidMin: parseUidMin(loginDefs),
  );
}

class _GroupMeta {
  const _GroupMeta({
    required this.gidToName,
    required this.userToGroups,
  });

  final Map<int, String> gidToName;
  final Map<String, List<String>> userToGroups;
}

_GroupMeta _parseGroup(List<String> lines) {
  final gidToName = <int, String>{};
  final userToGroups = <String, List<String>>{};
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final parts = t.split(':');
    if (parts.length < 4) continue;
    final name = parts[0];
    final gid = int.tryParse(parts[2]);
    if (gid == null) continue;
    gidToName[gid] = name;
    final members = parts[3];
    if (members.isEmpty) continue;
    for (final u in members.split(',')) {
      final user = u.trim();
      if (user.isEmpty) continue;
      (userToGroups[user] ??= <String>[]).add(name);
    }
  }
  return _GroupMeta(gidToName: gidToName, userToGroups: userToGroups);
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
    if (t.isEmpty ||
        t.toLowerCase().startsWith('wtmp') ||
        t.toLowerCase().startsWith('btmp') ||
        t.startsWith('reboot')) {
      continue;
    }
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 3) continue;
    final user = parts[0];
    final tty = parts[1];
    var host = '';
    var whenStart = 2;
    if (parts.length > 3 &&
        !RegExp(r'^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$').hasMatch(parts[2])) {
      host = parts[2];
      whenStart = 3;
    }
    final when =
        parts.length > whenStart ? parts.sublist(whenStart).join(' ') : '';
    out.add(RemoteLoginRecord(user: user, tty: tty, host: host, when: when));
  }
  return out;
}

List<RemotePasswdEntry> _parsePasswd(
  List<String> lines,
  _GroupMeta groupMeta,
) {
  final out = <RemotePasswdEntry>[];
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final parts = t.split(':');
    if (parts.length < 7) continue;
    final uid = int.tryParse(parts[2]) ?? -1;
    final gid = int.tryParse(parts[3]) ?? -1;
    if (uid < 0) continue;
    final name = parts[0];
    out.add(
      RemotePasswdEntry(
        name: name,
        uid: uid,
        gid: gid,
        gecos: parts[4],
        home: parts[5],
        shell: parts[6],
        groupName: groupMeta.gidToName[gid],
        groups: List.unmodifiable(groupMeta.userToGroups[name] ?? const []),
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
echo __LASTB__
lastb -n 20 2>/dev/null || true
echo __PASSWD__
getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null || true
echo __GROUP__
getent group 2>/dev/null || cat /etc/group 2>/dev/null || true
echo __LOGINDEFS__
grep -E '^UID_MIN' /etc/login.defs 2>/dev/null || true
''';
  final raw = await c.runQueued(cmd);
  if (raw == null) return null;
  return parseRemoteUsersBundle(raw);
}

/// `name:password\n` for [chpasswd] stdin — never embed the password in argv.
List<int> chpasswdStdinPayload(String name, String password) =>
    utf8.encode('$name:$password\n');

/// `useradd -m`; when [password] is non-empty, also runs `chpasswd` in the same
/// sudo session so `sudo -S` can auth once. Pass [chpasswdStdinPayload] via
/// [runUsersMutate]'s `stdinPayload` — the password is never in the command.
String userAddCommand(String name, {String? password}) {
  final n = _shellSingleQuote(name);
  final setPass = password != null && password.isNotEmpty;
  if (setPass) {
    // Single sudo: after optional sudo-password line, remaining stdin → chpasswd.
    return "sudo -n sh -c \"useradd -m '$n' && chpasswd\" 2>&1; echo __EC:\$?";
  }
  return "sudo -n useradd -m '$n' 2>&1; echo __EC:\$?";
}

String userDeleteCommand(String name) {
  final n = _shellSingleQuote(name);
  return "sudo -n userdel -r '$n' 2>&1; echo __EC:\$?";
}

String userLockCommand(String name) {
  final n = _shellSingleQuote(name);
  return "sudo -n usermod -L '$n' 2>&1; echo __EC:\$?";
}

String userUnlockCommand(String name) {
  final n = _shellSingleQuote(name);
  return "sudo -n usermod -U '$n' 2>&1; echo __EC:\$?";
}

/// Hint helper for dialogs (interactive `passwd`).
String userPasswdCommand(String name) {
  final n = _shellSingleQuote(name);
  return "sudo -n passwd '$n'";
}

/// Set password via `chpasswd` reading stdin (`name:password\\n`).
///
/// Callers must pass [chpasswdStdinPayload] as [runUsersMutate] `stdinPayload`.
String userSetPasswordCommand(String name) {
  assert(isSafeUsername(name));
  return r'sudo -n chpasswd 2>&1; echo __EC:$?';
}

/// Kick a single session by TTY (safer than killing all user processes).
String sessionKickByTtyCommand(String tty) {
  final t = _shellSingleQuote(tty);
  return "sudo -n pkill -KILL -t '$t' 2>&1; echo __EC:\$?";
}

Future<String?> runUsersMutate(
  SshWorkspaceController c,
  String cmd, {
  String? sudoPassword,
  List<int>? stdinPayload,
  String? terminalHint,
}) async {
  final usePwd = sudoPassword != null && sudoPassword.isNotEmpty;
  final wrapped = usePwd ? RemoteSudo.toStdinCommand(cmd) : cmd;
  // sudo -S consumes the first line; remaining bytes go to the command (e.g. chpasswd).
  final bytes = <int>[
    if (usePwd) ...RemoteSudo.passwordStdin(sudoPassword),
    if (stdinPayload != null) ...stdinPayload,
  ];
  final raw = await c.runQueued(
    wrapped,
    stdinBytes: bytes.isEmpty ? null : bytes,
  );
  return RemoteSudo.interpretExit(
    raw,
    usedPassword: usePwd,
    terminalHint: terminalHint ?? cmd.replaceAll('sudo -n ', 'sudo '),
  );
}
