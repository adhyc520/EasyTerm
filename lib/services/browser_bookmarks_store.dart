import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 浏览器书签条目（标题可与 URL 相同；[group] 空表示「默认」分组）。
class BrowserBookmark {
  const BrowserBookmark({
    required this.url,
    required this.title,
    this.group = '',
  });

  final String url;
  final String title;

  /// 分组名；空串在 UI 中展示为「默认」。
  final String group;

  /// 展示用标题：空标题时回落为 URL。
  String get displayTitle {
    final t = title.trim();
    return t.isEmpty ? url : t;
  }

  /// 展示用分组名。
  String get displayGroup {
    final g = group.trim();
    return g.isEmpty ? '默认' : g;
  }

  bool get hasDistinctTitle {
    final t = title.trim();
    return t.isNotEmpty && t != url;
  }
}

/// 按 host 持久化浏览器地址栏书签（远端目标字符串，如 `localhost:3000`）。
class BrowserBookmarksStore {
  BrowserBookmarksStore(this.hostKey);

  final String hostKey;

  String get _prefsKey => 'desktop_browser_bookmarks_$hostKey';

  static const int maxItems = 40;

  Future<List<BrowserBookmark>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey);
      if (raw == null) return <BrowserBookmark>[];
      return raw.map(_decode).where((b) => b.url.isNotEmpty).toList();
    } catch (_) {
      return <BrowserBookmark>[];
    }
  }

  Future<void> save(List<BrowserBookmark> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefsKey,
        items.map(_encode).toList(),
      );
    } catch (_) {}
  }

  Future<List<BrowserBookmark>> add(
    String url, {
    String? title,
    String? group,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return load();
    final resolvedTitle = (title ?? '').trim();
    final entry = BrowserBookmark(
      url: trimmed,
      title: resolvedTitle.isEmpty ? trimmed : resolvedTitle,
      group: (group ?? '').trim(),
    );
    final list = await load();
    list.removeWhere((e) => e.url == trimmed);
    list.insert(0, entry);
    if (list.length > maxItems) {
      list.removeRange(maxItems, list.length);
    }
    await save(list);
    return list;
  }

  Future<List<BrowserBookmark>> remove(String url) async {
    final list = await load();
    list.removeWhere((e) => e.url == url);
    await save(list);
    return list;
  }

  Future<List<BrowserBookmark>> rename(
    String url,
    String title, {
    String? group,
  }) async {
    final list = await load();
    final i = list.indexWhere((e) => e.url == url);
    if (i < 0) return list;
    final t = title.trim();
    list[i] = BrowserBookmark(
      url: list[i].url,
      title: t.isEmpty ? list[i].url : t,
      group: group != null ? group.trim() : list[i].group,
    );
    await save(list);
    return list;
  }

  /// 编码：优先 JSON（含可选 group）；旧数据为纯 URL；过渡格式为 `title\turl`。
  static String _encode(BrowserBookmark b) {
    final title = b.title.trim().isEmpty ? b.url : b.title.trim();
    final group = b.group.trim();
    if (title == b.url && group.isEmpty) return b.url;
    final map = <String, String>{'title': title, 'url': b.url};
    if (group.isNotEmpty) map['group'] = group;
    return jsonEncode(map);
  }

  static BrowserBookmark _decode(String raw) {
    final s = raw.trim();
    if (s.isEmpty) {
      return const BrowserBookmark(url: '', title: '');
    }
    if (s.startsWith('{')) {
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map) {
          final url = '${decoded['url'] ?? ''}'.trim();
          final title = '${decoded['title'] ?? ''}'.trim();
          final group = '${decoded['group'] ?? ''}'.trim();
          if (url.isNotEmpty) {
            return BrowserBookmark(
              url: url,
              title: title.isEmpty ? url : title,
              group: group,
            );
          }
        }
      } catch (_) {}
    }
    final tab = s.indexOf('\t');
    if (tab >= 0) {
      final title = s.substring(0, tab).trim();
      final url = s.substring(tab + 1).trim();
      if (url.isNotEmpty) {
        return BrowserBookmark(
          url: url,
          title: title.isEmpty ? url : title,
        );
      }
    }
    // 旧格式 url|title（若曾写入）
    final pipe = s.indexOf('|');
    if (pipe > 0) {
      final left = s.substring(0, pipe).trim();
      final right = s.substring(pipe + 1).trim();
      if (left.isNotEmpty &&
          right.isNotEmpty &&
          (left.startsWith('http://') ||
              left.startsWith('https://') ||
              left.contains(':'))) {
        return BrowserBookmark(
          url: left,
          title: right.isEmpty ? left : right,
        );
      }
    }
    return BrowserBookmark(url: s, title: s);
  }
}
