import 'package:shared_preferences/shared_preferences.dart';

/// 按 host 持久化浏览器最近访问（远端地址栏字符串）。
class BrowserHistoryStore {
  BrowserHistoryStore(this.hostKey);

  final String hostKey;

  String get _prefsKey => 'desktop_browser_history_$hostKey';

  Future<List<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey);
      if (raw == null) return <String>[];
      return List<String>.from(raw);
    } catch (_) {
      return <String>[];
    }
  }

  Future<void> save(List<String> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, items);
    } catch (_) {}
  }

  Future<List<String>> push(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return load();
    final list = await load();
    list.removeWhere((e) => e == trimmed);
    list.insert(0, trimmed);
    if (list.length > 50) {
      list.removeRange(50, list.length);
    }
    await save(list);
    return list;
  }

  Future<List<String>> clear() async {
    await save(const []);
    return <String>[];
  }
}
