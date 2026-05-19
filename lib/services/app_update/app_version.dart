/// Parses and compares semantic versions from pubspec / GitHub release tags.
final class AppVersion implements Comparable<AppVersion> {
  const AppVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.build,
  });

  final int major;
  final int minor;
  final int patch;
  final int? build;

  static AppVersion? tryParse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) {
      s = s.substring(1);
    }
    final plus = s.indexOf('+');
    int? build;
    if (plus >= 0) {
      build = int.tryParse(s.substring(plus + 1));
      s = s.substring(0, plus);
    }
    final parts = s.split('.');
    if (parts.isEmpty) return null;
    final nums = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part.trim());
      if (n == null) return null;
      nums.add(n);
    }
    while (nums.length < 3) {
      nums.add(0);
    }
    return AppVersion(
      major: nums[0],
      minor: nums[1],
      patch: nums[2],
      build: build,
    );
  }

  bool isNewerThan(AppVersion other) => compareTo(other) > 0;

  @override
  int compareTo(AppVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (pair.$1 != pair.$2) return pair.$1.compareTo(pair.$2);
    }
    final a = build ?? 0;
    final b = other.build ?? 0;
    return a.compareTo(b);
  }

  @override
  String toString() {
    final base = '$major.$minor.$patch';
    if (build == null) return base;
    return '$base+$build';
  }

  /// GitHub release tag style, e.g. [toString] `0.0.2` → `v0.0.2`.
  String toTagLabel() => 'v${toString().split('+').first}';

  /// User-facing label from [pubspec] / bundle version, e.g. `v0.0.2`.
  static String formatTagLabel(String version) {
    final core = version.trim().split('+').first;
    if (core.isEmpty) return 'v0.0.0';
    return core.startsWith('v') || core.startsWith('V') ? core : 'v$core';
  }
}
