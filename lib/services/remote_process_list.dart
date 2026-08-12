import 'remote_exec_capable.dart';

/// 远端 OS 类型（进程列表命令分支）。
enum RemoteOsKind { linux, windows, unknown }

/// 单个远端进程。
class RemoteProcess {
  const RemoteProcess({
    required this.pid,
    required this.name,
    this.user,
    this.cpuPercent,
    this.memPercent,
    this.memoryBytes,
    this.session,
    this.cmdline,
    this.ppid,
    this.startTime,
  });

  final int pid;
  final String name;
  final String? user;
  final double? cpuPercent;
  final double? memPercent;

  /// 工作集 / RSS（字节）。
  final int? memoryBytes;
  final String? session;

  /// 完整命令行（详情拉取，列表通常为空）。
  final String? cmdline;

  /// 父进程 PID。
  final int? ppid;

  /// 启动时间（如 `ps` lstart / WMI CreationDate）。
  final String? startTime;
}

/// 进程详情（按需拉取，不进列表快照）。
class RemoteProcessDetail {
  const RemoteProcessDetail({
    required this.pid,
    this.cmdline,
    this.ppid,
    this.startTime,
    this.message,
  });

  final int pid;
  final String? cmdline;
  final int? ppid;
  final String? startTime;

  /// 不可用时的说明（如 Windows 拉取失败）。
  final String? message;
}

class RemoteProcessSnapshot {
  const RemoteProcessSnapshot({
    required this.os,
    required this.processes,
  });

  final RemoteOsKind os;
  final List<RemoteProcess> processes;
}

const String kRemoteOsProbe = r'''
if test -r /proc/meminfo; then echo linux
elif command -v tasklist.exe >/dev/null 2>&1; then echo windows
elif command -v tasklist >/dev/null 2>&1; then echo windows
else echo unknown
fi
''';

String get kRemoteOsProbeOneLine => kRemoteOsProbe.replaceAll('\n', ';');

/// Linux：pid user %cpu %mem rss(KB) comm — 空格对齐字段，最多 800 行。
const String kLinuxProcessList = r'''
ps -eo pid=,user:16=,pcpu=,pmem=,rss=,comm:48= --sort=-pcpu 2>/dev/null | head -n 800
''';

String get kLinuxProcessListOneLine =>
    kLinuxProcessList.replaceAll('\n', ';').trim();

/// Windows：优先 PowerShell Get-Process（含 CPU + WorkingSet + UserName）。
/// `-IncludeUserName` 在 Win8+/Win10+ 可用；失败时回退无用户列。
const String kWindowsProcessListPs =
    r'powershell -NoProfile -NonInteractive -Command "try { Get-Process -IncludeUserName | Select-Object Id,ProcessName,CPU,WorkingSet,UserName | ConvertTo-Csv -NoTypeInformation } catch { Get-Process | Select-Object Id,ProcessName,CPU,WorkingSet | ConvertTo-Csv -NoTypeInformation }"';

/// Windows OpenSSH 回退：CSV，无表头。
const String kWindowsProcessList =
    r'tasklist.exe /FO CSV /NH 2>nul || tasklist /FO CSV /NH';

Future<RemoteOsKind> detectRemoteOs(RemoteExecCapable controller) async {
  if (!controller.connected) return RemoteOsKind.unknown;
  final raw = await controller.runRemoteForStatus(kRemoteOsProbeOneLine);
  return parseRemoteOsKind(raw ?? '');
}

RemoteOsKind parseRemoteOsKind(String raw) {
  final line = raw
      .split(RegExp(r'[\r\n]+'))
      .map((e) => e.trim().toLowerCase())
      .firstWhere((e) => e.isNotEmpty, orElse: () => '');
  switch (line) {
    case 'linux':
      return RemoteOsKind.linux;
    case 'windows':
      return RemoteOsKind.windows;
    default:
      return RemoteOsKind.unknown;
  }
}

Future<RemoteProcessSnapshot?> fetchRemoteProcessSnapshot(
  RemoteExecCapable controller, {
  RemoteOsKind? osHint,
}) async {
  if (!controller.connected) return null;
  final os = osHint ?? await detectRemoteOs(controller);
  switch (os) {
    case RemoteOsKind.linux:
      final raw = await controller.runRemoteForStatus(kLinuxProcessListOneLine);
      return RemoteProcessSnapshot(
        os: RemoteOsKind.linux,
        processes: parseLinuxProcessList(raw ?? ''),
      );
    case RemoteOsKind.windows:
      return RemoteProcessSnapshot(
        os: RemoteOsKind.windows,
        processes: await _fetchWindowsProcesses(controller),
      );
    case RemoteOsKind.unknown:
      // 兜底：先试 Linux，再试 Windows。
      final linuxRaw =
          await controller.runRemoteForStatus(kLinuxProcessListOneLine);
      final linux = parseLinuxProcessList(linuxRaw ?? '');
      if (linux.isNotEmpty) {
        return RemoteProcessSnapshot(
          os: RemoteOsKind.linux,
          processes: linux,
        );
      }
      final win = await _fetchWindowsProcesses(controller);
      if (win.isNotEmpty) {
        return RemoteProcessSnapshot(
          os: RemoteOsKind.windows,
          processes: win,
        );
      }
      return const RemoteProcessSnapshot(
        os: RemoteOsKind.unknown,
        processes: [],
      );
  }
}

Future<List<RemoteProcess>> _fetchWindowsProcesses(
  RemoteExecCapable controller,
) async {
  final psRaw = await controller.runRemoteForStatus(kWindowsProcessListPs);
  final fromPs = parseWindowsGetProcessCsv(psRaw ?? '');
  if (fromPs.isNotEmpty) return fromPs;
  final raw = await controller.runRemoteForStatus(kWindowsProcessList);
  return parseWindowsTasklistCsv(raw ?? '');
}

/// 结束进程。[force] 为 true 时 Linux 用 SIGKILL、Windows 加 `/F`；
/// 为 false 时 Linux 用 SIGTERM、Windows 用不带 `/F` 的 `taskkill`。
Future<String?> killRemoteProcess(
  RemoteExecCapable controller, {
  required RemoteOsKind os,
  required int pid,
  bool force = true,
}) async {
  if (!controller.connected || pid <= 0) return '无效 PID';
  final String cmd;
  switch (os) {
    case RemoteOsKind.linux:
      cmd = force ? 'kill -KILL $pid' : 'kill -TERM $pid';
    case RemoteOsKind.windows:
      cmd = force
          ? 'taskkill.exe /PID $pid /F 2>nul || taskkill /PID $pid /F'
          : 'taskkill.exe /PID $pid 2>nul || taskkill /PID $pid';
    case RemoteOsKind.unknown:
      return '未知远端系统，无法结束进程';
  }
  final out = await controller.runRemoteForStatus(cmd);
  return out;
}

/// 按需拉取进程详情（cmdline / PPID / 启动时间）。列表命令保持不变以免破坏解析。
Future<RemoteProcessDetail?> fetchRemoteProcessDetail(
  RemoteExecCapable c, {
  required int pid,
  required RemoteOsKind os,
}) async {
  if (!c.connected || pid <= 0) return null;
  switch (os) {
    case RemoteOsKind.linux:
      final cmd = 'cmdline=\$(tr \'\\0\' \' \' < /proc/$pid/cmdline 2>/dev/null); '
          'ppid=\$(awk \'{print \$4}\' /proc/$pid/stat 2>/dev/null); '
          'start=\$(ps -o lstart= -p $pid 2>/dev/null | sed \'s/^[[:space:]]*//\'); '
          'printf \'CMDLINE:%s\\n\' "\$cmdline"; '
          'printf \'PPID:%s\\n\' "\$ppid"; '
          'printf \'START:%s\\n\' "\$start"';
      final raw = await c.runRemoteForStatus(cmd);
      if (raw == null) return null;
      return parseRemoteProcessDetail(pid, raw);
    case RemoteOsKind.windows:
      // OpenSSH + PowerShell 转义易碎；尽力拉取，失败则带说明返回。
      final cmd = 'powershell -NoProfile -NonInteractive -Command '
          '"\$p = Get-CimInstance Win32_Process -Filter \'ProcessId = $pid\' '
          '-ErrorAction SilentlyContinue; '
          'if (\$null -eq \$p) { \'NOTFOUND\' } else { '
          '\'CMDLINE:\' + \$p.CommandLine; '
          '\'PPID:\' + \$p.ParentProcessId; '
          '\'START:\' + \$p.CreationDate }"';
      final raw = await c.runRemoteForStatus(cmd);
      if (raw == null ||
          raw.trim().isEmpty ||
          raw.trim().startsWith('NOTFOUND')) {
        return RemoteProcessDetail(
          pid: pid,
          message: 'Windows 下无法获取进程详情',
        );
      }
      final parsed = parseRemoteProcessDetail(pid, raw);
      if (parsed.cmdline == null &&
          parsed.ppid == null &&
          parsed.startTime == null) {
        return RemoteProcessDetail(
          pid: pid,
          message: 'Windows 下无法获取进程详情',
        );
      }
      return parsed;
    case RemoteOsKind.unknown:
      return RemoteProcessDetail(
        pid: pid,
        message: '未知远端系统，无法获取进程详情',
      );
  }
}

RemoteProcessDetail parseRemoteProcessDetail(int pid, String raw) {
  String? cmdline;
  int? ppid;
  String? start;
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trimRight();
    if (t.startsWith('CMDLINE:')) {
      cmdline = t.substring('CMDLINE:'.length).trim();
      if (cmdline.isEmpty) cmdline = null;
    } else if (t.startsWith('PPID:')) {
      ppid = int.tryParse(t.substring('PPID:'.length).trim());
    } else if (t.startsWith('START:')) {
      start = t.substring('START:'.length).trim();
      if (start.isEmpty) start = null;
    }
  }
  return RemoteProcessDetail(
    pid: pid,
    cmdline: cmdline,
    ppid: ppid,
    startTime: start,
  );
}

List<RemoteProcess> parseLinuxProcessList(String raw) {
  if (raw.isEmpty) return const [];
  final out = <RemoteProcess>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final m = RegExp(
      r'^(\d+)\s+(\S+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+(.+)$',
    ).firstMatch(t);
    if (m == null) continue;
    final pid = int.tryParse(m.group(1)!);
    if (pid == null || pid <= 0) continue;
    final cpu = double.tryParse(m.group(3)!);
    final memPct = double.tryParse(m.group(4)!);
    final rssKb = int.tryParse(m.group(5)!);
    out.add(
      RemoteProcess(
        pid: pid,
        user: m.group(2),
        cpuPercent: cpu,
        memPercent: memPct,
        memoryBytes: rssKb == null ? null : rssKb * 1024,
        name: m.group(6)!.trim(),
      ),
    );
  }
  return out;
}

/// 解析 `Get-Process | ConvertTo-Csv`。
/// 列：Id, ProcessName, CPU, WorkingSet（字节）[, UserName]。
/// CPU 为累计秒数，填入 [RemoteProcess.cpuPercent] 供排序/展示。
List<RemoteProcess> parseWindowsGetProcessCsv(String raw) {
  if (raw.isEmpty) return const [];
  final out = <RemoteProcess>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final cols = _parseCsvLine(t);
    if (cols.length < 4) continue;
    final idRaw = cols[0].trim();
    // 跳过表头
    if (idRaw.toLowerCase() == 'id') continue;
    final pid = int.tryParse(idRaw);
    final name = cols[1].trim();
    if (pid == null || pid <= 0 || name.isEmpty) continue;
    final cpuRaw = cols[2].trim();
    final cpu = cpuRaw.isEmpty ? null : double.tryParse(cpuRaw);
    final wsRaw = cols[3].trim();
    final ws = wsRaw.isEmpty ? null : int.tryParse(wsRaw);
    final userRaw = cols.length >= 5 ? cols[4].trim() : '';
    out.add(
      RemoteProcess(
        pid: pid,
        name: name,
        user: userRaw.isEmpty ? null : userRaw,
        cpuPercent: cpu,
        memoryBytes: ws,
      ),
    );
  }
  out.sort((a, b) => (b.memoryBytes ?? 0).compareTo(a.memoryBytes ?? 0));
  return out;
}

/// 解析 `tasklist /FO CSV /NH`。
/// 列：Image Name, PID, Session Name, Session#, Mem Usage
List<RemoteProcess> parseWindowsTasklistCsv(String raw) {
  if (raw.isEmpty) return const [];
  final out = <RemoteProcess>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final cols = _parseCsvLine(t);
    if (cols.length < 5) continue;
    final name = cols[0].trim();
    final pid = int.tryParse(cols[1].trim());
    if (pid == null || pid <= 0 || name.isEmpty) continue;
    final session = cols[2].trim();
    final mem = _parseWindowsMemUsage(cols[4]);
    out.add(
      RemoteProcess(
        pid: pid,
        name: name,
        session: session.isEmpty ? null : session,
        memoryBytes: mem,
      ),
    );
  }
  // 按内存降序，贴近任务管理器默认观感
  out.sort((a, b) => (b.memoryBytes ?? 0).compareTo(a.memoryBytes ?? 0));
  return out;
}

/// `"a","b","c"` 或混用引号的简单 CSV 行。
List<String> _parseCsvLine(String line) {
  final result = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buf.write(ch);
      }
    } else {
      if (ch == '"') {
        inQuotes = true;
      } else if (ch == ',') {
        result.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
  }
  result.add(buf.toString());
  return result;
}

/// `12,345 K` / `1,234,567 K` → bytes。
int? _parseWindowsMemUsage(String raw) {
  final t = raw.trim().toUpperCase().replaceAll('"', '');
  final m = RegExp(r'([\d,]+)\s*K').firstMatch(t);
  if (m != null) {
    final kb = int.tryParse(m.group(1)!.replaceAll(',', ''));
    if (kb != null) return kb * 1024;
  }
  final n = int.tryParse(t.replaceAll(RegExp(r'[^\d]'), ''));
  if (n != null && n > 0) return n * 1024;
  return null;
}

String formatProcessMemory(int? bytes) {
  if (bytes == null || bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

enum RemoteServiceAction { start, stop, restart }

class RemoteService {
  const RemoteService({
    required this.name,
    required this.status,
    this.displayName,
    this.startType,
    this.subState,
  });

  final String name;
  final String status;
  final String? displayName;
  final String? startType;
  final String? subState;

  bool get isRunning {
    final s = status.toLowerCase();
    return s == 'running' || s.startsWith('active');
  }
}

class RemoteServiceSnapshot {
  const RemoteServiceSnapshot({
    required this.os,
    required this.services,
  });

  final RemoteOsKind os;
  final List<RemoteService> services;
}

/// Linux systemctl：UNIT LOAD ACTIVE SUB DESCRIPTION
const String kLinuxServiceList =
    r'systemctl list-units --type=service --all --no-legend --plain --no-pager 2>/dev/null | head -n 600';

/// Windows：Name|Status|StartType|DisplayName
const String kWindowsServiceList =
    r'''powershell -NoProfile -NonInteractive -Command "Get-Service | ForEach-Object { $_.Name + '|' + $_.Status + '|' + $_.StartType + '|' + ($_.DisplayName -replace '[|\r\n]',' ') }"''';

bool isSafeRemoteServiceName(String name) {
  if (name.isEmpty || name.length > 128) return false;
  return RegExp(r'^[A-Za-z0-9_@.\-]+$').hasMatch(name);
}

Future<RemoteServiceSnapshot?> fetchRemoteServiceSnapshot(
  RemoteExecCapable controller, {
  RemoteOsKind? osHint,
}) async {
  if (!controller.connected) return null;
  final os = osHint ?? await detectRemoteOs(controller);
  switch (os) {
    case RemoteOsKind.linux:
      final raw = await controller.runRemoteForStatus(kLinuxServiceList);
      return RemoteServiceSnapshot(
        os: RemoteOsKind.linux,
        services: parseLinuxServiceList(raw ?? ''),
      );
    case RemoteOsKind.windows:
      final raw = await controller.runRemoteForStatus(kWindowsServiceList);
      return RemoteServiceSnapshot(
        os: RemoteOsKind.windows,
        services: parseWindowsServiceList(raw ?? ''),
      );
    case RemoteOsKind.unknown:
      final linuxRaw = await controller.runRemoteForStatus(kLinuxServiceList);
      final linux = parseLinuxServiceList(linuxRaw ?? '');
      if (linux.isNotEmpty) {
        return RemoteServiceSnapshot(
          os: RemoteOsKind.linux,
          services: linux,
        );
      }
      final winRaw = await controller.runRemoteForStatus(kWindowsServiceList);
      final win = parseWindowsServiceList(winRaw ?? '');
      if (win.isNotEmpty) {
        return RemoteServiceSnapshot(
          os: RemoteOsKind.windows,
          services: win,
        );
      }
      return const RemoteServiceSnapshot(
        os: RemoteOsKind.unknown,
        services: [],
      );
  }
}

Future<String?> controlRemoteService(
  RemoteExecCapable controller, {
  required RemoteOsKind os,
  required String name,
  required RemoteServiceAction action,
}) async {
  if (!controller.connected) return '未连接';
  if (!isSafeRemoteServiceName(name)) return '非法服务名';
  final String cmd;
  switch (os) {
    case RemoteOsKind.linux:
      final verb = switch (action) {
        RemoteServiceAction.start => 'start',
        RemoteServiceAction.stop => 'stop',
        RemoteServiceAction.restart => 'restart',
      };
      cmd = 'systemctl $verb $name';
    case RemoteOsKind.windows:
      cmd = switch (action) {
        RemoteServiceAction.start =>
          'sc.exe start $name 2>nul || net start $name',
        RemoteServiceAction.stop =>
          'sc.exe stop $name 2>nul || net stop $name',
        RemoteServiceAction.restart =>
          '(sc.exe stop $name 2>nul || net stop $name) & (sc.exe start $name 2>nul || net start $name)',
      };
    case RemoteOsKind.unknown:
      return '未知远端系统';
  }
  return controller.runRemoteForStatus(cmd);
}

List<RemoteService> parseLinuxServiceList(String raw) {
  if (raw.isEmpty) return const [];
  final out = <RemoteService>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 4) continue;
    final name = parts[0];
    if (name.isEmpty) continue;
    final active = parts[2];
    final sub = parts[3];
    final display =
        parts.length > 4 ? parts.sublist(4).join(' ') : null;
    out.add(
      RemoteService(
        name: name,
        status: active,
        subState: sub,
        displayName: display,
        startType: parts[1], // LOAD
      ),
    );
  }
  out.sort((a, b) {
    final ar = a.isRunning ? 0 : 1;
    final br = b.isRunning ? 0 : 1;
    if (ar != br) return ar - br;
    return a.name.compareTo(b.name);
  });
  return out;
}

/// `Name|Status|StartType|DisplayName`
List<RemoteService> parseWindowsServiceList(String raw) {
  if (raw.isEmpty) return const [];
  final out = <RemoteService>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final parts = t.split('|');
    if (parts.length < 2) continue;
    final name = parts[0].trim();
    if (name.isEmpty || name.toLowerCase() == 'name') continue;
    final status = parts[1].trim();
    final startType = parts.length > 2 ? parts[2].trim() : null;
    final display = parts.length > 3 ? parts.sublist(3).join('|').trim() : null;
    out.add(
      RemoteService(
        name: name,
        status: status,
        startType: startType,
        displayName: (display == null || display.isEmpty) ? null : display,
      ),
    );
  }
  out.sort((a, b) {
    final ar = a.isRunning ? 0 : 1;
    final br = b.isRunning ? 0 : 1;
    if (ar != br) return ar - br;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}
