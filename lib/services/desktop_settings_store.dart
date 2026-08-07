import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 远程桌面外壳偏好（壁纸 / 工作区 / snap / 托盘等），与终端 [WorkbenchSettingsStore] 分离。
final class DesktopSettingsStore extends ChangeNotifier {
  DesktopSettingsStore();

  static const _kWorkspaceCount = 'desktop_workspace_count';
  static const _kSnapEnabled = 'desktop_snap_enabled';
  static const _kSnapEdgePx = 'desktop_snap_edge_px';
  static const _kShowGrid = 'desktop_show_grid';
  static const _kWallpaper = 'desktop_wallpaper';
  static const _kTaskbarAutohide = 'desktop_taskbar_autohide';
  static const _kDefaultWFrac = 'desktop_default_window_w_frac';
  static const _kDefaultHFrac = 'desktop_default_window_h_frac';
  static const _kTrayShowClock = 'desktop_tray_show_clock';
  static const _kTrayShowMetrics = 'desktop_tray_show_metrics';
  static const _kLiveLogsDefault = 'desktop_live_logs_default';

  int workspaceCount = 2;
  bool snapEnabled = true;
  double snapEdgePx = 28;
  bool showGrid = true;
  String wallpaper = '';
  bool taskbarAutohide = false;
  double defaultWindowWFrac = 0.52;
  double defaultWindowHFrac = 0.58;
  bool trayShowClock = true;
  bool trayShowMetrics = true;
  bool liveLogsDefault = true;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    workspaceCount = (p.getInt(_kWorkspaceCount) ?? 2).clamp(1, 9);
    snapEnabled = p.getBool(_kSnapEnabled) ?? true;
    snapEdgePx = (p.getDouble(_kSnapEdgePx) ?? 28).clamp(8, 80);
    showGrid = p.getBool(_kShowGrid) ?? true;
    wallpaper = p.getString(_kWallpaper) ?? '';
    taskbarAutohide = p.getBool(_kTaskbarAutohide) ?? false;
    defaultWindowWFrac =
        (p.getDouble(_kDefaultWFrac) ?? 0.52).clamp(0.2, 1.0);
    defaultWindowHFrac =
        (p.getDouble(_kDefaultHFrac) ?? 0.58).clamp(0.2, 1.0);
    trayShowClock = p.getBool(_kTrayShowClock) ?? true;
    trayShowMetrics = p.getBool(_kTrayShowMetrics) ?? true;
    liveLogsDefault = p.getBool(_kLiveLogsDefault) ?? true;
    notifyListeners();
  }

  Future<void> persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kWorkspaceCount, workspaceCount.clamp(1, 9));
    await p.setBool(_kSnapEnabled, snapEnabled);
    await p.setDouble(_kSnapEdgePx, snapEdgePx);
    await p.setBool(_kShowGrid, showGrid);
    await p.setString(_kWallpaper, wallpaper);
    await p.setBool(_kTaskbarAutohide, taskbarAutohide);
    await p.setDouble(_kDefaultWFrac, defaultWindowWFrac);
    await p.setDouble(_kDefaultHFrac, defaultWindowHFrac);
    await p.setBool(_kTrayShowClock, trayShowClock);
    await p.setBool(_kTrayShowMetrics, trayShowMetrics);
    await p.setBool(_kLiveLogsDefault, liveLogsDefault);
    notifyListeners();
  }
}
