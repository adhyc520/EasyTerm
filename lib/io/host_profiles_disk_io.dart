import 'dart:io';

import 'package:path/path.dart' as p;

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

Future<void> deleteIfExists(String path) async {
  final f = File(path);
  if (await f.exists()) {
    await f.delete();
  }
}

Future<List<String>> listJsonBasenames(String dirPath) async {
  final d = Directory(dirPath);
  if (!await d.exists()) return const [];
  final out = <String>[];
  await for (final e in d.list(followLinks: false)) {
    if (e is File && e.path.endsWith('.json')) {
      out.add(p.basename(e.path));
    }
  }
  return out;
}
