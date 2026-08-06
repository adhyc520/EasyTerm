import 'package:easyterm/services/remote_process_list.dart';
import 'package:easyterm/services/sftp_remote_copy.dart';
import 'package:easyterm/util/remote_paths.dart';
import 'package:easyterm/util/remote_shell_cd.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isRemotePathUnderOrEqual', () {
    test('equal and trailing slash', () {
      expect(isRemotePathUnderOrEqual('/var/www', '/var/www'), isTrue);
      expect(isRemotePathUnderOrEqual('/var/www/', '/var/www'), isTrue);
      expect(isRemotePathUnderOrEqual('/var/www', '/var/www/'), isTrue);
    });

    test('descendant is under', () {
      expect(isRemotePathUnderOrEqual('/a', '/a/b'), isTrue);
      expect(isRemotePathUnderOrEqual('/a/b', '/a/b/c/d'), isTrue);
      expect(isRemotePathUnderOrEqual('/', '/etc'), isTrue);
    });

    test('sibling or prefix-lookalike is not under', () {
      expect(isRemotePathUnderOrEqual('/a/b', '/a/b copy'), isFalse);
      expect(isRemotePathUnderOrEqual('/a/b', '/a/bc'), isFalse);
      expect(isRemotePathUnderOrEqual('/a/b', '/a'), isFalse);
      expect(isRemotePathUnderOrEqual('/a/b', '/x/a/b'), isFalse);
    });

    test('windows separators and drive case', () {
      expect(
        isRemotePathUnderOrEqual(r'C:\Users\a', r'C:\Users\a\docs'),
        isTrue,
      );
      expect(
        isRemotePathUnderOrEqual(r'c:/Users/a', r'C:\Users\a\docs'),
        isTrue,
      );
      expect(
        isRemotePathUnderOrEqual(r'C:\Users\a', r'C:\Users\ab'),
        isFalse,
      );
    });
  });

  group('assertRemoteCopyDestinationAllowed', () {
    test('allows sibling copy name', () {
      expect(
        () => assertRemoteCopyDestinationAllowed('/data/proj', '/data/proj copy'),
        returnsNormally,
      );
    });

    test('rejects self and descendant', () {
      expect(
        () => assertRemoteCopyDestinationAllowed('/data/proj', '/data/proj'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => assertRemoteCopyDestinationAllowed(
          '/data/proj',
          '/data/proj/backup/proj',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('SftpRemotePastePartialFailure', () {
    test('toString includes counts', () {
      final e = SftpRemotePastePartialFailure(
        pasted: const ['a'],
        failures: const ['b：boom'],
      );
      expect(e.toString(), contains('部分成功'));
      expect(e.toString(), contains('b：boom'));
    });

    test('all failed wording', () {
      final e = SftpRemotePastePartialFailure(
        pasted: const [],
        failures: const ['x：err'],
      );
      expect(e.toString(), contains('全部失败'));
    });
  });

  group('remoteShellCdCommand', () {
    test('posix quotes and escapes', () {
      expect(remoteShellCdCommand('/var/www', RemoteOsKind.linux), "cd '/var/www'");
      expect(
        remoteShellCdCommand("it's", RemoteOsKind.linux),
        "cd 'it'\\''s'",
      );
    });

    test('windows uses Set-Location LiteralPath', () {
      expect(
        remoteShellCdCommand(r'C:\Users\a', RemoteOsKind.windows),
        r"Set-Location -LiteralPath 'C:\Users\a'",
      );
      expect(
        remoteShellCdCommand(r"C:\O'Brien", RemoteOsKind.windows),
        r"Set-Location -LiteralPath 'C:\O''Brien'",
      );
    });
  });
}
