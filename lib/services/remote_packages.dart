import 'ssh_workspace_controller.dart';

enum RemotePackageManager {
  apt,
  dnf,
  yum,
  pacman,
  brew,
  zypper,
  unknown,
}

extension RemotePackageManagerX on RemotePackageManager {
  String get label => switch (this) {
        RemotePackageManager.apt => 'APT',
        RemotePackageManager.dnf => 'DNF',
        RemotePackageManager.yum => 'YUM',
        RemotePackageManager.pacman => 'pacman',
        RemotePackageManager.brew => 'Homebrew',
        RemotePackageManager.zypper => 'zypper',
        RemotePackageManager.unknown => '未知',
      };
}

class RemotePackage {
  const RemotePackage({
    required this.name,
    this.version = '',
    this.description = '',
    this.installed = true,
  });

  final String name;
  final String version;
  final String description;
  final bool installed;
}

class RemotePackagesSnapshot {
  const RemotePackagesSnapshot({
    required this.manager,
    required this.packages,
    this.error,
  });

  final RemotePackageManager manager;
  final List<RemotePackage> packages;
  final String? error;
}

/// 仅允许常见包名字符，避免命令注入。
bool isSafePackageName(String name) {
  if (name.isEmpty || name.length > 180) return false;
  if (name.contains('..')) return false;
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9+._:@/-]*$').hasMatch(name);
}

RemotePackageManager parsePackageManagerDetect(String raw) {
  final t = raw.trim().toLowerCase();
  if (t.contains('apt-get') || t == 'apt') return RemotePackageManager.apt;
  if (t.contains('dnf')) return RemotePackageManager.dnf;
  if (t.contains('yum')) return RemotePackageManager.yum;
  if (t.contains('pacman')) return RemotePackageManager.pacman;
  if (t.contains('brew')) return RemotePackageManager.brew;
  if (t.contains('zypper')) return RemotePackageManager.zypper;
  return RemotePackageManager.unknown;
}

List<RemotePackage> parseInstalledPackages(
  RemotePackageManager pm,
  String raw,
) {
  final out = <RemotePackage>[];
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    switch (pm) {
      case RemotePackageManager.apt:
      case RemotePackageManager.dnf:
      case RemotePackageManager.yum:
      case RemotePackageManager.zypper:
        final i = t.indexOf('\t');
        if (i > 0) {
          out.add(
            RemotePackage(
              name: t.substring(0, i).trim(),
              version: t.substring(i + 1).trim(),
            ),
          );
        } else {
          final sp = t.split(RegExp(r'\s+'));
          if (sp.isNotEmpty) {
            out.add(
              RemotePackage(
                name: sp.first,
                version: sp.length > 1 ? sp.sublist(1).join(' ') : '',
              ),
            );
          }
        }
      case RemotePackageManager.pacman:
        final sp = t.split(RegExp(r'\s+'));
        if (sp.isNotEmpty) {
          out.add(
            RemotePackage(
              name: sp.first,
              version: sp.length > 1 ? sp.sublist(1).join(' ') : '',
            ),
          );
        }
      case RemotePackageManager.brew:
        final sp = t.split(RegExp(r'\s+'));
        if (sp.isNotEmpty) {
          out.add(
            RemotePackage(
              name: sp.first,
              version: sp.length > 1 ? sp.sublist(1).join(' ') : '',
            ),
          );
        }
      case RemotePackageManager.unknown:
        break;
    }
  }
  return out;
}

List<RemotePackage> parseSearchPackages(
  RemotePackageManager pm,
  String raw,
) {
  final out = <RemotePackage>[];
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    switch (pm) {
      case RemotePackageManager.apt:
        // name - description
        final m = RegExp(r'^(\S+)\s+-\s+(.*)$').firstMatch(t);
        if (m != null) {
          out.add(
            RemotePackage(
              name: m.group(1)!,
              description: m.group(2) ?? '',
              installed: false,
            ),
          );
        }
      case RemotePackageManager.dnf:
      case RemotePackageManager.yum:
        // name.arch : description  or  name.arch
        if (t.endsWith(':') || t.toLowerCase().contains('matched')) continue;
        final m = RegExp(r'^(\S+)\s*:\s*(.*)$').firstMatch(t);
        if (m != null) {
          final name = m.group(1)!.split('.').first;
          out.add(
            RemotePackage(
              name: name,
              description: m.group(2) ?? '',
              installed: false,
            ),
          );
        }
      case RemotePackageManager.pacman:
        // repo/name version
        final m = RegExp(r'^[^/\s]+/(\S+)\s+(\S+)').firstMatch(t);
        if (m != null) {
          out.add(
            RemotePackage(
              name: m.group(1)!,
              version: m.group(2) ?? '',
              installed: false,
            ),
          );
        }
      case RemotePackageManager.brew:
        if (!t.contains('==>') && !t.startsWith('If you')) {
          final name = t.split(RegExp(r'\s+')).first;
          if (name.isNotEmpty) {
            out.add(RemotePackage(name: name, installed: false));
          }
        }
      case RemotePackageManager.zypper:
        final parts = t.split('|');
        if (parts.length >= 3 && !parts[0].contains('-') && !t.startsWith('S ')) {
          final name = parts[1].trim();
          if (name.isNotEmpty && name != 'Name') {
            out.add(
              RemotePackage(
                name: name,
                version: parts.length > 3 ? parts[3].trim() : '',
                installed: false,
              ),
            );
          }
        }
      case RemotePackageManager.unknown:
        break;
    }
  }
  // 去重保序
  final seen = <String>{};
  return [
    for (final p in out)
      if (seen.add(p.name)) p,
  ];
}

String listInstalledCommand(RemotePackageManager pm, {int limit = 400}) {
  switch (pm) {
    case RemotePackageManager.apt:
      return "dpkg-query -W -f='\${Package}\\t\${Version}\\n' 2>/dev/null | head -n $limit";
    case RemotePackageManager.dnf:
    case RemotePackageManager.yum:
      return "rpm -qa --qf '%{NAME}\\t%{VERSION}-%{RELEASE}\\n' 2>/dev/null | sort | head -n $limit";
    case RemotePackageManager.pacman:
      return 'pacman -Q 2>/dev/null | head -n $limit';
    case RemotePackageManager.brew:
      return 'brew list --versions 2>/dev/null | head -n $limit';
    case RemotePackageManager.zypper:
      return "rpm -qa --qf '%{NAME}\\t%{VERSION}-%{RELEASE}\\n' 2>/dev/null | sort | head -n $limit";
    case RemotePackageManager.unknown:
      return 'true';
  }
}

String searchPackagesCommand(RemotePackageManager pm, String query) {
  final q = query.replaceAll("'", "'\\''");
  switch (pm) {
    case RemotePackageManager.apt:
      return "apt-cache search --names-only '$q' 2>/dev/null | head -n 80";
    case RemotePackageManager.dnf:
      return "dnf search -q '$q' 2>/dev/null | head -n 80";
    case RemotePackageManager.yum:
      return "yum search -q '$q' 2>/dev/null | head -n 80";
    case RemotePackageManager.pacman:
      return "pacman -Ss '$q' 2>/dev/null | head -n 80";
    case RemotePackageManager.brew:
      return "brew search '$q' 2>/dev/null | head -n 80";
    case RemotePackageManager.zypper:
      return "zypper search -t package '$q' 2>/dev/null | head -n 80";
    case RemotePackageManager.unknown:
      return 'true';
  }
}

/// 返回需要在远端执行的 install/remove 命令（可能含 sudo -n）。
String mutatePackageCommand(
  RemotePackageManager pm, {
  required String name,
  required bool install,
}) {
  final n = name.replaceAll("'", "'\\''");
  final sudo = 'sudo -n';
  switch (pm) {
    case RemotePackageManager.apt:
      return install
          ? "$sudo apt-get install -y '$n' 2>&1; echo __EC:\$?"
          : "$sudo apt-get remove -y '$n' 2>&1; echo __EC:\$?";
    case RemotePackageManager.dnf:
      return install
          ? "$sudo dnf install -y '$n' 2>&1; echo __EC:\$?"
          : "$sudo dnf remove -y '$n' 2>&1; echo __EC:\$?";
    case RemotePackageManager.yum:
      return install
          ? "$sudo yum install -y '$n' 2>&1; echo __EC:\$?"
          : "$sudo yum remove -y '$n' 2>&1; echo __EC:\$?";
    case RemotePackageManager.pacman:
      return install
          ? "$sudo pacman -S --noconfirm '$n' 2>&1; echo __EC:\$?"
          : "$sudo pacman -R --noconfirm '$n' 2>&1; echo __EC:\$?";
    case RemotePackageManager.brew:
      return install
          ? "brew install '$n' 2>&1; echo __EC:\$?"
          : "brew uninstall '$n' 2>&1; echo __EC:\$?";
    case RemotePackageManager.zypper:
      return install
          ? "$sudo zypper --non-interactive install '$n' 2>&1; echo __EC:\$?"
          : "$sudo zypper --non-interactive remove '$n' 2>&1; echo __EC:\$?";
    case RemotePackageManager.unknown:
      return 'echo unsupported; echo __EC:1';
  }
}

/// 给人看的「在终端执行」命令（交互式 sudo）。
String mutatePackageTerminalHint(
  RemotePackageManager pm, {
  required String name,
  required bool install,
}) {
  final n = name;
  switch (pm) {
    case RemotePackageManager.apt:
      return install
          ? "sudo apt-get install -y $n"
          : "sudo apt-get remove -y $n";
    case RemotePackageManager.dnf:
      return install ? "sudo dnf install -y $n" : "sudo dnf remove -y $n";
    case RemotePackageManager.yum:
      return install ? "sudo yum install -y $n" : "sudo yum remove -y $n";
    case RemotePackageManager.pacman:
      return install
          ? "sudo pacman -S --noconfirm $n"
          : "sudo pacman -R --noconfirm $n";
    case RemotePackageManager.brew:
      return install ? "brew install $n" : "brew uninstall $n";
    case RemotePackageManager.zypper:
      return install
          ? "sudo zypper install $n"
          : "sudo zypper remove $n";
    case RemotePackageManager.unknown:
      return '';
  }
}

Future<RemotePackageManager> detectPackageManager(
  SshWorkspaceController c,
) async {
  const cmd = r'''
for b in apt-get dnf yum pacman brew zypper; do
  if command -v "$b" >/dev/null 2>&1; then echo "$b"; exit 0; fi
done
echo none
''';
  final raw = await c.runQueued(cmd);
  if (raw == null) return RemotePackageManager.unknown;
  return parsePackageManagerDetect(raw.split(RegExp(r'\s')).first);
}

Future<RemotePackagesSnapshot?> fetchInstalledPackages(
  SshWorkspaceController c, {
  RemotePackageManager? manager,
  int limit = 400,
}) async {
  final pm = manager ?? await detectPackageManager(c);
  if (pm == RemotePackageManager.unknown) {
    return const RemotePackagesSnapshot(
      manager: RemotePackageManager.unknown,
      packages: [],
      error: '未检测到 apt/dnf/yum/pacman/brew/zypper',
    );
  }
  final raw = await c.runQueued(listInstalledCommand(pm, limit: limit));
  if (raw == null) return null;
  return RemotePackagesSnapshot(
    manager: pm,
    packages: parseInstalledPackages(pm, raw),
  );
}

Future<List<RemotePackage>?> searchRemotePackages(
  SshWorkspaceController c, {
  required RemotePackageManager manager,
  required String query,
}) async {
  final q = query.trim();
  if (q.isEmpty || q.length > 120) return const [];
  if (q.contains(RegExp(r'''[;|&`$<>'"\\\n]'''))) return const [];
  final raw = await c.runQueued(searchPackagesCommand(manager, q));
  if (raw == null) return null;
  return parseSearchPackages(manager, raw);
}

/// 返回 null 表示成功；否则为错误信息。
Future<String?> mutateRemotePackage(
  SshWorkspaceController c, {
  required RemotePackageManager manager,
  required String name,
  required bool install,
}) async {
  if (!isSafePackageName(name)) return '非法包名';
  final raw = await c.runQueued(
    mutatePackageCommand(manager, name: name, install: install),
    timeout: const Duration(minutes: 5),
  );
  if (raw == null) return '命令失败或已断开';
  final m = RegExp(r'__EC:(\d+)').firstMatch(raw);
  final ec = int.tryParse(m?.group(1) ?? '') ?? 1;
  if (ec == 0) return null;
  final msg = raw.replaceAll(RegExp(r'__EC:\d+\s*$'), '').trim();
  if (msg.toLowerCase().contains('password') ||
      msg.toLowerCase().contains('a password is required') ||
      msg.toLowerCase().contains('sudo: a password is required') ||
      msg.contains('sudo:')) {
    return '需要交互式 sudo。请在终端执行：\n${mutatePackageTerminalHint(manager, name: name, install: install)}';
  }
  return msg.isEmpty ? '操作失败 (exit $ec)' : msg;
}
