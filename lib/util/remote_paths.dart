String remoteDirname(String path) {
  final normalized = path.replaceAll('\\', '/');
  if (normalized == '/' || normalized.isEmpty) return '/';
  final trimmed = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final i = trimmed.lastIndexOf('/');
  if (i <= 0) return '/';
  return trimmed.substring(0, i);
}

String remoteBasename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final trimmed = normalized.endsWith('/') && normalized.length > 1
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final i = trimmed.lastIndexOf('/');
  return i < 0 ? trimmed : trimmed.substring(i + 1);
}

String remoteJoin(String dir, String name) {
  if (dir == '/' || dir.isEmpty) return '/$name';
  final d = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  return '$d/$name';
}
