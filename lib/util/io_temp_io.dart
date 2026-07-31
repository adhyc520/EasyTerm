import 'dart:io';

String createSystemTempDir(String prefix) =>
    Directory.systemTemp.createTempSync(prefix).path;

void deletePathRecursive(String path) {
  try {
    Directory(path).deleteSync(recursive: true);
  } catch (_) {}
}
