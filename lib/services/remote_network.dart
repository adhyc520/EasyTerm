import 'remote_process_list.dart';
import 'remote_exec_capable.dart';

/// 网卡累计收发字节（Linux `/proc/net/dev`；Windows 适配器统计）。
class RemoteNetIface {
  const RemoteNetIface({
    required this.name,
    required this.rxBytes,
    required this.txBytes,
    this.rxPackets,
    this.txPackets,
  });

  final String name;
  final int rxBytes;
  final int txBytes;
  final int? rxPackets;
  final int? txPackets;

  bool get isLoopback {
    final n = name.toLowerCase();
    return n == 'lo' || n.startsWith('loopback') || n == 'lo0';
  }
}

/// 监听中的端口（TCP/UDP）。
class RemoteListenSocket {
  const RemoteListenSocket({
    required this.protocol,
    required this.address,
    required this.port,
    this.process,
    this.pid,
  });

  final String protocol; // tcp / tcp6 / udp / udp6
  final String address;
  final int port;
  final String? process;
  final int? pid;

  String get endpoint {
    final a = address;
    if (a.contains(':') && !a.startsWith('[')) {
      return '[$a]:$port';
    }
    return '$a:$port';
  }

  /// 供桌面浏览器打开的目标（仅 TCP）；通配地址映射为 `localhost`。
  ///
  /// IPv6 必须带方括号（如 `[2001:db8::1]:8080`），否则 [Uri.parse] 会把端口拆错。
  String? get browserTarget {
    final p = protocol.toLowerCase();
    if (!p.startsWith('tcp')) return null;
    if (port <= 0 || port > 65535) return null;
    var host = address.trim();
    if (host.isEmpty ||
        host == '*' ||
        host == '0.0.0.0' ||
        host == '::' ||
        host == '[::]' ||
        host.toLowerCase() == '::0') {
      host = 'localhost';
    } else if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (host.contains(':')) {
      return '[$host]:$port';
    }
    return '$host:$port';
  }
}

/// 一次网络采样。
class RemoteNetworkSnapshot {
  const RemoteNetworkSnapshot({
    required this.os,
    required this.interfaces,
    required this.listeners,
    required this.sampledAt,
    this.tcpEstablished,
    this.tcpListen,
    this.tcpTimeWait,
    this.summaryLine,
  });

  final RemoteOsKind os;
  final List<RemoteNetIface> interfaces;
  final List<RemoteListenSocket> listeners;
  final DateTime sampledAt;
  final int? tcpEstablished;
  final int? tcpListen;
  final int? tcpTimeWait;
  final String? summaryLine;

  /// 相对 [previous] 计算各网卡收发速率（B/s）；无前次或时间过短则返回 null 速率。
  List<RemoteNetIfaceRate> ratesAgainst(RemoteNetworkSnapshot? previous) {
    if (previous == null ||
        sampledAt.difference(previous.sampledAt).inMilliseconds < 400) {
      return [
        for (final i in interfaces)
          RemoteNetIfaceRate(iface: i, rxBytesPerSec: null, txBytesPerSec: null),
      ];
    }
    final dt =
        sampledAt.difference(previous.sampledAt).inMilliseconds / 1000.0;
    final prevMap = {for (final p in previous.interfaces) p.name: p};
    final out = <RemoteNetIfaceRate>[];
    for (final i in interfaces) {
      final p = prevMap[i.name];
      if (p == null) {
        out.add(
          RemoteNetIfaceRate(
            iface: i,
            rxBytesPerSec: null,
            txBytesPerSec: null,
          ),
        );
        continue;
      }
      final drx = i.rxBytes - p.rxBytes;
      final dtx = i.txBytes - p.txBytes;
      out.add(
        RemoteNetIfaceRate(
          iface: i,
          rxBytesPerSec: drx < 0 ? null : drx / dt,
          txBytesPerSec: dtx < 0 ? null : dtx / dt,
        ),
      );
    }
    return out;
  }
}

class RemoteNetIfaceRate {
  const RemoteNetIfaceRate({
    required this.iface,
    required this.rxBytesPerSec,
    required this.txBytesPerSec,
  });

  final RemoteNetIface iface;
  final double? rxBytesPerSec;
  final double? txBytesPerSec;
}

/// Linux：网卡 + 监听端口 + `ss -s` 摘要。
const String kLinuxNetworkBundle = r'''
printf '__IF__\n'
cat /proc/net/dev 2>/dev/null
printf '__LISTEN__\n'
ss -lntuH 2>/dev/null || ss -lntu 2>/dev/null || netstat -lntu 2>/dev/null
printf '__SUM__\n'
ss -s 2>/dev/null | head -n 24
printf '__Z__\n'
''';

String get kLinuxNetworkBundleOneLine =>
    kLinuxNetworkBundle.replaceAll('\n', ';');

/// Windows：适配器累计字节 + TCP Listen + 状态计数。
const String kWindowsNetworkBundle =
    r'''powershell -NoProfile -NonInteractive -Command "Write-Output '__IF__'; Get-NetAdapterStatistics -ErrorAction SilentlyContinue | ForEach-Object { ($_.Name -replace '[|\r\n]',' ') + '|' + [int64]$_.ReceivedBytes + '|' + [int64]$_.SentBytes }; if(-not $?){ Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue | ForEach-Object { ($_.Name -replace '[|\r\n]',' ') + '|' + [int64]$_.BytesReceived + '|' + [int64]$_.BytesSent } }; Write-Output '__LISTEN__'; Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object -First 250 | ForEach-Object { 'tcp|' + $_.LocalAddress + '|' + $_.LocalPort + '|' + $_.OwningProcess }; Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Select-Object -First 120 | ForEach-Object { 'udp|' + $_.LocalAddress + '|' + $_.LocalPort + '|' + $_.OwningProcess }; Write-Output '__SUM__'; $g=Get-NetTCPConnection -ErrorAction SilentlyContinue | Group-Object State; if($g){ ($g | ForEach-Object { $_.Name + '=' + $_.Count }) -join ' ' }; Write-Output '__Z__'"''';

Future<RemoteNetworkSnapshot?> fetchRemoteNetworkSnapshot(
  RemoteExecCapable controller, {
  RemoteOsKind? osHint,
}) async {
  if (!controller.connected) return null;
  final os = osHint ?? await detectRemoteOs(controller);
  final now = DateTime.now();
  switch (os) {
    case RemoteOsKind.linux:
      final raw =
          await controller.runRemoteForStatus(kLinuxNetworkBundleOneLine);
      return parseLinuxNetworkBundle(raw ?? '', sampledAt: now);
    case RemoteOsKind.windows:
      final raw =
          await controller.runRemoteForStatus(kWindowsNetworkBundle);
      return parseWindowsNetworkBundle(raw ?? '', sampledAt: now);
    case RemoteOsKind.unknown:
      final linux =
          await controller.runRemoteForStatus(kLinuxNetworkBundleOneLine);
      final l = parseLinuxNetworkBundle(linux ?? '', sampledAt: now);
      if (l != null &&
          (l.interfaces.isNotEmpty || l.listeners.isNotEmpty)) {
        return l;
      }
      final win = await controller.runRemoteForStatus(kWindowsNetworkBundle);
      return parseWindowsNetworkBundle(win ?? '', sampledAt: now);
  }
}

RemoteNetworkSnapshot? parseLinuxNetworkBundle(
  String raw, {
  DateTime? sampledAt,
}) {
  if (raw.isEmpty || !raw.contains('__IF__')) return null;
  final ifaces = parseProcNetDev(_section(raw, '__IF__', '__LISTEN__'));
  final listeners =
      parseLinuxListenSockets(_section(raw, '__LISTEN__', '__SUM__'));
  final sum = _section(raw, '__SUM__', '__Z__');
  final counts = _parseSsSummary(sum);
  return RemoteNetworkSnapshot(
    os: RemoteOsKind.linux,
    interfaces: ifaces,
    listeners: listeners,
    sampledAt: sampledAt ?? DateTime.now(),
    tcpEstablished: counts.$1,
    tcpListen: counts.$2,
    tcpTimeWait: counts.$3,
    summaryLine: sum.isEmpty
        ? null
        : sum
            .split(RegExp(r'[\r\n]+'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .take(3)
            .join(' · '),
  );
}

RemoteNetworkSnapshot? parseWindowsNetworkBundle(
  String raw, {
  DateTime? sampledAt,
}) {
  if (raw.isEmpty || !raw.contains('__IF__')) return null;
  final ifaces =
      parseWindowsIfaceLines(_section(raw, '__IF__', '__LISTEN__'));
  final listeners =
      parseWindowsListenLines(_section(raw, '__LISTEN__', '__SUM__'));
  final sum = _section(raw, '__SUM__', '__Z__').trim();
  final counts = _parseWindowsTcpGroup(sum);
  return RemoteNetworkSnapshot(
    os: RemoteOsKind.windows,
    interfaces: ifaces,
    listeners: listeners,
    sampledAt: sampledAt ?? DateTime.now(),
    tcpEstablished: counts.$1,
    tcpListen: counts.$2,
    tcpTimeWait: counts.$3,
    summaryLine: sum.isEmpty ? null : sum,
  );
}

/// 解析 `/proc/net/dev` 正文。
List<RemoteNetIface> parseProcNetDev(String raw) {
  if (raw.isEmpty) return const [];
  final out = <RemoteNetIface>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty || !t.contains(':')) continue;
    if (t.toLowerCase().startsWith('inter-') ||
        t.toLowerCase().startsWith('face')) {
      continue;
    }
    final colon = t.indexOf(':');
    final name = t.substring(0, colon).trim();
    if (name.isEmpty) continue;
    final fields = t.substring(colon + 1).trim().split(RegExp(r'\s+'));
    if (fields.length < 9) continue;
    final rx = int.tryParse(fields[0]);
    final rxPkt = int.tryParse(fields[1]);
    final tx = int.tryParse(fields[8]);
    final txPkt = fields.length > 9 ? int.tryParse(fields[9]) : null;
    if (rx == null || tx == null) continue;
    out.add(
      RemoteNetIface(
        name: name,
        rxBytes: rx,
        txBytes: tx,
        rxPackets: rxPkt,
        txPackets: txPkt,
      ),
    );
  }
  out.sort((a, b) {
    if (a.isLoopback != b.isLoopback) return a.isLoopback ? 1 : -1;
    return (b.rxBytes + b.txBytes).compareTo(a.rxBytes + a.txBytes);
  });
  return out;
}

/// `name|rx|tx`
List<RemoteNetIface> parseWindowsIfaceLines(String raw) {
  if (raw.isEmpty) return const [];
  final out = <RemoteNetIface>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('__')) continue;
    final parts = t.split('|');
    if (parts.length < 3) continue;
    final name = parts[0].trim();
    final rx = int.tryParse(parts[1].trim());
    final tx = int.tryParse(parts[2].trim());
    if (name.isEmpty || rx == null || tx == null) continue;
    out.add(RemoteNetIface(name: name, rxBytes: rx, txBytes: tx));
  }
  out.sort((a, b) {
    if (a.isLoopback != b.isLoopback) return a.isLoopback ? 1 : -1;
    return (b.rxBytes + b.txBytes).compareTo(a.rxBytes + a.txBytes);
  });
  return out;
}

/// `ss -lntu` / `netstat -lntu` 行。
List<RemoteListenSocket> parseLinuxListenSockets(String raw) {
  if (raw.isEmpty) return const [];
  final out = <RemoteListenSocket>[];
  final seen = <String>{};
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final lower = t.toLowerCase();
    if (lower.startsWith('netid') ||
        lower.startsWith('state') ||
        lower.startsWith('proto') ||
        lower.startsWith('active')) {
      continue;
    }
    final sock = _parseSsListenLine(t) ?? _parseNetstatListenLine(t);
    if (sock == null) continue;
    final key = '${sock.protocol}|${sock.address}|${sock.port}';
    if (!seen.add(key)) continue;
    out.add(sock);
  }
  out.sort((a, b) {
    final p = a.port.compareTo(b.port);
    if (p != 0) return p;
    return a.protocol.compareTo(b.protocol);
  });
  return out;
}

/// `proto|addr|port|pid`
List<RemoteListenSocket> parseWindowsListenLines(String raw) {
  if (raw.isEmpty) return const [];
  final out = <RemoteListenSocket>[];
  final seen = <String>{};
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('__')) continue;
    final parts = t.split('|');
    if (parts.length < 3) continue;
    final proto = parts[0].trim().toLowerCase();
    final addr = parts[1].trim();
    final port = int.tryParse(parts[2].trim());
    if (port == null || port <= 0 || port > 65535) continue;
    final pid = parts.length > 3 ? int.tryParse(parts[3].trim()) : null;
    final key = '$proto|$addr|$port';
    if (!seen.add(key)) continue;
    out.add(
      RemoteListenSocket(
        protocol: proto.isEmpty ? 'tcp' : proto,
        address: addr.isEmpty ? '0.0.0.0' : addr,
        port: port,
        pid: (pid != null && pid > 0) ? pid : null,
      ),
    );
  }
  out.sort((a, b) => a.port.compareTo(b.port));
  return out;
}

String formatNetBytes(int bytes) {
  if (bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / 1024;
  if (gb < 1024) return '${gb.toStringAsFixed(2)} GB';
  return '${(gb / 1024).toStringAsFixed(2)} TB';
}

String formatNetRate(double? bytesPerSec) {
  if (bytesPerSec == null) return '—';
  if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
  final kb = bytesPerSec / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB/s';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(2)} MB/s';
  return '${(mb / 1024).toStringAsFixed(2)} GB/s';
}

String _section(String raw, String start, String end) {
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

RemoteListenSocket? _parseSsListenLine(String line) {
  // ss: LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
  //     UNCONN 0 0 127.0.0.1:323 0.0.0.0:*
  final parts = line.split(RegExp(r'\s+'));
  if (parts.length < 5) return null;
  final state = parts[0].toUpperCase();
  final String protoBase;
  if (state == 'LISTEN') {
    protoBase = 'tcp';
  } else if (state == 'UNCONN') {
    protoBase = 'udp';
  } else if (state == 'TCP' || state == 'TCP6' || state == 'UDP' || state == 'UDP6') {
    // some ss versions: Netid State Recv-Q Send-Q Local Address:Port Peer...
    return _parseSsNetidLine(parts);
  } else {
    return null;
  }
  final local = parts[3];
  final ep = _splitHostPort(local);
  if (ep == null) return null;
  final v6 = ep.$1.contains(':');
  return RemoteListenSocket(
    protocol: v6 ? '${protoBase}6' : protoBase,
    address: ep.$1,
    port: ep.$2,
  );
}

RemoteListenSocket? _parseSsNetidLine(List<String> parts) {
  // netid state recv-q send-q local peer
  if (parts.length < 6) return null;
  final netid = parts[0].toLowerCase();
  final state = parts[1].toUpperCase();
  if (netid.startsWith('tcp') && state != 'LISTEN') return null;
  if (netid.startsWith('udp') && state != 'UNCONN' && state != 'ESTAB') {
    // still show unbound udp
  }
  final local = parts[4];
  final ep = _splitHostPort(local);
  if (ep == null) return null;
  return RemoteListenSocket(
    protocol: netid,
    address: ep.$1,
    port: ep.$2,
  );
}

RemoteListenSocket? _parseNetstatListenLine(String line) {
  // tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN
  final parts = line.split(RegExp(r'\s+'));
  if (parts.length < 4) return null;
  final proto = parts[0].toLowerCase();
  if (!proto.startsWith('tcp') && !proto.startsWith('udp')) return null;
  final isTcp = proto.startsWith('tcp');
  String? local;
  if (isTcp) {
    if (!line.toUpperCase().contains('LISTEN')) return null;
    local = parts.length >= 4 ? parts[3] : null;
  } else {
    local = parts.length >= 4 ? parts[3] : null;
  }
  if (local == null) return null;
  final ep = _splitHostPort(local);
  if (ep == null) return null;
  return RemoteListenSocket(
    protocol: proto,
    address: ep.$1,
    port: ep.$2,
  );
}

(String, int)? _splitHostPort(String local) {
  final t = local.trim();
  if (t.isEmpty) return null;
  // [ffff:...]:80
  if (t.startsWith('[')) {
    final close = t.indexOf(']');
    if (close < 0) return null;
    final host = t.substring(1, close);
    final rest = t.substring(close + 1);
    if (!rest.startsWith(':')) return null;
    final port = int.tryParse(rest.substring(1));
    if (port == null || port <= 0 || port > 65535) return null;
    return (host, port);
  }
  final colon = t.lastIndexOf(':');
  if (colon <= 0) return null;
  final host = t.substring(0, colon);
  final port = int.tryParse(t.substring(colon + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  return (host.isEmpty ? '*' : host, port);
}

/// Returns (estab, listen, timewait).
(int?, int?, int?) _parseSsSummary(String raw) {
  if (raw.isEmpty) return (null, null, null);
  int? estab;
  int? listen;
  int? tw;
  // TCP:   12 (estab 3, closed 4, orphaned 0, synrecv 0, timewait 2/0), ports 0
  final m = RegExp(
    r'TCP:\s*\d+\s*\(([^)]+)\)',
    caseSensitive: false,
  ).firstMatch(raw);
  if (m != null) {
    final inner = m.group(1)!;
    estab = _kvInt(inner, 'estab');
    tw = _kvInt(inner, 'timewait');
  }
  // Listen       8      20
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.toLowerCase().startsWith('listen')) {
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length >= 2) listen = int.tryParse(parts[1]);
    }
  }
  return (estab, listen, tw);
}

int? _kvInt(String inner, String key) {
  final m = RegExp(
    '$key\\s+(\\d+)',
    caseSensitive: false,
  ).firstMatch(inner);
  return m == null ? null : int.tryParse(m.group(1)!);
}

(int?, int?, int?) _parseWindowsTcpGroup(String raw) {
  if (raw.isEmpty) return (null, null, null);
  int? pick(String name) {
    final m = RegExp(
      '$name\\s*=\\s*(\\d+)',
      caseSensitive: false,
    ).firstMatch(raw);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  return (pick('Established'), pick('Listen'), pick('TimeWait'));
}
