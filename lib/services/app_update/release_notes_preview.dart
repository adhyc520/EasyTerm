/// Builds a short, human-readable update preview from GitHub release notes
/// and/or compare commit subjects.
final class ReleaseNotesPreview {
  ReleaseNotesPreview._();

  static final _fullChangelogLine = RegExp(
    r'^\s*(?:\*\*)?Full Changelog(?:\*\*)?:\s*https://github\.com/\S+/compare/(\S+?)\.\.\.(\S+)\s*$',
    multiLine: true,
  );

  static final _noiseOnly = RegExp(
    r'^(?:\s*(?:#{1,6}\s*)?(?:What.?s new|Changelog|Release notes)\s*)*$',
    caseSensitive: false,
  );

  /// True when [body] has no useful bullet/paragraph content for the dialog.
  static bool needsEnrichment(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return true;

    final withoutChangelog = trimmed
        .replaceAll(_fullChangelogLine, '')
        .trim();
    if (withoutChangelog.isEmpty) return true;
    if (_noiseOnly.hasMatch(withoutChangelog)) return true;

    // Auto-notes that are only a heading + compare link.
    final lines = withoutChangelog
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return true;
    if (lines.length == 1 && lines.first.startsWith('#')) return true;
    return false;
  }

  /// Parses `base...head` from a GitHub "Full Changelog" line, if present.
  static (String base, String head)? parseCompareRange(String body) {
    final match = _fullChangelogLine.firstMatch(body);
    if (match == null) return null;
    final base = match.group(1)?.trim() ?? '';
    final head = match.group(2)?.trim() ?? '';
    if (base.isEmpty || head.isEmpty) return null;
    return (base, head);
  }

  /// Keeps authored notes; drops a trailing Full Changelog-only line when
  /// other content already exists.
  static String sanitizeAuthoredBody(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return '';
    if (needsEnrichment(trimmed)) return trimmed;
    final cleaned = trimmed.replaceAll(_fullChangelogLine, '').trim();
    return cleaned.isEmpty ? trimmed : cleaned;
  }

  /// Formats commit subjects as a bullet list suitable for the update dialog.
  static String formatCommitSummaries(
    Iterable<String> subjects, {
    int maxItems = 12,
  }) {
    final seen = <String>{};
    final items = <String>[];
    for (final raw in subjects) {
      final subject = _normalizeSubject(raw);
      if (subject.isEmpty) continue;
      if (!_seenAdd(seen, subject)) continue;
      items.add(subject);
      if (items.length >= maxItems) break;
    }
    if (items.isEmpty) return '';
    return items.map((s) => '• $s').join('\n');
  }

  static String _normalizeSubject(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    // First line only (commit message body ignored).
    final nl = s.indexOf('\n');
    if (nl >= 0) s = s.substring(0, nl).trim();
    // Drop conventional merge noise.
    if (s.toLowerCase().startsWith('merge ')) return '';
    // Soften conventional-commit prefixes for display.
    s = s.replaceFirst(
      RegExp(r'^(feat|fix|chore|docs|refactor|perf|test|ci)(\([^)]*\))?:\s*',
          caseSensitive: false),
      '',
    );
    return s.trim();
  }

  static bool _seenAdd(Set<String> seen, String subject) {
    final key = subject.toLowerCase();
    if (seen.contains(key)) return false;
    seen.add(key);
    return true;
  }
}
