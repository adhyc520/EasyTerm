import 'remote_process_list.dart';
import 'remote_exec_capable.dart';

/// 磁盘挂载点用量。
class RemoteDiskMount {
  const RemoteDiskMount({
    required this.filesystem,
    required this.mountPoint,
    required this.used01,
    this.sizeBytes,
    this.usedBytes,
    this.availBytes,
  });

  final String filesystem;
  final String mountPoint;
  final double used01;
  final int? sizeBytes;
  final int? usedBytes;
  final int? availBytes;
}

/// 远端主机一次采样的资源快照（Linux：/proc；Windows：CIM/WMI）。
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
    this.hostInfoLine,
    this.mounts = const [],
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
  final String? hostInfoLine;
  final List<RemoteDiskMount> mounts;

  /// Linux 多段标记输出。
  static RemoteHostSnapshot? parse(String raw) {
    if (raw.isEmpty) return null;
    const a = '__A__';
    const b = '__B__';
    const c = '__C__';
    const d = '__D__';
    const e = '__E__';
    const f = '__F__';
    const g = '__G__';
    const h = '__H__';
    const i = '__I__';
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
    // 兼容旧输出（无 __H__/__I__）：uptime 直至 __Z__
    final hasMounts = raw.contains(h);
    final uptimeBlock = hasMounts ? section(g, h) : section(g, z);
    final mountsBlock = hasMounts ? section(h, i) : '';
    final hostBlock = hasMounts
        ? (raw.contains(i) ? section(i, z) : '')
        : '';

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
    final mounts = parseDfMounts(mountsBlock);
    final hostInfo = hostBlock
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join(' · ');

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
      hostInfoLine: hostInfo.isEmpty ? null : hostInfo,
      mounts: mounts,
    );
  }

  /// Windows：`__WA__ mem __WB__ cpu __WC__ disk __WD__ mounts __WG__ uptime __WH__ host __WZ__`
  static RemoteHostSnapshot? parseWindows(String raw) {
    if (raw.isEmpty || !raw.contains('__WA__')) return null;

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

    double? ratio(String block) {
      final line = block.split(RegExp(r'[\r\n]+')).first.trim();
      if (line.isEmpty) return null;
      final v = double.tryParse(line);
      if (v == null) return null;
      return v.clamp(0.0, 1.0);
    }

    final mem = ratio(section('__WA__', '__WB__'));
    final cpu = ratio(section('__WB__', '__WC__'));
    final hasMounts = raw.contains('__WD__');
    final disk = ratio(
      hasMounts ? section('__WC__', '__WD__') : section('__WC__', '__WG__'),
    );
    final mounts = hasMounts
        ? parseWindowsMountLines(section('__WD__', '__WG__'))
        : const <RemoteDiskMount>[];
    final hasHost = raw.contains('__WH__');
    final uptime = section('__WG__', hasHost ? '__WH__' : '__WZ__')
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join(' ');
    final hostInfo = hasHost
        ? section('__WH__', '__WZ__')
            .split(RegExp(r'[\r\n]+'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .join(' · ')
        : '';

    if (mem == null &&
        cpu == null &&
        disk == null &&
        uptime.isEmpty &&
        mounts.isEmpty) {
      return null;
    }

    return RemoteHostSnapshot(
      memUsed01: mem,
      cpuUsed01: cpu,
      diskUsed01: disk,
      uptimeLine: uptime.isEmpty ? null : uptime,
      hostInfoLine: hostInfo.isEmpty ? null : hostInfo,
      mounts: mounts,
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
printf '__H__\n'
df -P 2>/dev/null | tail -n +2 | head -n 40
printf '__I__\n'
hostname 2>/dev/null; uname -srm 2>/dev/null
printf '__Z__\n'
''';

String get kRemoteStatusBundleOneLine =>
    kRemoteStatusBundle.replaceAll('\n', ';');

/// Windows：内存 / CPU / C: 磁盘 + 各盘符 + 运行时间 + 主机名。
const String kWindowsStatusBundle =
    r'''powershell -NoProfile -NonInteractive -Command "$os=Get-CimInstance Win32_OperatingSystem; $cpu=(Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average; $d=Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='C:'\"; $mem=1-($os.FreePhysicalMemory/[double]$os.TotalVisibleMemorySize); $disk=0; if($d -and $d.Size -gt 0){$disk=1-($d.FreeSpace/[double]$d.Size)}; $up=(Get-Date)-$os.LastBootUpTime; Write-Output '__WA__'; Write-Output ([math]::Round($mem,4)); Write-Output '__WB__'; Write-Output ([math]::Round(($cpu/100.0),4)); Write-Output '__WC__'; Write-Output ([math]::Round($disk,4)); Write-Output '__WD__'; Get-CimInstance Win32_LogicalDisk -Filter \"DriveType=3\" | ForEach-Object { if($_.Size -gt 0){ $u=1-($_.FreeSpace/[double]$_.Size); $_.DeviceID + '|' + [int64]$_.Size + '|' + [int64]($_.Size-$_.FreeSpace) + '|' + [int64]$_.FreeSpace + '|' + ([math]::Round($u,4)) } }; Write-Output '__WG__'; Write-Output ($up.Days.ToString()+'d '+$up.Hours.ToString()+'h '+$up.Minutes.ToString()+'m'); Write-Output '__WH__'; Write-Output ($env:COMPUTERNAME + ' · ' + $os.Caption + ' · ' + $os.Version); Write-Output '__WZ__'"''';

Future<RemoteHostSnapshot?> fetchRemoteHostSnapshot(
  RemoteExecCapable controller, {
  RemoteOsKind? osHint,
}) async {
  if (!controller.connected) return null;
  final os = osHint ?? await detectRemoteOs(controller);
  switch (os) {
    case RemoteOsKind.linux:
      final bundle =
          await controller.runRemoteForStatus(kRemoteStatusBundleOneLine);
      return RemoteHostSnapshot.parse(bundle ?? '');
    case RemoteOsKind.windows:
      final bundle =
          await controller.runRemoteForStatus(kWindowsStatusBundle);
      return RemoteHostSnapshot.parseWindows(bundle ?? '');
    case RemoteOsKind.unknown:
      final linux =
          await controller.runRemoteForStatus(kRemoteStatusBundleOneLine);
      final linuxSnap = RemoteHostSnapshot.parse(linux ?? '');
      if (linuxSnap != null) return linuxSnap;
      final win = await controller.runRemoteForStatus(kWindowsStatusBundle);
      return RemoteHostSnapshot.parseWindows(win ?? '');
  }
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

/// 解析 `df -P` 数据行（Filesystem 1024-blocks Used Available Capacity Mounted）。
List<RemoteDiskMount> parseDfMounts(String raw) {
  if (raw.isEmpty) return const [];
  final out = <RemoteDiskMount>[];
  final skip = RegExp(
    r'^/(dev|sys|proc|run)(/|$)',
    caseSensitive: false,
  );
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 6) continue;
    final fs = parts[0];
    final sizeKb = int.tryParse(parts[1]);
    final usedKb = int.tryParse(parts[2]);
    final availKb = int.tryParse(parts[3]);
    final pct = _parseDfPercent(parts[4].endsWith('%') ? parts[4] : '${parts[4]}%') ??
        _parseDfPercent(parts[4]);
    final mount = parts.sublist(5).join(' ');
    if (mount.isEmpty || skip.hasMatch(mount)) continue;
    // 跳过 tmpfs/devtmpfs 等虚拟盘（除非挂在 /）
    final fsLower = fs.toLowerCase();
    if ((fsLower.contains('tmpfs') || fsLower.contains('devtmpfs')) &&
        mount != '/') {
      continue;
    }
    final used01 = pct ??
        (sizeKb != null && sizeKb > 0 && usedKb != null
            ? (usedKb / sizeKb).clamp(0.0, 1.0)
            : null);
    if (used01 == null) continue;
    out.add(
      RemoteDiskMount(
        filesystem: fs,
        mountPoint: mount,
        used01: used01,
        sizeBytes: sizeKb == null ? null : sizeKb * 1024,
        usedBytes: usedKb == null ? null : usedKb * 1024,
        availBytes: availKb == null ? null : availKb * 1024,
      ),
    );
  }
  out.sort((a, b) => b.used01.compareTo(a.used01));
  return out;
}

/// `DeviceID|Size|Used|Free|used01`
List<RemoteDiskMount> parseWindowsMountLines(String raw) {
  if (raw.isEmpty) return const [];
  final out = <RemoteDiskMount>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('__')) continue;
    final parts = t.split('|');
    if (parts.length < 5) continue;
    final id = parts[0].trim();
    final size = int.tryParse(parts[1].trim());
    final used = int.tryParse(parts[2].trim());
    final free = int.tryParse(parts[3].trim());
    final ratio = double.tryParse(parts[4].trim());
    if (id.isEmpty || ratio == null) continue;
    out.add(
      RemoteDiskMount(
        filesystem: id,
        mountPoint: id,
        used01: ratio.clamp(0.0, 1.0),
        sizeBytes: size,
        usedBytes: used,
        availBytes: free,
      ),
    );
  }
  out.sort((a, b) => b.used01.compareTo(a.used01));
  return out;
}

String formatDiskBytes(int? bytes) {
  if (bytes == null || bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / 1024;
  if (gb < 1024) return '${gb.toStringAsFixed(1)} GB';
  return '${(gb / 1024).toStringAsFixed(2)} TB';
}
