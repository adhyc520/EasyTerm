import 'dart:io';

Future<String?> readUtf8IfExists(String path) async {
  final f = File(path);
  if (!await f.exists()) return null;
  return f.readAsString();
}

Future<void> writeUtf8EnsureParent(String path, String content) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  await f.writeAsString(content);
}
