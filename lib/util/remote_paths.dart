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

/// Unix `/…` 或 Windows `C:\…` / `C:/…` 视为绝对路径。
bool isRemoteAbsolutePath(String path) {
  final t = path.trim();
  if (t.isEmpty) return false;
  if (t.startsWith('/')) return true;
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(t);
}

/// 规范化远端路径分隔符；Windows 盘符路径保留盘符写法。
String normalizeRemotePath(String path) {
  final t = path.trim();
  if (t.isEmpty) return t;
  if (RegExp(r'^[A-Za-z]:').hasMatch(t)) {
    return t.replaceAll('/', '\\');
  }
  return t.replaceAll('\\', '/');
}

/// 用于祖先/相等比较：统一 `/`、去掉末尾 `/`（根除外）；盘符小写。
String normalizeRemotePathForCompare(String path) {
  var t = path.trim().replaceAll('\\', '/');
  if (t.isEmpty) return t;
  if (t.length > 1 && t.endsWith('/')) {
    t = t.substring(0, t.length - 1);
  }
  if (RegExp(r'^[A-Za-z]:').hasMatch(t)) {
    t = '${t[0].toLowerCase()}${t.substring(1)}';
  }
  return t;
}

/// [path] 是否与 [ancestor] 相同，或位于其目录树之下（复制/移动到自身子路径检测）。
bool isRemotePathUnderOrEqual(String ancestor, String path) {
  final a = normalizeRemotePathForCompare(ancestor);
  final p = normalizeRemotePathForCompare(path);
  if (a.isEmpty || p.isEmpty) return false;
  if (a == p) return true;
  if (a == '/') return true;
  return p.startsWith('$a/');
}
