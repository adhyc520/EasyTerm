import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按 host 持久化远程桌面窗口布局（归一化坐标）。
class DesktopLayoutStore {
  DesktopLayoutStore();

  static const int schemaVersion = 1;

  static String _prefsKey(String hostKey) => 'desktop_layout_$hostKey';

  /// 读取布局；损坏 / 版本不匹配时返回 `null`。
  Future<DesktopLayoutData?> load(String hostKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey(hostKey));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return DesktopLayoutData.fromJson(
        Map<String, dynamic>.from(decoded),
        expectedHostKey: hostKey,
      );
    } catch (e, st) {
      debugPrint('DesktopLayoutStore.load: $e');
      assert(() {
        debugPrint('$st');
        return true;
      }());
      return null;
    }
  }

  Future<void> save(DesktopLayoutData data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey(data.hostKey), jsonEncode(data.toJson()));
    } catch (e, st) {
      debugPrint('DesktopLayoutStore.save: $e\n$st');
    }
  }

  Future<void> clear(String hostKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey(hostKey));
    } catch (e, st) {
      debugPrint('DesktopLayoutStore.clear: $e\n$st');
    }
  }
}

@immutable
class DesktopLayoutData {
  const DesktopLayoutData({
    required this.hostKey,
    required this.windows,
    this.version = DesktopLayoutStore.schemaVersion,
  });

  final int version;
  final String hostKey;
  final List<DesktopLayoutWindow> windows;

  Map<String, dynamic> toJson() => {
        'version': version,
        'hostKey': hostKey,
        'windows': windows.map((w) => w.toJson()).toList(),
      };

  static DesktopLayoutData? fromJson(
    Map<String, dynamic> json, {
    required String expectedHostKey,
  }) {
    final version = json['version'];
    if (version is! int || version != DesktopLayoutStore.schemaVersion) {
      return null;
    }
    final hostKey = json['hostKey'];
    if (hostKey is! String || hostKey.isEmpty) return null;
    // 允许存储的 hostKey 与请求键一致；不一致则丢弃。
    if (hostKey != expectedHostKey) return null;
    final list = json['windows'];
    if (list is! List) return null;
    final windows = <DesktopLayoutWindow>[];
    for (final item in list) {
      if (item is! Map) continue;
      final w = DesktopLayoutWindow.fromJson(Map<String, dynamic>.from(item));
      if (w != null) windows.add(w);
    }
    return DesktopLayoutData(hostKey: hostKey, windows: windows, version: version);
  }
}

@immutable
class DesktopLayoutWindow {
  const DesktopLayoutWindow({
    required this.type,
    required this.rect,
    required this.state,
    required this.z,
    this.args = const {},
  });

  /// `terminal` / `files` / `browser` / `monitor` / `editor`
  final String type;

  /// `[xFrac, yFrac, wFrac, hFrac]`，相对桌面尺寸 0..1。
  final List<double> rect;
  final String state;
  final double z;
  final Map<String, dynamic> args;

  Map<String, dynamic> toJson() => {
        'type': type,
        'args': args,
        'rect': rect,
        'state': state,
        'z': z,
      };

  static DesktopLayoutWindow? fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    if (type is! String || type.isEmpty) return null;
    final rectRaw = json['rect'];
    if (rectRaw is! List || rectRaw.length != 4) return null;
    final rect = <double>[];
    for (final v in rectRaw) {
      if (v is num) {
        rect.add(v.toDouble());
      } else {
        return null;
      }
    }
    final state = json['state'];
    if (state is! String) return null;
    final z = json['z'];
    if (z is! num) return null;
    final argsRaw = json['args'];
    final args = <String, dynamic>{};
    if (argsRaw is Map) {
      args.addAll(Map<String, dynamic>.from(argsRaw));
    }
    return DesktopLayoutWindow(
      type: type,
      rect: rect,
      state: state,
      z: z.toDouble(),
      args: args,
    );
  }
}
