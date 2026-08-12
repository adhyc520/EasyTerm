import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CommandBookmark {
  CommandBookmark({
    required this.id,
    required this.label,
    required this.command,
    this.description,
    this.hostPattern,
    List<String>? tags,
    this.useCount = 0,
    DateTime? lastUsed,
    DateTime? createdAt,
  })  : tags = List<String>.from(tags ?? const []),
        lastUsed = lastUsed ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();

  final String id;
  String label;
  String command;
  String? description;
  String? hostPattern;
  List<String> tags;
  int useCount;
  DateTime lastUsed;
  DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'command': command,
        'description': description,
        'hostPattern': hostPattern,
        'tags': tags,
        'useCount': useCount,
        'lastUsed': lastUsed.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory CommandBookmark.fromJson(Map<String, Object?> json) {
    final rawTags = json['tags'];
    return CommandBookmark(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      command: json['command'] as String? ?? '',
      description: json['description'] as String?,
      hostPattern: json['hostPattern'] as String?,
      tags: rawTags is List
          ? rawTags.map((e) => '$e').where((e) => e.isNotEmpty).toList()
          : const [],
      useCount: (json['useCount'] as num?)?.toInt() ?? 0,
      lastUsed:
          DateTime.tryParse(json['lastUsed'] as String? ?? '') ?? DateTime.now(),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Persisted command bookmarks for the terminal command palette.
class CommandBookmarkStore extends ChangeNotifier {
  static const _prefsKey = 'easyterm.command_bookmarks.v1';

  final List<CommandBookmark> _items = [];
  bool _loaded = false;

  List<CommandBookmark> get items => List.unmodifiable(_items);
  bool get loaded => _loaded;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    _items.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final e in list) {
          if (e is Map) {
            _items.add(CommandBookmark.fromJson(Map<String, Object?>.from(e)));
          }
        }
      } catch (_) {
        // Corrupt data ignored.
      }
    }
    _sort();
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
  }

  void _sort() {
    _items.sort((a, b) {
      final byUse = b.useCount.compareTo(a.useCount);
      if (byUse != 0) return byUse;
      return b.lastUsed.compareTo(a.lastUsed);
    });
  }

  /// Fuzzy filter by label / command / tags / description.
  List<CommandBookmark> search(String query, {String? host}) {
    final q = query.trim().toLowerCase();
    final filtered = <CommandBookmark>[];
    for (final b in _items) {
      if (host != null && host.isNotEmpty && b.hostPattern != null) {
        final pat = b.hostPattern!.trim();
        if (pat.isNotEmpty && !_hostMatches(host, pat)) continue;
      }
      if (q.isEmpty) {
        filtered.add(b);
        continue;
      }
      final hay = [
        b.label,
        b.command,
        b.description ?? '',
        ...b.tags,
      ].join(' ').toLowerCase();
      if (hay.contains(q)) filtered.add(b);
    }
    return filtered;
  }

  static bool _hostMatches(String host, String pattern) {
    // Simple glob: * matches any run of chars.
    final escaped = RegExp.escape(pattern).replaceAll(r'\*', '.*');
    return RegExp('^$escaped\$', caseSensitive: false).hasMatch(host);
  }

  Future<CommandBookmark> create({
    required String label,
    required String command,
    String? description,
    String? hostPattern,
    List<String>? tags,
  }) async {
    await ensureLoaded();
    final clean = command.trimRight();
    if (clean.trim().isEmpty) {
      throw ArgumentError.value(command, 'command', 'Command cannot be empty.');
    }
    final item = CommandBookmark(
      id: 'cmd_${DateTime.now().microsecondsSinceEpoch}',
      label: label.trim().isEmpty ? clean.split('\n').first : label.trim(),
      command: clean,
      description: description?.trim().isEmpty == true
          ? null
          : description?.trim(),
      hostPattern: hostPattern?.trim().isEmpty == true
          ? null
          : hostPattern?.trim(),
      tags: tags,
    );
    _items.insert(0, item);
    _sort();
    await _persist();
    notifyListeners();
    return item;
  }

  Future<void> update({
    required String id,
    required String label,
    required String command,
    String? description,
    String? hostPattern,
    List<String>? tags,
  }) async {
    await ensureLoaded();
    final clean = command.trimRight();
    if (clean.trim().isEmpty) {
      throw ArgumentError.value(command, 'command', 'Command cannot be empty.');
    }
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    _items[i]
      ..label = label.trim().isEmpty ? clean.split('\n').first : label.trim()
      ..command = clean
      ..description =
          description?.trim().isEmpty == true ? null : description?.trim()
      ..hostPattern =
          hostPattern?.trim().isEmpty == true ? null : hostPattern?.trim();
    if (tags != null) {
      _items[i].tags = List<String>.from(tags);
    }
    _sort();
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    await ensureLoaded();
    _items.removeWhere((e) => e.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> recordUse(String id) async {
    await ensureLoaded();
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    _items[i]
      ..useCount += 1
      ..lastUsed = DateTime.now();
    _sort();
    await _persist();
    notifyListeners();
  }
}
