import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/desktop_settings_store.dart';
import '../services/desktop_window_size_store.dart';
import '../services/terminal_session_controller.dart';
import '../services/workbench_settings_store.dart';
import 'desktop_app_registry.dart';

enum WindowState { normal, minimized, maximized }

/// 贴边分屏区域（半屏 / 四分之一）。
enum TileZone {
  left,
  right,
  top,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

enum DesktopAppType {
  terminal,
  files,
  browser,
  monitor,
  tasks,
  logs,
  containers,
  diskUsage,
  transfers,
  editor,
  forwards,
  runCommand,
  cron,
  users,
  packages,
  firewall,
}

/// 窗口缩放手柄（4 边 + 4 角）。
enum ResizeEdge {
  left,
  right,
  top,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// 虚拟工作区（运行期组织；不持久化窗口清单）。
class DesktopWorkspace {
  DesktopWorkspace(this.id, this.name);

  final String id;
  String name;
  final List<DesktopWindow> windows = [];
}

class DesktopWindow {
  DesktopWindow({
    required this.id,
    required this.type,
    required this.title,
    required this.rect,
    this.state = WindowState.normal,
    this.z = 0,
    this.focused = false,
    this.alwaysOnTop = false,
    Map<String, dynamic>? args,
    this.preMaxRect,
  })  : args = args ?? <String, dynamic>{},
        focusScope = FocusScopeNode(debugLabel: 'desk-$id');

  final String id;
  final DesktopAppType type;
  String title;
  WindowState state;
  double z;
  bool focused;
  bool alwaysOnTop;
  final Map<String, dynamic> args;

  /// 本窗口内容的焦点域：失焦时统一 unfocus，避免终端/WebView 抢走其它窗输入。
  final FocusScopeNode focusScope;

  /// normal 态逻辑坐标（最大化时仍保留，或由 [preMaxRect] 还原）。
  Rect rect;
  Rect? preMaxRect;

  /// 编辑器多标签：尝试在本窗口打开 [path]；已存在则聚焦。返回是否已处理。
  bool Function(String path)? tryOpenEditorPath;

  /// 关闭前确认；返回 false 则取消关闭（如编辑器未保存）。
  Future<bool> Function()? onWillClose;

  /// SSH 重连成功后由桌面外壳调用，各 App 自行恢复。
  VoidCallback? onConnectionRestored;

  void disposeFocus() {
    focusScope.dispose();
  }

  /// 当前应绘制的几何（minimized 时仍返回 normal，由视图过滤）。
  Rect displayRect(Size desktopSize, double taskbarH) {
    if (state == WindowState.maximized) {
      final h = math.max(0.0, desktopSize.height - taskbarH);
      return Rect.fromLTWH(0, 0, desktopSize.width, h);
    }
    return rect;
  }
}

/// 桌面窗口几何 / z 序 / 状态管理；内容由 [RemoteDesktopView] 按 type 构建。
///
/// 不持久化窗口清单/位置：每次进入桌面都是空桌面（由视图开默认终端）。
/// 仅按 host + 应用类型记住上次缩放后的宽高，新开同类窗口复用该尺寸。
class DesktopWindowManager extends ChangeNotifier {
  DesktopWindowManager({
    required this.controller,
    required this.hostKey,
    required this.settings,
    DesktopSettingsStore? desktopSettings,
  })  : desktopSettings = desktopSettings ?? DesktopSettingsStore(),
        _sizeStore = DesktopWindowSizeStore(hostKey) {
    _initWorkspaces(this.desktopSettings.workspaceCount);
  }

  final TerminalSessionController controller;
  final String hostKey;
  final WorkbenchSettingsStore settings;
  final DesktopSettingsStore desktopSettings;
  final DesktopWindowSizeStore _sizeStore;

  static const double taskbarH = 44;
  static const double titleBarH = 30;
  static const double minWidth = 240;
  static const double minHeight = 160;
  static const int kDefaultWorkspaceCount = 2;

  final List<DesktopWorkspace> _workspaces = [];
  int _activeWs = 0;

  /// type.name → 相对工作区宽高（0..1）
  final Map<String, ({double w, double h})> _preferredSizes = {};
  Size desktopSize = Size.zero;
  double _zSeq = 0;
  int _idSeq = 0;
  int _wsIdSeq = 0;
  int _focusGeneration = 0;
  bool _layoutRestored = false;
  bool _disposed = false;
  Timer? _persistSizeTimer;
  String? _pendingPersistType;
  TileZone? _snapPreviewZone;
  String? _snapPreviewWindowId;
  bool _snapPreviewMaximize = false;
  bool _geometryNotifyScheduled = false;
  bool _dragActive = false;
  bool _resizeActive = false;
  List<String>? _showDesktopHiddenIds;

  double get _snapEdgePx => desktopSettings.snapEdgePx;

  List<DesktopWorkspace> get workspaces => List.unmodifiable(_workspaces);
  DesktopWorkspace get activeWorkspace => _workspaces[_activeWs];
  int get activeWorkspaceIndex => _activeWs;

  /// 当前工作区窗口（任务栏 / 既有调用兼容）。
  List<DesktopWindow> get windows =>
      List.unmodifiable(activeWorkspace.windows);

  /// 所有工作区窗口（渲染层 Offstage 保活）。
  List<DesktopWindow> get allWindows => [
        for (final ws in _workspaces) ...ws.windows,
      ];

  int workspaceIndexOfWindow(String id) {
    for (var i = 0; i < _workspaces.length; i++) {
      if (_workspaces[i].windows.any((w) => w.id == id)) return i;
    }
    return -1;
  }

  bool isWindowInActiveWorkspace(String id) =>
      workspaceIndexOfWindow(id) == _activeWs;

  /// 递增以通知已聚焦窗口重新夺取键盘焦点（如点标题栏）。
  int get focusGeneration => _focusGeneration;

  DesktopWindow? get focusedWindow {
    for (final w in activeWorkspace.windows) {
      if (w.focused) return w;
    }
    return null;
  }

  bool get layoutRestored => _layoutRestored;

  /// 「显示桌面」是否处于隐藏态。
  bool get showingDesktop =>
      _showDesktopHiddenIds != null && _showDesktopHiddenIds!.isNotEmpty;

  TileZone? get snapPreviewZone => _snapPreviewZone;
  String? get snapPreviewWindowId => _snapPreviewWindowId;
  bool get snapPreviewMaximize => _snapPreviewMaximize;

  Rect? get snapPreviewRect {
    if (_snapPreviewWindowId == null || desktopSize == Size.zero) return null;
    if (_snapPreviewMaximize) {
      final workH = math.max(0.0, desktopSize.height - taskbarH);
      return Rect.fromLTWH(0, 0, desktopSize.width, workH);
    }
    final zone = _snapPreviewZone;
    if (zone == null) return null;
    return rectForTileZone(zone);
  }

  bool get pointerGeometryActive => _dragActive || _resizeActive;

  void _initWorkspaces(int count) {
    _workspaces.clear();
    final n = count.clamp(1, 9);
    for (var i = 0; i < n; i++) {
      _workspaces.add(DesktopWorkspace('ws${++_wsIdSeq}', '桌面 ${i + 1}'));
    }
    _activeWs = 0;
  }

  String _nextId() => 'w${++_idSeq}';

  static String defaultTitle(DesktopAppType type, Map<String, dynamic> args) {
    switch (type) {
      case DesktopAppType.diskUsage:
        final path = args['path']?.toString();
        if (path != null && path.isNotEmpty && path != '/') {
          final i = path.replaceAll('\\', '/').lastIndexOf('/');
          final name = i < 0 ? path : path.substring(i + 1);
          return name.isEmpty ? metaFor(type).label : '占用 · $name';
        }
        return metaFor(type).label;
      case DesktopAppType.editor:
        final path = args['path']?.toString();
        if (path != null && path.isNotEmpty) {
          final i = path.replaceAll('\\', '/').lastIndexOf('/');
          return i < 0 ? path : path.substring(i + 1);
        }
        return metaFor(type).label;
      default:
        return metaFor(type).label;
    }
  }

  void notifyConnectionRestored() {
    for (final w in allWindows) {
      try {
        w.onConnectionRestored?.call();
      } catch (e) {
        debugPrint('onConnectionRestored: $e');
      }
    }
  }

  /// 标题等元数据变更后通知外壳重绘（不改变焦点）。
  void requestRebuild() => notifyListeners();

  void switchWorkspace(int i) {
    if (i < 0 || i >= _workspaces.length || i == _activeWs) return;
    _activeWs = i;
    final wins = activeWorkspace.windows;
    DesktopWindow? best;
    for (final w in allWindows) {
      w.focused = false;
    }
    for (final w in wins) {
      if (w.state == WindowState.minimized) continue;
      if (best == null || w.z > best.z) best = w;
    }
    if (best != null) {
      best.focused = true;
      _focusGeneration++;
    }
    _syncWindowFocusScopes(prefer: best);
    notifyListeners();
  }

  void addWorkspace({String? name}) {
    if (_workspaces.length >= 9) return;
    final idx = _workspaces.length;
    _workspaces.add(
      DesktopWorkspace('ws${++_wsIdSeq}', name ?? '桌面 ${idx + 1}'),
    );
    desktopSettings.workspaceCount = _workspaces.length;
    unawaited(desktopSettings.persist());
    notifyListeners();
  }

  void removeWorkspace(int i) {
    if (_workspaces.length <= 1) return;
    if (i < 0 || i >= _workspaces.length) return;
    final victim = _workspaces.removeAt(i);
    final target = _workspaces[i > 0 ? i - 1 : 0];
    target.windows.addAll(victim.windows);
    if (_activeWs >= _workspaces.length) {
      _activeWs = _workspaces.length - 1;
    } else if (_activeWs > i) {
      _activeWs--;
    } else if (_activeWs == i) {
      _activeWs = _activeWs.clamp(0, _workspaces.length - 1);
    }
    desktopSettings.workspaceCount = _workspaces.length;
    unawaited(desktopSettings.persist());
    notifyListeners();
  }

  void moveWindowToWorkspace(String winId, int wsIndex) {
    if (wsIndex < 0 || wsIndex >= _workspaces.length) return;
    DesktopWorkspace? from;
    DesktopWindow? win;
    for (final ws in _workspaces) {
      final j = ws.windows.indexWhere((w) => w.id == winId);
      if (j >= 0) {
        from = ws;
        win = ws.windows.removeAt(j);
        break;
      }
    }
    if (from == null || win == null) return;
    if (identical(from, _workspaces[wsIndex])) {
      from.windows.add(win);
      return;
    }
    win.focused = false;
    _workspaces[wsIndex].windows.add(win);
    notifyListeners();
  }

  void toggleAlwaysOnTop(String id) {
    final w = _find(id);
    if (w == null) return;
    w.alwaysOnTop = !w.alwaysOnTop;
    if (w.alwaysOnTop) w.z = ++_zSeq;
    notifyListeners();
  }

  /// 显示桌面：最小化当前工作区全部；再点恢复。
  void toggleShowDesktop() {
    final hidden = _showDesktopHiddenIds;
    if (hidden != null && hidden.isNotEmpty) {
      for (final id in hidden) {
        final w = _find(id);
        if (w != null && w.state == WindowState.minimized) {
          w.state = WindowState.normal;
        }
      }
      _showDesktopHiddenIds = null;
      notifyListeners();
      return;
    }
    final ids = <String>[];
    for (final w in activeWorkspace.windows) {
      if (w.state != WindowState.minimized) {
        ids.add(w.id);
        w.state = WindowState.minimized;
        w.focused = false;
      }
    }
    _showDesktopHiddenIds = ids;
    notifyListeners();
  }

  /// Whether [type] is allowed for the current session capabilities.
  bool canOpen(DesktopAppType type) {
    final needs = metaFor(type).needs;
    return needs.every(controller.capabilities.contains);
  }

  DesktopWindow? open(
    DesktopAppType type, {
    Map<String, dynamic>? args,
    Rect? rect,
    String? title,
    WindowState state = WindowState.normal,
    double? z,
  }) {
    if (!canOpen(type)) return null;
    final a = Map<String, dynamic>.from(args ?? const {});
    final r = rect ?? _staggeredDefaultRect(type);
    final win = DesktopWindow(
      id: _nextId(),
      type: type,
      title: title ?? defaultTitle(type, a),
      rect: _clampNormalRect(r),
      state: state,
      z: z ?? (++_zSeq),
      focused: false,
      args: a,
    );
    activeWorkspace.windows.add(win);
    focus(win.id);
    notifyListeners();
    return win;
  }

  void close(String id) {
    DesktopWorkspace? owner;
    var i = -1;
    for (final ws in _workspaces) {
      i = ws.windows.indexWhere((w) => w.id == id);
      if (i >= 0) {
        owner = ws;
        break;
      }
    }
    if (owner == null || i < 0) return;
    final wasFocused = owner.windows[i].focused;
    final closing = owner.windows[i];
    closing.onWillClose = null;
    closing.onConnectionRestored = null;
    closing.tryOpenEditorPath = null;
    closing.focusScope.unfocus();
    closing.disposeFocus();
    owner.windows.removeAt(i);
    if (wasFocused && owner.windows.isNotEmpty) {
      DesktopWindow? best;
      for (final w in owner.windows) {
        if (w.state == WindowState.minimized) continue;
        if (best == null || w.z > best.z) best = w;
      }
      best ??= owner.windows.last;
      focus(best.id);
    } else {
      notifyListeners();
    }
  }

  Future<bool> requestClose(String id) async {
    final w = _find(id);
    if (w == null) return true;
    final hook = w.onWillClose;
    if (hook != null) {
      final allow = await hook();
      if (!allow) return false;
    }
    close(id);
    return true;
  }

  void focus(String id, {bool reclaimKeyboard = true}) {
    final target = _find(id);
    if (target == null) return;
    final wi = workspaceIndexOfWindow(id);
    if (wi >= 0 && wi != _activeWs) {
      _activeWs = wi;
    }
    var changed = false;
    for (final w in allWindows) {
      final should = identical(w, target);
      if (w.focused != should) {
        w.focused = should;
        changed = true;
      }
    }
    if (target.state == WindowState.minimized) {
      target.state = WindowState.normal;
      changed = true;
    }
    if (target.z < _zSeq) {
      target.z = ++_zSeq;
      changed = true;
    }
    if (reclaimKeyboard) {
      _focusGeneration++;
      changed = true;
    }
    if (changed) {
      _syncWindowFocusScopes(prefer: target);
      notifyListeners();
    } else {
      // 已是焦点窗时仍确保其它窗焦点域已释放（防终端残留）。
      _syncWindowFocusScopes(prefer: target);
    }
  }

  /// 非焦点窗口的 [FocusScope] 一律放下，避免 PTY/WebView/输入框串台。
  void _syncWindowFocusScopes({DesktopWindow? prefer}) {
    for (final w in allWindows) {
      if (w.focused) continue;
      if (w.focusScope.hasFocus || w.focusScope.hasPrimaryFocus) {
        w.focusScope.unfocus();
      }
    }
    final target = prefer ?? focusedWindow;
    if (target == null || !target.focused) return;
    // 延迟到帧后：此时窗口子树已挂上 FocusScope。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !target.focused) return;
      if (!target.focusScope.canRequestFocus) return;
      if (!target.focusScope.hasFocus) {
        target.focusScope.requestFocus();
      }
    });
  }

  void beginDrag(String id) {
    final w = _find(id);
    if (w == null) return;
    _dragActive = true;
    _clearSnapPreview(notify: false);
    if (w.state == WindowState.maximized) {
      final prev = w.preMaxRect;
      w.state = WindowState.normal;
      if (prev != null) {
        w.rect = _clampNormalRect(prev);
      }
      w.preMaxRect = null;
    }
    _notifyGeometryChanged();
  }

  void dragBy(String id, Offset delta) {
    final w = _find(id);
    if (w == null || w.state != WindowState.normal) return;
    if (desktopSize == Size.zero) return;
    _dragActive = true;
    final next = w.rect.shift(delta);
    w.rect = _clampDragRect(next);
    if (desktopSettings.snapEnabled) {
      final hint = _detectSnapHint(w.rect);
      _snapPreviewMaximize = hint.maximize;
      _snapPreviewZone = hint.zone;
      _snapPreviewWindowId =
          (hint.maximize || hint.zone != null) ? id : null;
    } else {
      _clearSnapPreview(notify: false);
    }
    _notifyGeometryChanged();
  }

  void endDrag(String id) {
    final forThis = _snapPreviewWindowId == id;
    final maximize = forThis && _snapPreviewMaximize;
    final zone = forThis ? _snapPreviewZone : null;
    _dragActive = false;
    _clearSnapPreview(notify: false);
    if (maximize) {
      final w = _find(id);
      if (w != null && w.state != WindowState.maximized) {
        w.preMaxRect = w.rect;
        w.state = WindowState.maximized;
      }
      focus(id);
      _flushGeometryNotify();
      return;
    }
    if (zone != null) {
      tile(id, zone);
      return;
    }
    focus(id);
    _flushGeometryNotify();
  }

  void beginResize(String id) {
    _resizeActive = true;
    _notifyGeometryChanged();
  }

  void tile(String id, TileZone zone) {
    final w = _find(id);
    if (w == null || desktopSize == Size.zero) return;
    final target = rectForTileZone(zone);
    w.preMaxRect = null;
    w.state = WindowState.normal;
    w.rect = _clampNormalRect(target);
    _clearSnapPreview(notify: false);
    focus(id);
    notifyListeners();
  }

  /// 将窗口设为指定矩形（normal 态），用于三分等非 [TileZone] 贴靠布局。
  void setWindowRect(String id, Rect rect) {
    final w = _find(id);
    if (w == null || desktopSize == Size.zero) return;
    w.preMaxRect = null;
    w.state = WindowState.normal;
    w.rect = _clampNormalRect(rect);
    _clearSnapPreview(notify: false);
    focus(id);
    notifyListeners();
  }

  Rect rectForTileZone(TileZone zone) {
    final workH = math.max(0.0, desktopSize.height - taskbarH);
    final workW = math.max(0.0, desktopSize.width);
    final halfW = workW / 2;
    final halfH = workH / 2;
    switch (zone) {
      case TileZone.left:
        return Rect.fromLTWH(0, 0, halfW, workH);
      case TileZone.right:
        return Rect.fromLTWH(halfW, 0, workW - halfW, workH);
      case TileZone.top:
        return Rect.fromLTWH(0, 0, workW, halfH);
      case TileZone.bottom:
        return Rect.fromLTWH(0, halfH, workW, workH - halfH);
      case TileZone.topLeft:
        return Rect.fromLTWH(0, 0, halfW, halfH);
      case TileZone.topRight:
        return Rect.fromLTWH(halfW, 0, workW - halfW, halfH);
      case TileZone.bottomLeft:
        return Rect.fromLTWH(0, halfH, halfW, workH - halfH);
      case TileZone.bottomRight:
        return Rect.fromLTWH(halfW, halfH, workW - halfW, workH - halfH);
    }
  }

  void resizeBy(String id, ResizeEdge edge, Offset delta) {
    final w = _find(id);
    if (w == null || w.state != WindowState.normal) return;
    if (desktopSize == Size.zero) return;
    _resizeActive = true;

    var left = w.rect.left;
    var top = w.rect.top;
    var right = w.rect.right;
    var bottom = w.rect.bottom;

    final dx = delta.dx;
    final dy = delta.dy;

    switch (edge) {
      case ResizeEdge.left:
        left += dx;
      case ResizeEdge.right:
        right += dx;
      case ResizeEdge.top:
        top += dy;
      case ResizeEdge.bottom:
        bottom += dy;
      case ResizeEdge.topLeft:
        left += dx;
        top += dy;
      case ResizeEdge.topRight:
        right += dx;
        top += dy;
      case ResizeEdge.bottomLeft:
        left += dx;
        bottom += dy;
      case ResizeEdge.bottomRight:
        right += dx;
        bottom += dy;
    }

    if (right - left < minWidth) {
      if (edge == ResizeEdge.left ||
          edge == ResizeEdge.topLeft ||
          edge == ResizeEdge.bottomLeft) {
        left = right - minWidth;
      } else {
        right = left + minWidth;
      }
    }
    if (bottom - top < minHeight) {
      if (edge == ResizeEdge.top ||
          edge == ResizeEdge.topLeft ||
          edge == ResizeEdge.topRight) {
        top = bottom - minHeight;
      } else {
        bottom = top + minHeight;
      }
    }

    final workH = math.max(0.0, desktopSize.height - taskbarH);
    left = left.clamp(0.0, math.max(0.0, desktopSize.width - minWidth));
    top = top.clamp(0.0, math.max(0.0, workH - minHeight));
    right = right.clamp(left + minWidth, desktopSize.width);
    bottom = bottom.clamp(top + minHeight, workH);

    w.rect = Rect.fromLTRB(left, top, right, bottom);
    _rememberSize(w);
    _notifyGeometryChanged();
  }

  void cycleFocus({bool reverse = false}) {
    final candidates = activeWorkspace.windows
        .where((w) => w.state != WindowState.minimized)
        .toList()
      ..sort((a, b) => a.z.compareTo(b.z));
    if (candidates.isEmpty) {
      if (activeWorkspace.windows.isEmpty) return;
      restore(activeWorkspace.windows.last.id);
      return;
    }
    final focused = focusedWindow;
    var idx = focused == null
        ? -1
        : candidates.indexWhere((w) => identical(w, focused));
    if (reverse) {
      idx = idx <= 0 ? candidates.length - 1 : idx - 1;
    } else {
      idx = (idx + 1) % candidates.length;
    }
    focus(candidates[idx].id);
  }

  void endResize(String id) {
    final w = _find(id);
    _resizeActive = false;
    if (w == null || w.state != WindowState.normal) {
      _flushGeometryNotify();
      return;
    }
    _rememberSize(w);
    _flushPreferredSize(w.type);
    focus(id, reclaimKeyboard: false);
    _flushGeometryNotify();
  }

  void minimize(String id) {
    final w = _find(id);
    if (w == null) return;
    if (w.state == WindowState.minimized) return;
    w.state = WindowState.minimized;
    w.focused = false;
    DesktopWindow? best;
    for (final o in activeWorkspace.windows) {
      if (o.id == id || o.state == WindowState.minimized) continue;
      if (best == null || o.z > best.z) best = o;
    }
    if (best != null) {
      focus(best.id);
    } else {
      notifyListeners();
    }
  }

  void toggleMaximize(String id) {
    final w = _find(id);
    if (w == null) return;
    if (w.state == WindowState.maximized) {
      final prev = w.preMaxRect;
      w.state = WindowState.normal;
      if (prev != null) {
        w.rect = _clampNormalRect(prev);
      }
      w.preMaxRect = null;
    } else {
      if (w.state == WindowState.minimized) {
        w.state = WindowState.normal;
      }
      w.preMaxRect = w.rect;
      w.state = WindowState.maximized;
    }
    focus(id);
    notifyListeners();
  }

  void restore(String id) {
    final w = _find(id);
    if (w == null) return;
    if (w.state == WindowState.normal) {
      focus(id);
      return;
    }
    if (w.state == WindowState.maximized) {
      toggleMaximize(id);
      return;
    }
    w.state = WindowState.normal;
    focus(id);
    notifyListeners();
  }

  Future<void> leaveDesktop() async {
    if (_disposed) return;
    await _flushPendingPreferredSize();
    _disposeAllWindowFocus();
    for (final ws in _workspaces) {
      ws.windows.clear();
    }
    _showDesktopHiddenIds = null;
    _layoutRestored = false;
    notifyListeners();
  }

  void taskbarActivate(String id) {
    final w = _find(id);
    if (w == null) return;
    if (w.focused && w.state != WindowState.minimized) {
      minimize(id);
    } else {
      restore(id);
    }
  }

  void setDesktopSize(Size s) {
    if (s.width <= 0 || s.height <= 0) return;
    if ((s.width - desktopSize.width).abs() < 0.5 &&
        (s.height - desktopSize.height).abs() < 0.5) {
      return;
    }
    final old = desktopSize;
    desktopSize = s;
    if (old != Size.zero && old.width > 0 && old.height > 0) {
      final sx = s.width / old.width;
      final sy = s.height / old.height;
      for (final w in allWindows) {
        final r = w.rect;
        w.rect = _clampNormalRect(
          Rect.fromLTWH(r.left * sx, r.top * sy, r.width * sx, r.height * sy),
        );
      }
    } else {
      for (final w in allWindows) {
        w.rect = _clampNormalRect(w.rect);
      }
    }
    notifyListeners();
  }

  Future<void> prepareFreshDesktop() async {    if (_layoutRestored || _disposed) return;
    _layoutRestored = true;
    _disposeAllWindowFocus();
    for (final ws in _workspaces) {
      ws.windows.clear();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('desktop_layout_$hostKey');
    } catch (_) {}
    try {
      await desktopSettings.load();
      if (!_disposed) {
        final want = desktopSettings.workspaceCount.clamp(1, 9);
        if (_workspaces.length != want) {
          _initWorkspaces(want);
        }
      }
    } catch (_) {}
    try {
      final loaded = await _sizeStore.load();
      if (!_disposed) {
        _preferredSizes
          ..clear()
          ..addAll(loaded);
      }
    } catch (_) {}
    if (_disposed) return;
    notifyListeners();
  }

  bool get hasPrimaryTerminal {
    for (final w in allWindows) {
      if (w.type == DesktopAppType.terminal && w.args['usePrimary'] == true) {
        return true;
      }
    }
    return false;
  }

  DesktopWindow? openTerminal({bool preferPrimary = true}) {
    if (preferPrimary && !hasPrimaryTerminal) {
      return open(DesktopAppType.terminal, args: const {'usePrimary': true});
    }
    return open(DesktopAppType.terminal);
  }

  @override
  void dispose() {
    _disposed = true;
    _persistSizeTimer?.cancel();
    _persistSizeTimer = null;
    _geometryNotifyScheduled = false;
    _disposeAllWindowFocus();
    for (final ws in _workspaces) {
      ws.windows.clear();
    }
    super.dispose();
  }

  void _disposeAllWindowFocus() {
    for (final w in allWindows) {
      try {
        w.focusScope.unfocus();
        w.disposeFocus();
      } catch (_) {}
    }
  }

  void _notifyGeometryChanged() {
    if (_disposed || _geometryNotifyScheduled) return;
    _geometryNotifyScheduled = true;
    scheduleMicrotask(() {
      _geometryNotifyScheduled = false;
      if (_disposed) return;
      notifyListeners();
    });
  }

  void _flushGeometryNotify() {
    _geometryNotifyScheduled = false;
    if (_disposed) return;
    notifyListeners();
  }

  DesktopWindow? _find(String id) {
    for (final w in allWindows) {
      if (w.id == id) return w;
    }
    return null;
  }

  Rect _staggeredDefaultRect(DesktopAppType type) {
    final i = activeWorkspace.windows.length;
    final workH = math.max(minHeight, desktopSize.height - taskbarH);
    final workW = math.max(minWidth, desktopSize.width);
    final pref = _preferredSizes[type.name];
    final wFrac = pref?.w ?? desktopSettings.defaultWindowWFrac;
    final hFrac = pref?.h ?? desktopSettings.defaultWindowHFrac;
    final w = (workW * wFrac).clamp(minWidth, workW);
    final h = (workH * hFrac).clamp(minHeight, workH);
    final left = 40.0 + (i % 6) * 28.0;
    final top = 36.0 + (i % 6) * 28.0;
    return Rect.fromLTWH(left, top, w, h);
  }

  void _rememberSize(DesktopWindow w) {
    if (desktopSize == Size.zero) return;
    final workH = math.max(minHeight, desktopSize.height - taskbarH);
    final workW = math.max(minWidth, desktopSize.width);
    final wFrac = (w.rect.width / workW).clamp(0.05, 1.0);
    final hFrac = (w.rect.height / workH).clamp(0.05, 1.0);
    _preferredSizes[w.type.name] = (w: wFrac, h: hFrac);
    _pendingPersistType = w.type.name;
    _persistSizeTimer?.cancel();
    _persistSizeTimer = Timer(const Duration(milliseconds: 400), () {
      final typeName = _pendingPersistType;
      if (typeName == null || _disposed) return;
      _flushPreferredSizeName(typeName);
    });
  }

  void _flushPreferredSize(DesktopAppType type) {
    _flushPreferredSizeName(type.name);
  }

  void _flushPreferredSizeName(String typeName) {
    final size = _preferredSizes[typeName];
    if (size == null || _disposed) return;
    if (_pendingPersistType == typeName) {
      _persistSizeTimer?.cancel();
      _persistSizeTimer = null;
      _pendingPersistType = null;
    }
    unawaited(_sizeStore.put(typeName, size.w, size.h));
  }

  Future<void> _flushPendingPreferredSize() async {
    final typeName = _pendingPersistType;
    _persistSizeTimer?.cancel();
    _persistSizeTimer = null;
    _pendingPersistType = null;
    if (typeName == null) return;
    final size = _preferredSizes[typeName];
    if (size == null) return;
    await _sizeStore.put(typeName, size.w, size.h);
  }

  ({TileZone? zone, bool maximize}) _detectSnapHint(Rect r) {
    if (desktopSize == Size.zero) {
      return (zone: null, maximize: false);
    }
    final workH = math.max(0.0, desktopSize.height - taskbarH);
    final t = _snapEdgePx;
    final cx = r.left + r.width / 2;
    final cy = r.top + titleBarH / 2;
    final nearL = cx <= t || r.left <= t;
    final nearR =
        cx >= desktopSize.width - t || r.right >= desktopSize.width - t;
    final nearT = cy <= t || r.top <= t;
    final nearB = cy >= workH - t;
    if (nearL && nearT) return (zone: TileZone.topLeft, maximize: false);
    if (nearR && nearT) return (zone: TileZone.topRight, maximize: false);
    if (nearL && nearB) return (zone: TileZone.bottomLeft, maximize: false);
    if (nearR && nearB) return (zone: TileZone.bottomRight, maximize: false);
    if (nearL) return (zone: TileZone.left, maximize: false);
    if (nearR) return (zone: TileZone.right, maximize: false);
    if (nearT) return (zone: null, maximize: true);
    if (nearB) return (zone: TileZone.bottom, maximize: false);
    return (zone: null, maximize: false);
  }

  void _clearSnapPreview({bool notify = true}) {
    if (_snapPreviewZone == null &&
        _snapPreviewWindowId == null &&
        !_snapPreviewMaximize) {
      if (notify) notifyListeners();
      return;
    }
    _snapPreviewZone = null;
    _snapPreviewWindowId = null;
    _snapPreviewMaximize = false;
    if (notify) notifyListeners();
  }

  Rect _clampNormalRect(Rect r) {
    if (desktopSize == Size.zero) return r;
    final workH = math.max(0.0, desktopSize.height - taskbarH);
    var width = r.width.clamp(minWidth, math.max(minWidth, desktopSize.width));
    var height = r.height.clamp(minHeight, math.max(minHeight, workH));
    var left = r.left;
    var top = r.top;
    if (left + width > desktopSize.width) {
      left = desktopSize.width - width;
    }
    if (top + height > workH) {
      top = workH - height;
    }
    left = left.clamp(0.0, math.max(0.0, desktopSize.width - width)).toDouble();
    top = top.clamp(0.0, math.max(0.0, workH - height)).toDouble();
    return Rect.fromLTWH(left, top, width.toDouble(), height.toDouble());
  }

  Rect _clampDragRect(Rect r) {
    final workH = math.max(0.0, desktopSize.height - taskbarH);
    final minLeft = -r.width + 80;
    final maxLeft = desktopSize.width - 80;
    final minTop = 0.0;
    final maxTop = math.max(0.0, workH - titleBarH);
    final left = r.left
        .clamp(math.min(minLeft, maxLeft), math.max(minLeft, maxLeft))
        .toDouble();
    final top = r.top.clamp(minTop, maxTop).toDouble();
    return Rect.fromLTWH(left, top, r.width, r.height);
  }
}
