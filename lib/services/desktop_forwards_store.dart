import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 按 host 持久化的本地端口转发偏好（重连后可重建）。
class DesktopForwardsStore {
  DesktopForwardsStore(this.hostKey);

  final String hostKey;

  String get _key => 'desktop_forwards_$hostKey';

  Future<List<DesktopForwardSpec>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in list)
          if (e is Map)
            DesktopForwardSpec(
              remoteHost: '${e['host'] ?? '127.0.0.1'}',
              remotePort: (e['port'] as num?)?.toInt() ?? 0,
              localPort: (e['local'] as num?)?.toInt(),
            ),
      ].where((e) => e.remotePort > 0 && e.remotePort < 65536).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<DesktopForwardSpec> items) async {
    final p = await SharedPreferences.getInstance();
    final encoded = jsonEncode([
      for (final e in items)
        {
          'host': e.remoteHost,
          'port': e.remotePort,
          if (e.localPort != null) 'local': e.localPort,
        },
    ]);
    await p.setString(_key, encoded);
  }
}

class DesktopForwardSpec {
  const DesktopForwardSpec({
    required this.remoteHost,
    required this.remotePort,
    this.localPort,
  });

  final String remoteHost;
  final int remotePort;
  final int? localPort;
}
