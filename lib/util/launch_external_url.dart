import 'dart:io';

import 'package:flutter/foundation.dart';

/// 用系统默认浏览器打开 [uri]（仅 http/https）。
///
/// Windows 走 `rundll32 url.dll,FileProtocolHandler`，避免 `cmd /c start`
/// 把查询串里的 `&` 当成命令分隔符。
Future<void> launchExternalBrowserUri(Uri uri) async {
  if (kIsWeb) {
    throw UnsupportedError('Web 不支持外部打开');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw ArgumentError.value(uri, 'uri', '仅支持 http/https');
  }
  final url = uri.toString();
  if (Platform.isMacOS) {
    final r = await Process.run('open', [url]);
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim();
      throw StateError(err.isEmpty ? 'open failed' : err);
    }
    return;
  }
  if (Platform.isWindows) {
    final r = await Process.run('rundll32', [
      'url.dll,FileProtocolHandler',
      url,
    ]);
    if (r.exitCode != 0) {
      throw StateError('rundll32 FileProtocolHandler failed');
    }
    return;
  }
  final r = await Process.run('xdg-open', [url]);
  if (r.exitCode != 0) {
    throw StateError('xdg-open failed');
  }
}
