import 'package:shared_preferences/shared_preferences.dart';

/// 按 host 持久化 SFTP 路径书签。
class SftpBookmarksStore {
  SftpBookmarksStore(this.hostKey);

  final String hostKey;

  String get _prefsKey => 'desktop_sftp_bookmarks_$hostKey';

  static const int maxItems = 40;

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

  Future<List<String>> add(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return load();
    final list = await load();
    list.removeWhere((e) => e == trimmed);
    list.insert(0, trimmed);
    if (list.length > maxItems) {
      list.removeRange(maxItems, list.length);
    }
    await save(list);
    return list;
  }

  Future<List<String>> remove(String path) async {
    final list = await load();
    list.removeWhere((e) => e == path);
    await save(list);
    return list;
  }

  /// 已收藏则移除，否则加入；返回更新后的列表。
  Future<List<String>> toggle(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return load();
    final list = await load();
    if (list.contains(trimmed)) {
      list.removeWhere((e) => e == trimmed);
    } else {
      list.insert(0, trimmed);
      if (list.length > maxItems) {
        list.removeRange(maxItems, list.length);
      }
    }
    await save(list);
    return list;
  }
}

/// 按 host 持久化 SFTP 最近访问路径。
class SftpRecentStore {
  SftpRecentStore(this.hostKey);

  final String hostKey;

  String get _prefsKey => 'desktop_sftp_recent_$hostKey';

  static const int maxItems = 20;

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

  /// 导航时移到最前；返回更新后的列表。
  Future<List<String>> touch(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return load();
    final list = await load();
    list.removeWhere((e) => e == trimmed);
    list.insert(0, trimmed);
    if (list.length > maxItems) {
      list.removeRange(maxItems, list.length);
    }
    await save(list);
    return list;
  }
}
