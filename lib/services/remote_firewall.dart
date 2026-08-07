import 'remote_sudo.dart';
import 'ssh_workspace_controller.dart';

enum RemoteFirewallBackend { ufw, firewalld, iptables, unknown }

extension RemoteFirewallBackendX on RemoteFirewallBackend {
  String get label => switch (this) {
        RemoteFirewallBackend.ufw => 'UFW',
        RemoteFirewallBackend.firewalld => 'firewalld',
        RemoteFirewallBackend.iptables => 'iptables',
        RemoteFirewallBackend.unknown => '未知',
      };
}

class RemoteFirewallRule {
  const RemoteFirewallRule({
    required this.raw,
    this.number,
    this.action = '',
    this.to = '',
    this.from = '',
  });

  final String raw;
  final int? number;
  final String action;
  final String to;
  final String from;
}

class RemoteFirewallSnapshot {
  const RemoteFirewallSnapshot({
    required this.backend,
    required this.active,
    required this.statusText,
    required this.rules,
    this.error,
  });

  final RemoteFirewallBackend backend;
  final bool? active;
  final String statusText;
  final List<RemoteFirewallRule> rules;
  final String? error;
}

RemoteFirewallBackend parseFirewallBackendDetect(String raw) {
  final t = raw.trim().toLowerCase();
  if (t.contains('ufw')) return RemoteFirewallBackend.ufw;
  if (t.contains('firewall-cmd') || t.contains('firewalld')) {
    return RemoteFirewallBackend.firewalld;
  }
  if (t.contains('iptables')) return RemoteFirewallBackend.iptables;
  return RemoteFirewallBackend.unknown;
}

bool? parseUfwActive(String statusText) {
  final t = statusText.toLowerCase();
  if (t.contains('status: active')) return true;
  if (t.contains('status: inactive')) return false;
  return null;
}

List<RemoteFirewallRule> parseUfwStatus(String raw) {
  final rules = <RemoteFirewallRule>[];
  var inRules = false;
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.contains('To') &&
        trimmed.contains('Action') &&
        trimmed.contains('From')) {
      inRules = true;
      continue;
    }
    if (trimmed.startsWith('--') || RegExp(r'^-+$').hasMatch(trimmed.replaceAll(' ', ''))) {
      continue;
    }
    if (!inRules) continue;
    final numM = RegExp(r'^\[\s*(\d+)\]\s+(.*)$').firstMatch(trimmed);
    final body = numM != null ? numM.group(2)! : trimmed;
    final number = numM != null ? int.tryParse(numM.group(1)!) : null;
    final parts = body.split(RegExp(r'\s{2,}'));
    // 跳过仍像表头分隔的行
    if (parts.isNotEmpty && parts[0].replaceAll('-', '').isEmpty) continue;
    rules.add(
      RemoteFirewallRule(
        raw: trimmed,
        number: number,
        to: parts.isNotEmpty ? parts[0] : body,
        action: parts.length > 1 ? parts[1] : '',
        from: parts.length > 2 ? parts.sublist(2).join(' ') : '',
      ),
    );
  }
  return rules;
}

List<RemoteFirewallRule> parseFirewalldList(String raw) {
  final rules = <RemoteFirewallRule>[];
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    rules.add(RemoteFirewallRule(raw: t, to: t));
  }
  return rules;
}

List<RemoteFirewallRule> parseIptablesList(String raw) {
  final rules = <RemoteFirewallRule>[];
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('Chain') || t.startsWith('target')) continue;
    final parts = t.split(RegExp(r'\s+'));
    rules.add(
      RemoteFirewallRule(
        raw: t,
        action: parts.isNotEmpty ? parts[0] : '',
        to: parts.length > 1 ? parts.sublist(1).join(' ') : '',
      ),
    );
  }
  return rules;
}

bool isSafeFirewallPortSpec(String spec) {
  if (spec.isEmpty || spec.length > 32) return false;
  // 22 / 22/tcp / 80:90/tcp / OpenSSH
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9/:._-]*$').hasMatch(spec);
}

Future<RemoteFirewallBackend> detectFirewallBackend(
  SshWorkspaceController c,
) async {
  const cmd = r'''
if command -v ufw >/dev/null 2>&1; then echo ufw; exit 0; fi
if command -v firewall-cmd >/dev/null 2>&1; then echo firewalld; exit 0; fi
if command -v iptables >/dev/null 2>&1; then echo iptables; exit 0; fi
echo none
''';
  final raw = await c.runQueued(cmd);
  if (raw == null) return RemoteFirewallBackend.unknown;
  return parseFirewallBackendDetect(raw.split(RegExp(r'\s')).first);
}

Future<RemoteFirewallSnapshot?> fetchFirewallSnapshot(
  SshWorkspaceController c, {
  RemoteFirewallBackend? backend,
}) async {
  final be = backend ?? await detectFirewallBackend(c);
  switch (be) {
    case RemoteFirewallBackend.ufw:
      final raw = await c.runQueued(
        'ufw status verbose 2>&1; echo __N__; ufw status numbered 2>&1',
      );
      if (raw == null) return null;
      final parts = raw.split('__N__');
      final status = parts.first.trim();
      final numbered = parts.length > 1 ? parts[1].trim() : status;
      var rules = parseUfwStatus(numbered);
      if (rules.isEmpty) rules = parseUfwStatus(status);
      return RemoteFirewallSnapshot(
        backend: be,
        active: parseUfwActive(status),
        statusText: status,
        rules: rules,
      );
    case RemoteFirewallBackend.firewalld:
      final raw = await c.runQueued(
        'firewall-cmd --state 2>&1; echo __SEP__; firewall-cmd --list-all 2>&1',
      );
      if (raw == null) return null;
      final parts = raw.split('__SEP__');
      final state = parts.first.trim().toLowerCase();
      final list = parts.length > 1 ? parts[1].trim() : '';
      return RemoteFirewallSnapshot(
        backend: be,
        active: state.contains('running'),
        statusText: raw.replaceAll('__SEP__', '\n').trim(),
        rules: parseFirewalldList(list),
      );
    case RemoteFirewallBackend.iptables:
      final raw = await c.runQueued('iptables -L -n -v 2>&1 | head -n 200');
      if (raw == null) return null;
      return RemoteFirewallSnapshot(
        backend: be,
        active: null,
        statusText: raw,
        rules: parseIptablesList(raw),
      );
    case RemoteFirewallBackend.unknown:
      return const RemoteFirewallSnapshot(
        backend: RemoteFirewallBackend.unknown,
        active: null,
        statusText: '',
        rules: [],
        error: '未检测到 ufw / firewalld / iptables',
      );
  }
}

String ufwAllowCommand(String portSpec) {
  final p = portSpec.replaceAll("'", "'\\''");
  return "sudo -n ufw allow '$p' 2>&1; echo __EC:\$?";
}

String ufwDenyCommand(String portSpec) {
  final p = portSpec.replaceAll("'", "'\\''");
  return "sudo -n ufw deny '$p' 2>&1; echo __EC:\$?";
}

String ufwDeleteCommand(int number) =>
    "sudo -n ufw --force delete $number 2>&1; echo __EC:\$?";

String ufwSetEnabledCommand(bool enable) => enable
    ? 'sudo -n ufw --force enable 2>&1; echo __EC:\$?'
    : 'sudo -n ufw disable 2>&1; echo __EC:\$?';

Future<String?> runFirewallMutate(
  SshWorkspaceController c,
  String command, {
  String? terminalHint,
  String? sudoPassword,
}) async {
  final usePwd = sudoPassword != null && sudoPassword.isNotEmpty;
  final cmd = usePwd ? RemoteSudo.toStdinCommand(command) : command;
  final raw = await c.runQueued(
    cmd,
    stdinBytes: usePwd ? RemoteSudo.passwordStdin(sudoPassword) : null,
  );
  return RemoteSudo.interpretExit(
    raw,
    usedPassword: usePwd,
    terminalHint: terminalHint ?? command.replaceAll('sudo -n ', 'sudo '),
  );
}
