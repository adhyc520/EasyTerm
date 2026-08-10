import 'package:shared_preferences/shared_preferences.dart';

/// Global find-query history shared across editor instances.
class EditorFindHistoryStore {
  EditorFindHistoryStore._();

  static const _prefsKey = 'editor_find_history';
  static const maxEntries = 20;

  static Future<List<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey);
      if (raw == null) return <String>[];
      return List<String>.from(raw);
    } catch (_) {
      return <String>[];
    }
  }

  static Future<void> save(List<String> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, items);
    } catch (_) {}
  }

  static Future<List<String>> push(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return load();
    final list = await load();
    list.removeWhere((e) => e == trimmed);
    list.insert(0, trimmed);
    if (list.length > maxEntries) {
      list.removeRange(maxEntries, list.length);
    }
    await save(list);
    return list;
  }
}
