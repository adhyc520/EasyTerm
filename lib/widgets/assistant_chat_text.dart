import 'dart:convert';

/// 无可见字形的 Unicode。
final RegExp _invisibleGlyphs = RegExp(
  r'[\u3164\u115f\u1160\u2060\u180e\ufeff\u00ad\u200b-\u200d]',
);

/// OpenAI 多模态 `content` 数组 → 纯文本。
String? messageContentString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is List) {
    final buf = StringBuffer();
    for (final part in value) {
      if (part is! Map) continue;
      if (part['type'] == 'text') {
        final t = part['text'];
        if (t is String) buf.write(t);
      }
    }
    final s = buf.toString();
    return s.isEmpty ? null : s;
  }
  return value.toString();
}

/// 去掉 ANSI、零宽字符与多余空行。
String normalizeChatText(String text) {
  var s = text.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '');
  s = s.replaceAll(_invisibleGlyphs, '');
  s = s.replaceAll(RegExp(r'[ \t]+\n'), '\n');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

/// 是否像 Markdown（用于决定是否走 Markdown 渲染）。
bool looksLikeMarkdown(String text) {
  final s = text.trim();
  if (s.isEmpty) return false;
  return RegExp(
    r'(^#{1,6}\s|```|``|\*\*|__|^\s*[-*+]\s|^\s*\d+\.\s|\[[^\]]+\]\()',
    multiLine: true,
  ).hasMatch(s);
}

Map<String, dynamic>? tryParseToolJson(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {}
  return null;
}
