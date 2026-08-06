import 'package:easyterm/widgets/sftp_browser.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sftpLocalPathFromClipboardFileUri', () {
    test('accepts file scheme uris', () {
      final path = sftpLocalPathFromClipboardFileUri(
        Uri.file('/Users/me/Documents/a.txt'),
      );
      expect(path, '/Users/me/Documents/a.txt');
    });

    test('rejects non-file schemes', () {
      expect(
        sftpLocalPathFromClipboardFileUri(Uri.parse('https://example.com/a')),
        isNull,
      );
      expect(
        sftpLocalPathFromClipboardFileUri(Uri.parse('content://media/1')),
        isNull,
      );
    });

    test('windows file uri uses platform path rules', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final path = sftpLocalPathFromClipboardFileUri(
        Uri.file(r'C:\Users\me\a.txt', windows: true),
      );
      expect(path, isNotNull);
      expect(path!.toLowerCase(), contains('a.txt'));
    });
  });
}
