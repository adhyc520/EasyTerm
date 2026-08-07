import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easyterm/desktop/desktop_window_manager.dart';
import 'package:easyterm/services/desktop_settings_store.dart';
import 'package:easyterm/services/ssh_workspace_controller.dart';
import 'package:easyterm/services/workbench_settings_store.dart';

class _FakeController extends SshWorkspaceController {
  _FakeController()
      : super(
          settings: WorkbenchSettingsStore(),
          host: 'localhost',
          port: 22,
          username: 'u',
          password: '',
        );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopWindowManager workspaces', () {
    late DesktopWindowManager wm;

    setUp(() {
      final settings = WorkbenchSettingsStore();
      final desk = DesktopSettingsStore()..workspaceCount = 2;
      wm = DesktopWindowManager(
        controller: _FakeController(),
        hostKey: 'test-host',
        settings: settings,
        desktopSettings: desk,
      );
      wm.setDesktopSize(const Size(1200, 800));
    });

    tearDown(() => wm.dispose());

    test('windows getter is active workspace only', () {
      expect(wm.workspaces.length, 2);
      wm.open(DesktopAppType.files);
      expect(wm.windows.length, 1);
      wm.switchWorkspace(1);
      expect(wm.windows, isEmpty);
      wm.open(DesktopAppType.monitor);
      expect(wm.windows.length, 1);
      expect(wm.allWindows.length, 2);
    });

    test('moveWindowToWorkspace and switch', () {
      final a = wm.open(DesktopAppType.files);
      wm.moveWindowToWorkspace(a.id, 1);
      expect(wm.windows, isEmpty);
      wm.switchWorkspace(1);
      expect(wm.windows.single.id, a.id);
    });

    test('alwaysOnTop toggles', () {
      final w = wm.open(DesktopAppType.tasks);
      expect(w.alwaysOnTop, isFalse);
      wm.toggleAlwaysOnTop(w.id);
      expect(w.alwaysOnTop, isTrue);
    });

    test('tile left half', () {
      final w = wm.open(DesktopAppType.browser);
      wm.tile(w.id, TileZone.left);
      expect(w.rect.left, 0);
      expect(w.rect.width, closeTo(600, 0.5));
    });

    test('show desktop minimize/restore', () {
      wm.open(DesktopAppType.files);
      wm.open(DesktopAppType.logs);
      wm.toggleShowDesktop();
      expect(wm.showingDesktop, isTrue);
      expect(
        wm.windows.every((w) => w.state == WindowState.minimized),
        isTrue,
      );
      wm.toggleShowDesktop();
      expect(wm.showingDesktop, isFalse);
    });

    test('notifyConnectionRestored invokes hooks', () {
      final w = wm.open(DesktopAppType.monitor);
      var n = 0;
      w.onConnectionRestored = () => n++;
      wm.notifyConnectionRestored();
      expect(n, 1);
    });

    test('close clears connection restored hook', () {
      final w = wm.open(DesktopAppType.logs);
      w.onConnectionRestored = () {};
      wm.close(w.id);
      expect(wm.windows, isEmpty);
    });

    test('forwards and runCommand default titles', () {
      expect(
        DesktopWindowManager.defaultTitle(DesktopAppType.forwards, const {}),
        '端口转发',
      );
      expect(
        DesktopWindowManager.defaultTitle(DesktopAppType.runCommand, const {}),
        '运行命令',
      );
      expect(
        DesktopWindowManager.defaultTitle(DesktopAppType.cron, const {}),
        '计划任务',
      );
      expect(
        DesktopWindowManager.defaultTitle(DesktopAppType.users, const {}),
        '用户与组',
      );
      expect(
        DesktopWindowManager.defaultTitle(DesktopAppType.packages, const {}),
        '包管理器',
      );
      expect(
        DesktopWindowManager.defaultTitle(DesktopAppType.firewall, const {}),
        '防火墙',
      );
    });
  });
}
