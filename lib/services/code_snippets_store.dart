import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CodeSnippet {
  CodeSnippet({
    required this.id,
    required this.name,
    required this.body,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;
  String body;
  DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'body': body,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory CodeSnippet.fromJson(Map<String, Object?> json) {
    return CodeSnippet(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      body: json['body'] as String? ?? '',
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// 本地代码块：新建 / 编辑 / 删除，运行由 UI 写入当前焦点终端。
class CodeSnippetsStore extends ChangeNotifier {
  static const _prefsKey = 'easyterm.code_snippets.v1';

  final List<CodeSnippet> _items = [];
  bool _loaded = false;

  List<CodeSnippet> get items => List.unmodifiable(_items);
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
            _items.add(CodeSnippet.fromJson(Map<String, Object?>.from(e)));
          }
        }
      } catch (_) {
        // 损坏数据忽略，保持空列表。
      }
    }
    _items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
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

  Future<CodeSnippet> create({
    required String name,
    required String body,
  }) async {
    await ensureLoaded();
    final cleanBody = body.trimRight();
    if (cleanBody.trim().isEmpty) {
      throw ArgumentError.value(body, 'body', 'Snippet body cannot be empty.');
    }
    final item = CodeSnippet(
      id: 'snip_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'Untitled' : name.trim(),
      body: cleanBody,
    );
    _items.insert(0, item);
    await _persist();
    notifyListeners();
    return item;
  }

  Future<void> update({
    required String id,
    required String name,
    required String body,
  }) async {
    await ensureLoaded();
    final cleanBody = body.trimRight();
    if (cleanBody.trim().isEmpty) {
      throw ArgumentError.value(body, 'body', 'Snippet body cannot be empty.');
    }
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    _items[i]
      ..name = name.trim().isEmpty ? 'Untitled' : name.trim()
      ..body = cleanBody
      ..updatedAt = DateTime.now();
    _items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    await ensureLoaded();
    _items.removeWhere((e) => e.id == id);
    await _persist();
    notifyListeners();
  }
}
