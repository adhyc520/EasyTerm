import 'remote_process_list.dart';
import 'ssh_workspace_controller.dart';

/// 单块 GPU 采样（nvidia-smi）。
class RemoteGpuInfo {
  const RemoteGpuInfo({
    required this.index,
    required this.name,
    this.util01,
    this.memUsed01,
    this.memUsedMiB,
    this.memTotalMiB,
    this.tempC,
  });

  final int index;
  final String name;
  final double? util01;
  final double? memUsed01;
  final double? memUsedMiB;
  final double? memTotalMiB;
  final double? tempC;
}

class RemoteGpuSnapshot {
  const RemoteGpuSnapshot({
    required this.os,
    required this.gpus,
    this.available = true,
    this.error,
  });

  final RemoteOsKind os;
  final List<RemoteGpuInfo> gpus;
  final bool available;
  final String? error;
}

const String kNvidiaSmiQuery =
    r'''nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null''';

const String kWindowsNvidiaSmiQuery =
    r'''nvidia-smi.exe --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>nul || nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits''';

Future<RemoteGpuSnapshot?> fetchRemoteGpuSnapshot(
  SshWorkspaceController controller, {
  RemoteOsKind? osHint,
}) async {
  if (!controller.connected) return null;
  final os = osHint ?? await detectRemoteOs(controller);
  final cmd =
      os == RemoteOsKind.windows ? kWindowsNvidiaSmiQuery : kNvidiaSmiQuery;
  final raw = await controller.runRemoteForStatus(cmd);
  if (raw == null || raw.trim().isEmpty) {
    return RemoteGpuSnapshot(
      os: os,
      gpus: const [],
      available: false,
      error: null,
    );
  }
  final lower = raw.toLowerCase();
  if (lower.contains('not found') ||
      lower.contains('not recognized') ||
      lower.contains('no devices') ||
      lower.contains('failed')) {
    return RemoteGpuSnapshot(
      os: os,
      gpus: const [],
      available: false,
      error: raw.trim().split(RegExp(r'[\r\n]+')).first,
    );
  }
  final gpus = parseNvidiaSmiCsv(raw);
  return RemoteGpuSnapshot(
    os: os,
    gpus: gpus,
    available: gpus.isNotEmpty,
  );
}

/// `index, name, util, memUsed, memTotal, temp`
List<RemoteGpuInfo> parseNvidiaSmiCsv(String raw) {
  final out = <RemoteGpuInfo>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final cols = t.split(',').map((e) => e.trim()).toList();
    if (cols.length < 5) continue;
    final index = int.tryParse(cols[0]);
    if (index == null) continue;
    final name = cols[1];
    if (name.isEmpty) continue;
    final util = double.tryParse(cols[2].replaceAll('%', ''));
    final memUsed = double.tryParse(cols[3]);
    final memTotal = double.tryParse(cols[4]);
    final temp = cols.length > 5 ? double.tryParse(cols[5]) : null;
    double? mem01;
    if (memUsed != null && memTotal != null && memTotal > 0) {
      mem01 = (memUsed / memTotal).clamp(0.0, 1.0);
    }
    out.add(
      RemoteGpuInfo(
        index: index,
        name: name,
        util01: util == null ? null : (util / 100).clamp(0.0, 1.0),
        memUsed01: mem01,
        memUsedMiB: memUsed,
        memTotalMiB: memTotal,
        tempC: temp,
      ),
    );
  }
  return out;
}
