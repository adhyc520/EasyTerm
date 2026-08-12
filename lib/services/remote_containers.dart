import 'remote_process_list.dart';
import 'remote_sudo.dart';
import 'remote_exec_capable.dart';

enum RemoteContainerAction { start, stop, restart, remove }

/// 单个容器（Docker）。
class RemoteContainer {
  const RemoteContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.status,
    this.state,
    this.ports,
    this.cpuPercent,
    this.memPercent,
    this.memUsage,
    this.netIo,
  });

  final String id;
  final String name;
  final String image;
  final String status;
  final String? state;
  final String? ports;
  final double? cpuPercent;
  final double? memPercent;
  final String? memUsage;
  final String? netIo;

  bool get isRunning {
    final s = (state ?? status).toLowerCase();
    return s == 'running' || s.startsWith('up ');
  }

  String get shortId =>
      id.length > 12 ? id.substring(0, 12) : id;
}

class RemoteContainerSnapshot {
  const RemoteContainerSnapshot({
    required this.os,
    required this.containers,
    this.available = true,
    this.error,
  });

  final RemoteOsKind os;
  final List<RemoteContainer> containers;
  final bool available;
  final String? error;
}

bool isSafeContainerRef(String ref) {
  if (ref.isEmpty || ref.length > 128) return false;
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.\-]*$').hasMatch(ref);
}

/// `ID|Names|Image|Status|State|Ports`
const String kLinuxDockerPs =
    r'''docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.State}}|{{.Ports}}' 2>/dev/null | head -n 400''';

/// `ID|CPUPerc|MemPerc|MemUsage|NetIO`
const String kLinuxDockerStats =
    r'''docker stats --no-stream --format '{{.ID}}|{{.CPUPerc}}|{{.MemPerc}}|{{.MemUsage}}|{{.NetIO}}' 2>/dev/null | head -n 400''';

const String kWindowsDockerPs =
    r'''docker.exe ps -a --format "{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.State}}|{{.Ports}}" 2>nul || docker ps -a --format "{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.State}}|{{.Ports}}"''';

const String kWindowsDockerStats =
    r'''docker.exe stats --no-stream --format "{{.ID}}|{{.CPUPerc}}|{{.MemPerc}}|{{.MemUsage}}|{{.NetIO}}" 2>nul || docker stats --no-stream --format "{{.ID}}|{{.CPUPerc}}|{{.MemPerc}}|{{.MemUsage}}|{{.NetIO}}"''';

Future<bool> detectDockerAvailable(
  RemoteExecCapable controller, {
  RemoteOsKind? osHint,
}) async {
  if (!controller.connected) return false;
  final os = osHint ?? await detectRemoteOs(controller);
  final cmd = os == RemoteOsKind.windows
      ? 'docker.exe version --format "{{.Server.Version}}" 2>nul || docker version --format "{{.Server.Version}}"'
      : 'docker version --format "{{.Server.Version}}" 2>/dev/null';
  final raw = await controller.runRemoteForStatus(cmd);
  final t = (raw ?? '').trim();
  return t.isNotEmpty && !t.toLowerCase().contains('error');
}

Future<RemoteContainerSnapshot?> fetchRemoteContainers(
  RemoteExecCapable controller, {
  RemoteOsKind? osHint,
}) async {
  if (!controller.connected) return null;
  final os = osHint ?? await detectRemoteOs(controller);
  switch (os) {
    case RemoteOsKind.linux:
      return _fetch(controller, os: RemoteOsKind.linux);
    case RemoteOsKind.windows:
      return _fetch(controller, os: RemoteOsKind.windows);
    case RemoteOsKind.unknown:
      final linux = await _fetch(controller, os: RemoteOsKind.linux);
      // null = 命令超时/队列失败，勿当成「无 Docker」再去试 Windows。
      if (linux == null) return null;
      if (linux.available || linux.containers.isNotEmpty) return linux;
      return _fetch(controller, os: RemoteOsKind.windows);
  }
}

/// 拉取容器列表。
///
/// 返回 `null` 表示命令失败（超时、掉线、队列拥塞等），调用方应保留上一帧数据，
/// **不要**据此判定「未安装 Docker」。
Future<RemoteContainerSnapshot?> _fetch(
  RemoteExecCapable controller, {
  required RemoteOsKind os,
}) async {
  final psCmd =
      os == RemoteOsKind.windows ? kWindowsDockerPs : kLinuxDockerPs;
  final statsCmd =
      os == RemoteOsKind.windows ? kWindowsDockerStats : kLinuxDockerStats;

  // 与「空输出 / 无 docker」区分：null 只表示 exec 失败。
  final psRaw = await controller.runQueued(
    psCmd,
    timeout: const Duration(seconds: 20),
  );
  if (psRaw == null) return null;

  if (psRaw.trim().isEmpty) {
    // 成功但无输出：可能是零容器，也可能是未安装（stderr 被丢弃）。
    final available = await _probeDockerCli(controller, os: os);
    if (available == null) return null; // probe 也失败 → 瞬时错误
    return RemoteContainerSnapshot(
      os: os,
      containers: const [],
      available: available,
      error: available ? null : '未检测到 Docker（需安装且当前用户可访问）',
    );
  }

  var list = parseDockerPs(psRaw, os: os);
  // Telnet/Serial 仿真 exec：跳过 stats，减少主终端刷屏与超时。
  if (list.isNotEmpty && !controller.lightweightRemoteExec) {
    final statsRaw = await controller.runQueued(
      statsCmd,
      timeout: const Duration(seconds: 20),
    );
    if (statsRaw != null && statsRaw.trim().isNotEmpty) {
      list = mergeDockerStats(list, parseDockerStats(statsRaw));
    }
  }
  list.sort((a, b) {
    final ar = a.isRunning ? 0 : 1;
    final br = b.isRunning ? 0 : 1;
    if (ar != br) return ar - br;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return RemoteContainerSnapshot(
    os: os,
    containers: list,
    available: true,
  );
}

/// 探测 Docker CLI 是否存在。
///
/// - `true` / `false`：明确结论
/// - `null`：命令失败，无法判定
Future<bool?> _probeDockerCli(
  RemoteExecCapable controller, {
  required RemoteOsKind os,
}) async {
  final probe = os == RemoteOsKind.windows
      ? r'(where docker.exe >nul 2>nul || where docker >nul 2>nul) && echo __DOCKER_OK__ || echo __DOCKER_MISSING__'
      : r'command -v docker >/dev/null 2>&1 && echo __DOCKER_OK__ || echo __DOCKER_MISSING__';
  final p = await controller.runQueued(
    probe,
    timeout: const Duration(seconds: 10),
  );
  if (p == null) return null;
  final t = p.trim();
  if (t.contains('__DOCKER_OK__')) return true;
  if (t.contains('__DOCKER_MISSING__')) return false;
  // 输出被 MOTD/噪声污染且无标记 → 当作瞬时失败，避免误报「无 Docker」。
  return null;
}

Future<String?> controlRemoteContainer(
  RemoteExecCapable controller, {
  required RemoteOsKind os,
  required String ref,
  required RemoteContainerAction action,
}) async {
  if (!controller.connected) return '未连接';
  if (!isSafeContainerRef(ref)) return '非法容器引用';
  final verb = switch (action) {
    RemoteContainerAction.start => 'start',
    RemoteContainerAction.stop => 'stop',
    RemoteContainerAction.restart => 'restart',
    RemoteContainerAction.remove => 'rm -f',
  };
  if (os == RemoteOsKind.windows) {
    final cmd = 'docker.exe $verb $ref 2>nul || docker $verb $ref';
    final raw = await controller.runRemoteForStatus(cmd);
    if (raw == null) return '命令失败或已断开';
    final lower = raw.toLowerCase();
    if (lower.contains('error') ||
        lower.contains('no such') ||
        lower.contains('cannot')) {
      final msg = raw.trim();
      return msg.isEmpty ? '操作失败' : msg;
    }
    return null;
  }
  final cmd = 'docker $verb $ref 2>&1; echo __EC:\$?';
  final raw = await controller.runRemoteForStatus(cmd);
  return RemoteSudo.interpretExit(raw, usedPassword: false);
}

Future<String?> inspectRemoteContainer(
  RemoteExecCapable controller, {
  required RemoteOsKind os,
  required String ref,
}) async {
  if (!controller.connected) return null;
  if (!isSafeContainerRef(ref)) return null;
  final cmd = os == RemoteOsKind.windows
      ? 'docker.exe inspect $ref 2>nul || docker inspect $ref'
      : "docker inspect --format '{{.Name}}|{{.State.Status}}|{{.Config.Image}}|{{.Created}}|{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' $ref 2>/dev/null || docker inspect $ref 2>/dev/null | head -n 80";
  return controller.runQueued(cmd);
}

List<RemoteContainer> parseDockerPs(String raw, {RemoteOsKind? os}) {
  if (raw.isEmpty) return const [];
  final out = <RemoteContainer>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('CONTAINER')) continue;
    final parts = t.split('|');
    if (parts.length < 4) continue;
    final id = parts[0].trim();
    final name = parts[1].trim();
    final image = parts[2].trim();
    final status = parts[3].trim();
    final state = parts.length > 4 ? parts[4].trim() : null;
    final ports = parts.length > 5 ? parts.sublist(5).join('|').trim() : null;
    if (id.isEmpty) continue;
    out.add(
      RemoteContainer(
        id: id,
        name: name.isEmpty ? id : name,
        image: image,
        status: status,
        state: (state == null || state.isEmpty) ? null : state,
        ports: (ports == null || ports.isEmpty) ? null : ports,
      ),
    );
  }
  return out;
}

Map<String, ({double? cpu, double? mem, String? memUsage, String? netIo})>
    parseDockerStats(String raw) {
  final map = <String,
      ({double? cpu, double? mem, String? memUsage, String? netIo})>{};
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty || t.toUpperCase().startsWith('CONTAINER')) continue;
    final parts = t.split('|');
    if (parts.length < 3) continue;
    final id = parts[0].trim();
    if (id.isEmpty) continue;
    final cpu = _parsePercent(parts[1]);
    final mem = _parsePercent(parts[2]);
    final memUsage = parts.length > 3 ? parts[3].trim() : null;
    final netIo = parts.length > 4 ? parts[4].trim() : null;
    map[id] = (
      cpu: cpu,
      mem: mem,
      memUsage: (memUsage == null || memUsage.isEmpty) ? null : memUsage,
      netIo: (netIo == null || netIo.isEmpty) ? null : netIo,
    );
  }
  return map;
}

List<RemoteContainer> mergeDockerStats(
  List<RemoteContainer> list,
  Map<String, ({double? cpu, double? mem, String? memUsage, String? netIo})>
      stats,
) {
  if (stats.isEmpty) return list;
  ({double? cpu, double? mem, String? memUsage, String? netIo})? match(
    String id,
  ) {
    final direct = stats[id];
    if (direct != null) return direct;
    for (final e in stats.entries) {
      if (id.startsWith(e.key) || e.key.startsWith(id)) return e.value;
    }
    return null;
  }

  return [
    for (final c in list)
      if (match(c.id) case final s?)
        RemoteContainer(
          id: c.id,
          name: c.name,
          image: c.image,
          status: c.status,
          state: c.state,
          ports: c.ports,
          cpuPercent: s.cpu,
          memPercent: s.mem,
          memUsage: s.memUsage,
          netIo: s.netIo,
        )
      else
        c,
  ];
}

double? _parsePercent(String raw) {
  final t = raw.trim().replaceAll('%', '');
  if (t.isEmpty) return null;
  return double.tryParse(t);
}
