import 'ssh_workspace_controller.dart';

/// 远端主机一次采样的资源快照（Linux：/proc + df + vmstat）。
class RemoteHostSnapshot {
  const RemoteHostSnapshot({
    this.memUsed01,
    this.cpuUsed01,
    this.diskUsed01,
    this.inodeUsed01,
    this.loadPressure01,
    this.loadLine,
    this.dfSpaceLine,
    this.dfInodeLine,
    this.uptimeLine,
  });

  final double? memUsed01;
  final double? cpuUsed01;
  final double? diskUsed01;
  final double? inodeUsed01;
  final double? loadPressure01;
  final String? loadLine;
  final String? dfSpaceLine;
  final String? dfInodeLine;
  final String? uptimeLine;

  static RemoteHostSnapshot? parse(String raw) {
    if (raw.isEmpty) return null;
    const a = '__A__';
    const b = '__B__';
    const c = '__C__';
    const d = '__D__';
    const e = '__E__';
    const f = '__F__';
    const g = '__G__';
    const z = '__Z__';
    if (!raw.contains(a)) return null;

    String section(String start, String end) {
      final i0 = raw.indexOf(start);
      if (i0 < 0) return '';
      var from = i0 + start.length;
      while (from < raw.length && (raw[from] == '\n' || raw[from] == '\r')) {
        from++;
      }
      final i1 = raw.indexOf(end, from);
      if (i1 < 0) return raw.substring(from).trim();
      return raw.substring(from, i1).trim();
    }

    final memBlock = section(a, b);
    final vmBlock = section(b, c);
    final dfP = section(c, d);
    final dfPi = section(d, e);
    final loadBlock = section(e, f);
    final nprocBlock = section(f, g);
    final uptimeBlock = section(g, z);

    final mem = _parseMeminfo(memBlock);
    final cpu = _parseVmstatIdle(vmBlock);
    final disk = _parseDfPercent(dfP);
    final inode = _parseDfPercent(dfPi);
    final loadParts = _parseLoadavg(loadBlock);
    final nproc = int.tryParse(nprocBlock.split('\n').first.trim()) ?? 1;
    double? loadPressure;
    if (loadParts != null && loadParts.isNotEmpty && nproc > 0) {
      loadPressure = (loadParts[0] / nproc).clamp(0.0, 1.0);
    }

    final uptime = uptimeBlock
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join(' ');

    return RemoteHostSnapshot(
      memUsed01: mem,
      cpuUsed01: cpu,
      diskUsed01: disk,
      inodeUsed01: inode,
      loadPressure01: loadPressure,
      loadLine: loadParts?.map((e) => e.toStringAsFixed(2)).join(', '),
      dfSpaceLine: dfP.isEmpty ? null : dfP.replaceAll('|', ' '),
      dfInodeLine: dfPi.isEmpty ? null : dfPi.replaceAll('|', ' '),
      uptimeLine: uptime.isEmpty ? null : uptime,
    );
  }
}

/// 多段输出：避免远端 awk 引号问题，在客户端解析。
const String kRemoteStatusBundle = r'''
printf '__A__\n'
cat /proc/meminfo 2>/dev/null
printf '__B__\n'
vmstat 1 2 2>/dev/null
printf '__C__\n'
df -P / 2>/dev/null | tail -n 1
printf '__D__\n'
df -Pi / 2>/dev/null | tail -n 1
printf '__E__\n'
cat /proc/loadavg 2>/dev/null
printf '__F__\n'
nproc 2>/dev/null || echo 1
printf '__G__\n'
uptime 2>/dev/null || true
printf '__Z__\n'
''';

String get kRemoteStatusBundleOneLine =>
    kRemoteStatusBundle.replaceAll('\n', ';');

Future<RemoteHostSnapshot?> fetchRemoteHostSnapshot(
  SshWorkspaceController controller,
) async {
  if (!controller.connected) return null;
  final bundle = await controller.runRemoteForStatus(kRemoteStatusBundleOneLine);
  return RemoteHostSnapshot.parse(bundle ?? '');
}

double? _parseMeminfo(String block) {
  if (block.isEmpty) return null;
  int? kb(String prefix) {
    for (final line in block.split('\n')) {
      final t = line.trim();
      if (!t.startsWith(prefix)) continue;
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length >= 2) return int.tryParse(parts[1]);
    }
    return null;
  }

  final total = kb('MemTotal:');
  final avail = kb('MemAvailable:');
  if (total != null && total > 0 && avail != null) {
    return ((total - avail) / total).clamp(0.0, 1.0);
  }
  final free = kb('MemFree:');
  final buffers = kb('Buffers:') ?? 0;
  final cached = kb('Cached:') ?? 0;
  if (total != null && total > 0 && free != null) {
    final approxAvail = free + buffers + cached;
    return ((total - approxAvail) / total).clamp(0.0, 1.0);
  }
  return null;
}

double? _parseVmstatIdle(String block) {
  if (block.isEmpty) return null;
  String? lastNumeric;
  for (final line in block.split('\n')) {
    final t = line.trimLeft();
    if (t.isEmpty) continue;
    if (RegExp(r'^\d').hasMatch(t)) lastNumeric = line;
  }
  if (lastNumeric == null) return null;
  final fields = lastNumeric.trim().split(RegExp(r'\s+'));
  if (fields.length < 15) return null;
  // 常见 Linux vmstat 数据行：… us sy id wa [st]，id 在 0-based 第 14 列
  final idle = double.tryParse(fields[14]);
  if (idle == null) return null;
  return ((100 - idle) / 100).clamp(0.0, 1.0);
}

double? _parseDfPercent(String line) {
  if (line.isEmpty) return null;
  for (final part in line.split(RegExp(r'\s+'))) {
    if (part.endsWith('%')) {
      final n = double.tryParse(part.replaceAll('%', ''));
      if (n != null) return (n / 100).clamp(0.0, 1.0);
    }
  }
  return null;
}

List<double>? _parseLoadavg(String block) {
  final line = block.split('\n').first.trim();
  if (line.isEmpty) return null;
  final parts = line.split(RegExp(r'\s+'));
  if (parts.length < 3) return null;
  final a = double.tryParse(parts[0]);
  final b = double.tryParse(parts[1]);
  final c = double.tryParse(parts[2]);
  if (a == null || b == null || c == null) return null;
  return [a, b, c];
}
