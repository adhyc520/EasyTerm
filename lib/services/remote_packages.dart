import 'remote_sudo.dart';
import 'remote_exec_capable.dart';

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

/// 包版本号（可选）；仅允许常见版本字符。
bool isSafePackageVersion(String version) {
  if (version.isEmpty || version.length > 120) return false;
  return RegExp(r'^[A-Za-z0-9.+~:_-]+$').hasMatch(version);
}

/// 安装目标：apt 用 `name=ver`，dnf/yum 用 `name-ver`，brew 用 `name@ver`；其它忽略版本。
String packageInstallTarget(
  RemotePackageManager pm,
  String name, {
  String? version,
}) {
  final v = version?.trim() ?? '';
  if (v.isEmpty || !isSafePackageVersion(v)) return name;
  switch (pm) {
    case RemotePackageManager.apt:
      return '$name=$v';
    case RemotePackageManager.dnf:
    case RemotePackageManager.yum:
      return '$name-$v';
    case RemotePackageManager.brew:
      return '$name@$v';
    case RemotePackageManager.pacman:
    case RemotePackageManager.zypper:
    case RemotePackageManager.unknown:
      return name;
  }
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

String listInstalledCommand(
  RemotePackageManager pm, {
  int limit = 20000,
  String? nameFilter,
}) {
  final filter = nameFilter?.trim() ?? '';
  // 仅允许包名通配安全字符，避免注入。
  final useFilter =
      filter.isNotEmpty && RegExp(r'^[A-Za-z0-9+._:@/-]+$').hasMatch(filter);
  final head = limit > 0 ? ' | head -n $limit' : '';

  switch (pm) {
    case RemotePackageManager.apt:
      if (useFilter) {
        final pat = filter.replaceAll("'", "'\\''");
        return "dpkg-query -W -f='\${Package}\\t\${Version}\\n' '*$pat*' 2>/dev/null$head";
      }
      return "dpkg-query -W -f='\${Package}\\t\${Version}\\n' 2>/dev/null$head";
    case RemotePackageManager.dnf:
    case RemotePackageManager.yum:
    case RemotePackageManager.zypper:
      if (useFilter) {
        final pat = filter.replaceAll("'", "'\\''");
        return "rpm -qa --qf '%{NAME}\\t%{VERSION}-%{RELEASE}\\n' 2>/dev/null | "
            "grep -iF -- '$pat' | sort$head";
      }
      return "rpm -qa --qf '%{NAME}\\t%{VERSION}-%{RELEASE}\\n' 2>/dev/null | sort$head";
    case RemotePackageManager.pacman:
      if (useFilter) {
        final pat = filter.replaceAll("'", "'\\''");
        return "pacman -Q 2>/dev/null | grep -iF -- '$pat'$head";
      }
      return 'pacman -Q 2>/dev/null$head';
    case RemotePackageManager.brew:
      if (useFilter) {
        final pat = filter.replaceAll("'", "'\\''");
        return "brew list --versions 2>/dev/null | grep -iF -- '$pat'$head";
      }
      return 'brew list --versions 2>/dev/null$head';
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

/// 返回需要在远端执行的 install/remove 命令（可能含 sudo -n / sudo -S）。
String mutatePackageCommand(
  RemotePackageManager pm, {
  required String name,
  required bool install,
  String? version,
  bool sudoWithStdin = false,
}) {
  final core = mutatePackageStreamCommand(
    pm,
    name: name,
    install: install,
    version: version,
    sudoWithStdin: sudoWithStdin,
  );
  return '$core; echo __EC:\$?';
}

/// 流式安装/卸载命令（无 `__EC` 尾标，退出码走 SSH session）。
///
/// [version] 仅在 [install] 时生效（见 [packageInstallTarget]）。
String mutatePackageStreamCommand(
  RemotePackageManager pm, {
  required String name,
  required bool install,
  String? version,
  bool sudoWithStdin = false,
}) {
  final target = install
      ? packageInstallTarget(pm, name, version: version)
      : name;
  final n = target.replaceAll("'", "'\\''");
  final sudo = sudoWithStdin ? "sudo -S -p ''" : 'sudo -n';
  switch (pm) {
    case RemotePackageManager.apt:
      return install
          ? "$sudo apt-get install -y '$n' 2>&1"
          : "$sudo apt-get remove -y '$n' 2>&1";
    case RemotePackageManager.dnf:
      return install
          ? "$sudo dnf install -y '$n' 2>&1"
          : "$sudo dnf remove -y '$n' 2>&1";
    case RemotePackageManager.yum:
      return install
          ? "$sudo yum install -y '$n' 2>&1"
          : "$sudo yum remove -y '$n' 2>&1";
    case RemotePackageManager.pacman:
      return install
          ? "$sudo pacman -S --noconfirm '$n' 2>&1"
          : "$sudo pacman -R --noconfirm '$n' 2>&1";
    case RemotePackageManager.brew:
      return install ? "brew install '$n' 2>&1" : "brew uninstall '$n' 2>&1";
    case RemotePackageManager.zypper:
      return install
          ? "$sudo zypper --non-interactive install '$n' 2>&1"
          : "$sudo zypper --non-interactive remove '$n' 2>&1";
    case RemotePackageManager.unknown:
      // 保持非零退出：mutatePackageCommand 会追加 `__EC:$?`。
      return 'echo unsupported; false';
  }
}

/// 全量升级命令（流式，无 `__EC` 尾标）。
String upgradeAllPackagesStreamCommand(
  RemotePackageManager pm, {
  bool sudoWithStdin = false,
}) {
  final sudo = sudoWithStdin ? "sudo -S -p ''" : 'sudo -n';
  switch (pm) {
    case RemotePackageManager.apt:
      return '$sudo apt-get upgrade -y 2>&1';
    case RemotePackageManager.dnf:
      return '$sudo dnf upgrade -y 2>&1';
    case RemotePackageManager.yum:
      return '$sudo yum update -y 2>&1';
    case RemotePackageManager.pacman:
      return '$sudo pacman -Syu --noconfirm 2>&1';
    case RemotePackageManager.brew:
      return 'brew upgrade 2>&1';
    case RemotePackageManager.zypper:
      return '$sudo zypper --non-interactive update 2>&1';
    case RemotePackageManager.unknown:
      return 'echo unsupported; false';
  }
}

String upgradeAllPackagesTerminalHint(RemotePackageManager pm) {
  switch (pm) {
    case RemotePackageManager.apt:
      return 'sudo apt-get upgrade -y';
    case RemotePackageManager.dnf:
      return 'sudo dnf upgrade -y';
    case RemotePackageManager.yum:
      return 'sudo yum update -y';
    case RemotePackageManager.pacman:
      return 'sudo pacman -Syu --noconfirm';
    case RemotePackageManager.brew:
      return 'brew upgrade';
    case RemotePackageManager.zypper:
      return 'sudo zypper update';
    case RemotePackageManager.unknown:
      return '';
  }
}

/// 给人看的「在终端执行」命令（交互式 sudo）。
String mutatePackageTerminalHint(
  RemotePackageManager pm, {
  required String name,
  required bool install,
  String? version,
}) {
  final n = install
      ? packageInstallTarget(pm, name, version: version)
      : name;
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
  RemoteExecCapable c,
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
  RemoteExecCapable c, {
  RemotePackageManager? manager,
  int limit = 20000,
  String? nameFilter,
}) async {
  final pm = manager ?? await detectPackageManager(c);
  if (pm == RemotePackageManager.unknown) {
    return const RemotePackagesSnapshot(
      manager: RemotePackageManager.unknown,
      packages: [],
      error: '未检测到 apt/dnf/yum/pacman/brew/zypper',
    );
  }
  final raw = await c.runQueued(
    listInstalledCommand(pm, limit: limit, nameFilter: nameFilter),
    timeout: const Duration(seconds: 45),
  );
  if (raw == null) return null;
  return RemotePackagesSnapshot(
    manager: pm,
    packages: parseInstalledPackages(pm, raw),
  );
}

Future<List<RemotePackage>?> searchRemotePackages(
  RemoteExecCapable c, {
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
///
/// [sudoPassword] 非空时用 `sudo -S` 并从 stdin 注入密码。
Future<String?> mutateRemotePackage(
  RemoteExecCapable c, {
  required RemotePackageManager manager,
  required String name,
  required bool install,
  String? version,
  String? sudoPassword,
}) async {
  if (!isSafePackageName(name)) return '非法包名';
  final v = version?.trim() ?? '';
  if (v.isNotEmpty && !isSafePackageVersion(v)) return '非法版本号';
  final usePwd = sudoPassword != null && sudoPassword.isNotEmpty;
  final raw = await c.runQueued(
    mutatePackageCommand(
      manager,
      name: name,
      install: install,
      version: v.isEmpty ? null : v,
      sudoWithStdin: usePwd,
    ),
    timeout: const Duration(minutes: 5),
    stdinBytes: usePwd ? RemoteSudo.passwordStdin(sudoPassword) : null,
  );
  return RemoteSudo.interpretExit(
    raw,
    usedPassword: usePwd,
    terminalHint: mutatePackageTerminalHint(
      manager,
      name: name,
      install: install,
      version: v.isEmpty ? null : v,
    ),
  );
}

String? listPackageFilesCommand(RemotePackageManager pm, String name) {
  if (!isSafePackageName(name)) return null;
  final n = name.replaceAll("'", "'\\''");
  switch (pm) {
    case RemotePackageManager.apt:
      return "dpkg -L '$n' 2>/dev/null | head -n 500";
    case RemotePackageManager.dnf:
    case RemotePackageManager.yum:
    case RemotePackageManager.zypper:
      return "rpm -ql '$n' 2>/dev/null | head -n 500";
    case RemotePackageManager.pacman:
      return "pacman -Ql '$n' 2>/dev/null | head -n 500";
    case RemotePackageManager.brew:
    case RemotePackageManager.unknown:
      return null;
  }
}

List<String> parsePackageFiles(RemotePackageManager pm, String raw) {
  if (raw.isEmpty) return const [];
  final out = <String>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (pm == RemotePackageManager.pacman) {
      // `pkgname /path/to/file`
      final i = t.indexOf(' /');
      if (i >= 0) {
        out.add(t.substring(i + 1).trim());
      } else {
        final sp = t.indexOf(' ');
        out.add(sp > 0 ? t.substring(sp + 1).trim() : t);
      }
    } else {
      out.add(t);
    }
  }
  return out;
}

/// 列出已安装包的文件路径（最多 500）。不支持的包管理器返回 null。
Future<List<String>?> listPackageFiles(
  RemoteExecCapable c, {
  required RemotePackageManager pm,
  required String name,
}) async {
  final cmd = listPackageFilesCommand(pm, name);
  if (cmd == null) return null;
  final raw = await c.runQueued(cmd, timeout: const Duration(seconds: 30));
  if (raw == null) return null;
  return parsePackageFiles(pm, raw);
}

/// 卸载 dry-run 命令。优先 `apt-get -s`；brew 用 `uninstall --dry-run`（Homebrew 3+）。
String? simulateRemoveCommand(RemotePackageManager pm, String name) {
  if (!isSafePackageName(name)) return null;
  final n = name.replaceAll("'", "'\\''");
  switch (pm) {
    case RemotePackageManager.apt:
      return "apt-get -s remove '$n' 2>&1";
    case RemotePackageManager.dnf:
      return "dnf remove -y --setopt=tsflags=test '$n' 2>&1";
    case RemotePackageManager.yum:
      return "yum --assumeno remove '$n' 2>&1";
    case RemotePackageManager.brew:
      return "brew uninstall --dry-run '$n' 2>&1";
    case RemotePackageManager.pacman:
    case RemotePackageManager.zypper:
    case RemotePackageManager.unknown:
      return null;
  }
}

/// 从 dry-run 输出解析将受影响的包名（去重保序）。
List<String> parseRemoveSimulation(RemotePackageManager pm, String raw) {
  final out = <String>[];
  final seen = <String>{};
  void add(String name) {
    final n = name.trim();
    if (n.isEmpty || !seen.add(n)) return;
    out.add(n);
  }

  switch (pm) {
    case RemotePackageManager.apt:
      var inRemoved = false;
      for (final line in raw.split(RegExp(r'\r?\n'))) {
        final t = line.trim();
        if (t.isEmpty) continue;
        final remv = RegExp(r'^Remv\s+(\S+)').firstMatch(t);
        if (remv != null) {
          add(remv.group(1)!);
          continue;
        }
        if (t.toLowerCase().contains('will be removed')) {
          inRemoved = true;
          continue;
        }
        if (inRemoved) {
          if (t.endsWith(':') ||
              t.toLowerCase().startsWith('the following') ||
              RegExp(r'^\d+\s+(upgraded|newly|to\s+remove)', caseSensitive: false)
                  .hasMatch(t)) {
            inRemoved = false;
            continue;
          }
          for (final part in t.split(RegExp(r'\s+'))) {
            if (part.isNotEmpty && !part.startsWith('*')) add(part);
          }
        }
      }
    case RemotePackageManager.dnf:
    case RemotePackageManager.yum:
      for (final line in raw.split(RegExp(r'\r?\n'))) {
        final t = line.trim();
        // `Removing: pkg` / `Removing pkg` / transaction table rows
        final m = RegExp(
          r'^(?:Removing|Erasing)[:\s]+(\S+)',
          caseSensitive: false,
        ).firstMatch(t);
        if (m != null) add(m.group(1)!.split('.').first);
      }
    case RemotePackageManager.brew:
      // `brew uninstall --dry-run` 列出 formula 名；跳过英文说明行。
      for (final line in raw.split(RegExp(r'\r?\n'))) {
        final t = line.trim();
        if (t.isEmpty) continue;
        final lower = t.toLowerCase();
        if (lower.startsWith('would ') ||
            lower.startsWith('==>') ||
            (lower.contains('formula') && lower.contains('uninstall')) ||
            lower.startsWith('error:') ||
            lower.startsWith('warning:')) {
          continue;
        }
        // 可能是缩进的包名，或 "Uninstalling foo..." 行。
        final un = RegExp(
          r'^Uninstalling\s+(\S+)',
          caseSensitive: false,
        ).firstMatch(t);
        if (un != null) {
          add(un.group(1)!.replaceAll(RegExp(r'[.:]+$'), ''));
          continue;
        }
        final token = t.split(RegExp(r'\s+')).first;
        if (isSafePackageName(token) &&
            !const {
              'would',
              'uninstall',
              'uninstalling',
              'formula',
              'formulae',
              'cask',
              'casks',
            }.contains(token.toLowerCase())) {
          add(token);
        }
      }
    case RemotePackageManager.pacman:
    case RemotePackageManager.zypper:
    case RemotePackageManager.unknown:
      break;
  }
  return out;
}

/// 模拟卸载并返回受影响包名；不支持或失败时返回 null。
Future<List<String>?> fetchRemoveImpact(
  RemoteExecCapable c, {
  required RemotePackageManager manager,
  required String name,
}) async {
  final cmd = simulateRemoveCommand(manager, name);
  if (cmd == null || cmd.isEmpty) return null;
  final raw = await c.runQueued(cmd, timeout: const Duration(seconds: 60));
  if (raw == null) return null;
  final parsed = parseRemoveSimulation(manager, raw);
  // brew dry-run 若解析为空，回退 `brew uses --installed` 作依赖影响提示。
  if (manager == RemotePackageManager.brew &&
      parsed.isEmpty &&
      isSafePackageName(name)) {
    final n = name.replaceAll("'", "'\\''");
    final uses = await c.runQueued(
      "brew uses --installed '$n' 2>/dev/null | head -n 80",
      timeout: const Duration(seconds: 30),
    );
    if (uses != null && uses.trim().isNotEmpty) {
      final deps = <String>[];
      final seen = <String>{name};
      for (final line in uses.split(RegExp(r'\r?\n'))) {
        final t = line.trim().split(RegExp(r'\s+')).first;
        if (t.isNotEmpty && isSafePackageName(t) && seen.add(t)) deps.add(t);
      }
      if (deps.isNotEmpty) return [name, ...deps];
    }
    return [name];
  }
  return parsed;
}

String? packageVersionsCommand(RemotePackageManager pm, String name) {
  if (!isSafePackageName(name)) return null;
  final n = name.replaceAll("'", "'\\''");
  switch (pm) {
    case RemotePackageManager.apt:
      return "apt-cache madison '$n' 2>/dev/null | head -n 30";
    case RemotePackageManager.dnf:
      return "dnf repoquery -q --qf '%{version}-%{release}' '$n' 2>/dev/null | "
          'head -n 30';
    case RemotePackageManager.yum:
      return "repoquery -q --qf '%{version}-%{release}' '$n' 2>/dev/null | "
          'head -n 30';
    case RemotePackageManager.pacman:
    case RemotePackageManager.brew:
    case RemotePackageManager.zypper:
    case RemotePackageManager.unknown:
      return null;
  }
}

/// 从版本列表命令输出解析版本字符串（去重保序）。
List<String> parsePackageVersions(RemotePackageManager pm, String raw) {
  final out = <String>[];
  final seen = <String>{};
  void add(String v) {
    final t = v.trim();
    if (t.isEmpty || !isSafePackageVersion(t) || !seen.add(t)) return;
    out.add(t);
  }

  switch (pm) {
    case RemotePackageManager.apt:
      // `name | version | repo`
      for (final line in raw.split(RegExp(r'\r?\n'))) {
        final parts = line.split('|');
        if (parts.length >= 2) {
          add(parts[1].trim().split(RegExp(r'\s+')).first);
        }
      }
    case RemotePackageManager.dnf:
    case RemotePackageManager.yum:
      for (final line in raw.split(RegExp(r'\r?\n'))) {
        final t = line.trim();
        if (t.isEmpty || t.toLowerCase().startsWith('last metadata')) continue;
        // repoquery: bare version-release; list --showduplicates: name.arch ver repo
        if (t.contains('|')) {
          final parts = t.split('|');
          if (parts.length >= 2) add(parts[1].trim());
          continue;
        }
        final sp = t.split(RegExp(r'\s+'));
        if (sp.length == 1) {
          add(sp.first);
        } else if (sp.length >= 2 && !sp.first.toLowerCase().startsWith('available')) {
          // skip header-ish first token if it looks like name.arch
          final ver = sp.length >= 2 ? sp[1] : sp.first;
          if (ver.contains('.') || ver.contains('-') || RegExp(r'^\d').hasMatch(ver)) {
            add(ver);
          } else {
            add(sp.first);
          }
        }
      }
    case RemotePackageManager.pacman:
    case RemotePackageManager.brew:
    case RemotePackageManager.zypper:
    case RemotePackageManager.unknown:
      break;
  }
  return out;
}

/// 查询可安装版本候选；不支持或失败时返回 null。
Future<List<String>?> fetchPackageVersions(
  RemoteExecCapable c, {
  required RemotePackageManager manager,
  required String name,
}) async {
  final cmd = packageVersionsCommand(manager, name);
  if (cmd == null || cmd.isEmpty) return null;
  final raw = await c.runQueued(cmd, timeout: const Duration(seconds: 45));
  if (raw == null) return null;
  return parsePackageVersions(manager, raw);
}
