import 'package:shared_preferences/shared_preferences.dart';

/// 按 host 持久化浏览器地址栏书签（远端目标字符串，如 `localhost:3000`）。
class BrowserBookmarksStore {
  BrowserBookmarksStore(this.hostKey);

  final String hostKey;

  String get _prefsKey => 'desktop_browser_bookmarks_$hostKey';

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

  Future<List<String>> add(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return load();
    final list = await load();
    list.removeWhere((e) => e == trimmed);
    list.insert(0, trimmed);
    if (list.length > 40) {
      list.removeRange(40, list.length);
    }
    await save(list);
    return list;
  }

  Future<List<String>> remove(String url) async {
    final list = await load();
    list.removeWhere((e) => e == url);
    await save(list);
    return list;
  }
}
