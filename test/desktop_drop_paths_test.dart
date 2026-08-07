import 'package:desktop_drop/desktop_drop.dart';
import 'package:easyterm/services/ssh_workspace_controller.dart';
import 'package:easyterm/util/desktop_drop_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    SshWorkspaceController.activeDragRemotePaths = const [];
    SshWorkspaceController.lastDragRemotePath = null;
  });

  group('resolveDesktopDropRemotePaths', () {
    test('prefers active multi-select remote batch', () {
      SshWorkspaceController.activeDragRemotePaths = const [
        '/home/a/one.txt',
        '/home/a/two.txt',
      ];
      final paths = resolveDesktopDropRemotePaths(
        const DropDoneDetails(
          files: [],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      expect(paths, ['/home/a/one.txt', '/home/a/two.txt']);
    });

    test('maps drag-temp local path to remote', () {
      SshWorkspaceController.registerDragTempPath(
        '/tmp/easyterm_drag_x',
        remotePath: '/var/log/syslog',
      );
      addTearDown(
        () => SshWorkspaceController.unregisterDragTempPath(
          '/tmp/easyterm_drag_x',
        ),
      );

      final paths = resolveDesktopDropRemotePaths(
        DropDoneDetails(
          files: [DropItemFile('/tmp/easyterm_drag_x')],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      expect(paths, ['/var/log/syslog']);
    });

    test('ignores plain local files without internal drag flag', () {
      SshWorkspaceController.lastDragRemotePath = '/stale/remote';
      final paths = resolveDesktopDropRemotePaths(
        DropDoneDetails(
          files: [DropItemFile('/Users/me/local.txt')],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
        isInternalDrag: false,
      );
      expect(paths, isEmpty);
    });

    test('last path fallback only when internal drag', () {
      SshWorkspaceController.lastDragRemotePath = '/home/a/virt.txt';
      final no = resolveDesktopDropRemotePaths(
        const DropDoneDetails(
          files: [],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
        isInternalDrag: false,
      );
      expect(no, isEmpty);

      final yes = resolveDesktopDropRemotePaths(
        const DropDoneDetails(
          files: [],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
        isInternalDrag: true,
      );
      expect(yes, ['/home/a/virt.txt']);
    });
  });
}
