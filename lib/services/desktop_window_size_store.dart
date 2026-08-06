import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 按 host + 应用类型记住窗口宽高（相对工作区 0..1），不记位置与窗口清单。
class DesktopWindowSizeStore {
  DesktopWindowSizeStore(this.hostKey);

  final String hostKey;

  String get _prefsKey => 'desktop_window_sizes_$hostKey';

  /// typeName → (wFrac, hFrac)
  Future<Map<String, ({double w, double h})>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return const {};
      return parseSizesJson(raw);
    } catch (_) {
      return const {};
    }
  }

  Future<void> save(Map<String, ({double w, double h})> sizes) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (sizes.isEmpty) {
        await prefs.remove(_prefsKey);
        return;
      }
      await prefs.setString(_prefsKey, encodeSizesJson(sizes));
    } catch (_) {}
  }

  Future<void> put(String typeName, double wFrac, double hFrac) async {
    final all = Map<String, ({double w, double h})>.from(await load());
    all[typeName] = (w: _clampFrac(wFrac), h: _clampFrac(hFrac));
    await save(all);
  }

  static Map<String, ({double w, double h})> parseSizesJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final out = <String, ({double w, double h})>{};
      for (final e in decoded.entries) {
        final key = e.key?.toString();
        final v = e.value;
        if (key == null || key.isEmpty || v is! Map) continue;
        final w = _asDouble(v['w']);
        final h = _asDouble(v['h']);
        if (w == null || h == null) continue;
        out[key] = (w: _clampFrac(w), h: _clampFrac(h));
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  static String encodeSizesJson(Map<String, ({double w, double h})> sizes) {
    final map = <String, Map<String, double>>{};
    for (final e in sizes.entries) {
      map[e.key] = {'w': _clampFrac(e.value.w), 'h': _clampFrac(e.value.h)};
    }
    return jsonEncode(map);
  }

  static double _clampFrac(double v) => v.clamp(0.05, 1.0);

  static double? _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}
