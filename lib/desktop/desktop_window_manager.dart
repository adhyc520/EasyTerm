import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/desktop_window_size_store.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_settings_store.dart';

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

class DesktopWindow {
  DesktopWindow({
    required this.id,
    required this.type,
    required this.title,
    required this.rect,
    this.state = WindowState.normal,
    this.z = 0,
    this.focused = false,
    Map<String, dynamic>? args,
    this.preMaxRect,
  }) : args = args ?? <String, dynamic>{};

  final String id;
  final DesktopAppType type;
  String title;
  WindowState state;
  double z;
  bool focused;
  final Map<String, dynamic> args;

  /// normal 态逻辑坐标（最大化时仍保留，或由 [preMaxRect] 还原）。
  Rect rect;
  Rect? preMaxRect;

  /// 关闭前确认；返回 false 则取消关闭（如编辑器未保存）。
  Future<bool> Function()? onWillClose;

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
  }) : _sizeStore = DesktopWindowSizeStore(hostKey);

  final SshWorkspaceController controller;
  final String hostKey;
  final WorkbenchSettingsStore settings;
  final DesktopWindowSizeStore _sizeStore;

  static const double taskbarH = 44;
  static const double titleBarH = 30;
  static const double minWidth = 240;
  static const double minHeight = 160;
  static const double _defaultWFrac = 0.52;
  static const double _defaultHFrac = 0.58;

  final List<DesktopWindow> _windows = [];
  /// type.name → 相对工作区宽高（0..1）
  final Map<String, ({double w, double h})> _preferredSizes = {};
  Size desktopSize = Size.zero;
  double _zSeq = 0;
  int _idSeq = 0;
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

  static const double _snapEdgePx = 28;

  List<DesktopWindow> get windows => List.unmodifiable(_windows);

  /// 递增以通知已聚焦窗口重新夺取键盘焦点（如点标题栏）。
  int get focusGeneration => _focusGeneration;

  DesktopWindow? get focusedWindow {
    for (final w in _windows) {
      if (w.focused) return w;
    }
    return null;
  }

  bool get layoutRestored => _layoutRestored;

  /// 拖动贴边时的预览区域（无则 null）。
  TileZone? get snapPreviewZone => _snapPreviewZone;

  String? get snapPreviewWindowId => _snapPreviewWindowId;

  /// 拖到顶边时预览最大化。
  bool get snapPreviewMaximize => _snapPreviewMaximize;

  /// 贴边预览矩形（相对桌面坐标，不含任务栏）。
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

  /// 正在拖动或缩放：窗口框应暂时去掉 MouseRegion，避免 mouse_tracker 重入。
  bool get pointerGeometryActive => _dragActive || _resizeActive;

  String _nextId() => 'w${++_idSeq}';

  static String defaultTitle(DesktopAppType type, Map<String, dynamic> args) {
    switch (type) {
      case DesktopAppType.terminal:
        return '终端';
      case DesktopAppType.files:
        return '文件';
      case DesktopAppType.browser:
        return '浏览器';
      case DesktopAppType.monitor:
        return '监控';
      case DesktopAppType.tasks:
        return '任务管理器';
      case DesktopAppType.logs:
        return '日志';
      case DesktopAppType.containers:
        return '容器';
      case DesktopAppType.diskUsage:
        final path = args['path']?.toString();
        if (path != null && path.isNotEmpty && path != '/') {
          final i = path.replaceAll('\\', '/').lastIndexOf('/');
          final name = i < 0 ? path : path.substring(i + 1);
          return name.isEmpty ? '磁盘占用' : '占用 · $name';
        }
        return '磁盘占用';
      case DesktopAppType.transfers:
        return '传输';
      case DesktopAppType.editor:
        final path = args['path']?.toString();
        if (path != null && path.isNotEmpty) {
          final i = path.replaceAll('\\', '/').lastIndexOf('/');
          return i < 0 ? path : path.substring(i + 1);
        }
        return '编辑器';
    }
  }

  /// 供 App 更新标题等元数据后触发重绘。
  void requestRebuild() {
    notifyListeners();
  }

  DesktopWindow open(
    DesktopAppType type, {
    Map<String, dynamic>? args,
    Rect? rect,
    String? title,
    WindowState state = WindowState.normal,
    double? z,
  }) {
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
    _windows.add(win);
    focus(win.id);
    notifyListeners();
    return win;
  }

  void close(String id) {
    final i = _windows.indexWhere((w) => w.id == id);
    if (i < 0) return;
    final wasFocused = _windows[i].focused;
    _windows[i].onWillClose = null;
    _windows.removeAt(i);
    if (wasFocused && _windows.isNotEmpty) {
      DesktopWindow? best;
      for (final w in _windows) {
        if (w.state == WindowState.minimized) continue;
        if (best == null || w.z > best.z) best = w;
      }
      best ??= _windows.last;
      focus(best.id);
    }
    notifyListeners();
  }

  /// 带 [DesktopWindow.onWillClose] 确认的关闭。
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
    var changed = false;
    for (final w in _windows) {
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
    // 已在最前则不抬 z，避免缩放/拖动 onPanStart 无谓整桌面重建打断指针。
    if (target.z < _zSeq) {
      target.z = ++_zSeq;
      changed = true;
    }
    if (reclaimKeyboard) {
      _focusGeneration++;
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
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
    final hint = _detectSnapHint(w.rect);
    _snapPreviewMaximize = hint.maximize;
    _snapPreviewZone = hint.zone;
    _snapPreviewWindowId =
        (hint.maximize || hint.zone != null) ? id : null;
    // 指针事件中同步 notify 会带着 MouseRegion 重建，触发 mouse_tracker 重入断言。
    _notifyGeometryChanged();
  }

  /// 标题栏拖动结束：若靠近边缘则贴边分屏或最大化。
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

  /// 贴边分屏到指定区域（写入 normal rect，退出最大化）。
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

  /// 工作区内某贴边区域的目标矩形。
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

  /// 在可见窗口间循环焦点。
  void cycleFocus({bool reverse = false}) {
    final candidates = _windows
        .where((w) => w.state != WindowState.minimized)
        .toList()
      ..sort((a, b) => a.z.compareTo(b.z));
    if (candidates.isEmpty) {
      if (_windows.isEmpty) return;
      restore(_windows.last.id);
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

  /// 缩放手势结束：立即落盘当前类型的优选尺寸，并刷新几何。
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
    for (final o in _windows) {
      if (o.id == id || o.state == WindowState.minimized) continue;
      if (best == null || o.z > best.z) best = o;
    }
    if (best != null) {
      focus(best.id);
    }
    notifyListeners();
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

  /// 退出桌面模式：清空窗口（触发各 App dispose 回收 shell/转发）。
  /// 下次进入从空桌面开始；已记住的窗口尺寸会保留。
  Future<void> leaveDesktop() async {
    if (_disposed) return;
    await _flushPendingPreferredSize();
    _windows.clear();
    _layoutRestored = false;
    notifyListeners();
  }

  /// 任务栏按钮：已聚焦则最小化，否则聚焦（并还原）。
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
      for (final w in _windows) {
        final r = w.rect;
        w.rect = _clampNormalRect(
          Rect.fromLTWH(r.left * sx, r.top * sy, r.width * sx, r.height * sy),
        );
      }
    } else {
      for (final w in _windows) {
        w.rect = _clampNormalRect(w.rect);
      }
    }
    notifyListeners();
  }

  /// 进入桌面：标记就绪；加载按类型的优选尺寸；不还原窗口清单/位置。
  Future<void> prepareFreshDesktop() async {
    if (_layoutRestored || _disposed) return;
    _layoutRestored = true;
    _windows.clear();
    // 清掉历史版本按 host 落盘的完整布局，避免残留。
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('desktop_layout_$hostKey');
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

  /// 是否已有复用主 shell 的终端窗口。
  bool get hasPrimaryTerminal {
    for (final w in _windows) {
      if (w.type == DesktopAppType.terminal && w.args['usePrimary'] == true) {
        return true;
      }
    }
    return false;
  }

  /// 打开终端：若尚无主终端则优先复用主 shell。
  DesktopWindow openTerminal({bool preferPrimary = true}) {
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
    _windows.clear();
    super.dispose();
  }

  // --- internals ---

  /// 拖动/缩放等高频几何变更：合并到微任务再通知，避开指针事件中的 mouse_tracker 临界区。
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
    for (final w in _windows) {
      if (w.id == id) return w;
    }
    return null;
  }

  Rect _staggeredDefaultRect(DesktopAppType type) {
    final i = _windows.length;
    final workH = math.max(minHeight, desktopSize.height - taskbarH);
    final workW = math.max(minWidth, desktopSize.width);
    final pref = _preferredSizes[type.name];
    final wFrac = pref?.w ?? _defaultWFrac;
    final hFrac = pref?.h ?? _defaultHFrac;
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
    // 顶边中央：最大化（与 Win/mac 习惯一致）；底边：下半屏。
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
    // 标题栏中心点保持在桌面内：left ∈ [-w+80, desktopW-80], top ∈ [0, workH-titleBarH]
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
