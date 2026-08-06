import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../services/desktop_layout_store.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_settings_store.dart';

enum WindowState { normal, minimized, maximized }

enum DesktopAppType {
  terminal,
  files,
  browser,
  monitor,
  tasks,
  logs,
  containers,
  editor,
}

/// 贴边分屏区域（阶段 3）。
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
class DesktopWindowManager extends ChangeNotifier {
  DesktopWindowManager({
    required this.controller,
    required this.hostKey,
    required this.settings,
    DesktopLayoutStore? layoutStore,
  }) : _store = layoutStore ?? DesktopLayoutStore();

  final SshWorkspaceController controller;
  final String hostKey;
  final WorkbenchSettingsStore settings;
  final DesktopLayoutStore _store;

  static const double taskbarH = 44;
  static const double titleBarH = 30;
  static const double minWidth = 240;
  static const double minHeight = 160;

  final List<DesktopWindow> _windows = [];
  Size desktopSize = Size.zero;
  double _zSeq = 0;
  int _idSeq = 0;
  Timer? _persistTimer;
  bool _layoutRestored = false;
  bool _disposed = false;

  List<DesktopWindow> get windows => List.unmodifiable(_windows);

  DesktopWindow? get focusedWindow {
    for (final w in _windows) {
      if (w.focused) return w;
    }
    return null;
  }

  bool get layoutRestored => _layoutRestored;

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
      case DesktopAppType.editor:
        final path = args['path']?.toString();
        if (path != null && path.isNotEmpty) {
          final i = path.replaceAll('\\', '/').lastIndexOf('/');
          return i < 0 ? path : path.substring(i + 1);
        }
        return '编辑器';
    }
  }

  /// 供 App 更新标题等元数据后触发重绘；[persist] 为 true 时防抖落盘布局。
  void requestRebuild({bool persist = false}) {
    if (persist) _persistDebounced();
    notifyListeners();
  }

  DesktopWindow open(
    DesktopAppType type, {
    Map<String, dynamic>? args,
    Rect? rect,
    String? title,
    WindowState state = WindowState.normal,
    double? z,
    bool persist = true,
  }) {
    final a = Map<String, dynamic>.from(args ?? const {});
    final r = rect ?? _staggeredDefaultRect();
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
    focus(win.id, persist: false);
    if (persist) _persistDebounced();
    notifyListeners();
    return win;
  }

  void close(String id) {
    final i = _windows.indexWhere((w) => w.id == id);
    if (i < 0) return;
    final wasFocused = _windows[i].focused;
    _windows.removeAt(i);
    if (wasFocused && _windows.isNotEmpty) {
      // 聚焦 z 最大的可见窗口
      DesktopWindow? best;
      for (final w in _windows) {
        if (w.state == WindowState.minimized) continue;
        if (best == null || w.z > best.z) best = w;
      }
      best ??= _windows.last;
      focus(best.id, persist: false);
    }
    _persistDebounced();
    notifyListeners();
  }

  void focus(String id, {bool persist = true}) {
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
    final nextZ = ++_zSeq;
    if (target.z != nextZ) {
      target.z = nextZ;
      changed = true;
    }
    if (!changed) return;
    if (persist) _persistDebounced();
    notifyListeners();
  }

  void dragBy(String id, Offset delta) {
    final w = _find(id);
    if (w == null || w.state != WindowState.normal) return;
    if (desktopSize == Size.zero) return;
    final r = w.rect;
    final next = r.shift(delta);
    w.rect = _clampDragRect(next);
    _persistDebounced();
    notifyListeners();
  }

  void resizeBy(String id, ResizeEdge edge, Offset delta) {
    final w = _find(id);
    if (w == null || w.state != WindowState.normal) return;
    if (desktopSize == Size.zero) return;

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

    // 最小尺寸
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
    _persistDebounced();
    notifyListeners();
  }

  void minimize(String id) {
    final w = _find(id);
    if (w == null) return;
    if (w.state == WindowState.minimized) return;
    w.state = WindowState.minimized;
    w.focused = false;
    // 把焦点交给下一个
    DesktopWindow? best;
    for (final o in _windows) {
      if (o.id == id || o.state == WindowState.minimized) continue;
      if (best == null || o.z > best.z) best = o;
    }
    if (best != null) {
      focus(best.id, persist: false);
    }
    _persistDebounced();
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
    focus(id, persist: false);
    _persistDebounced();
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
    // minimized -> normal
    w.state = WindowState.normal;
    focus(id, persist: false);
    _persistDebounced();
    notifyListeners();
  }

  /// 贴边分屏：按 [zone] 占工作区一半或四分之一。
  void tile(String id, TileZone zone) {
    final w = _find(id);
    if (w == null) return;
    if (desktopSize == Size.zero) return;

    final workH = math.max(minHeight, desktopSize.height - taskbarH);
    final workW = math.max(minWidth, desktopSize.width);
    final halfW = workW / 2;
    final halfH = workH / 2;

    late Rect next;
    switch (zone) {
      case TileZone.left:
        next = Rect.fromLTWH(0, 0, halfW, workH);
      case TileZone.right:
        next = Rect.fromLTWH(halfW, 0, halfW, workH);
      case TileZone.top:
        next = Rect.fromLTWH(0, 0, workW, halfH);
      case TileZone.bottom:
        next = Rect.fromLTWH(0, halfH, workW, halfH);
      case TileZone.topLeft:
        next = Rect.fromLTWH(0, 0, halfW, halfH);
      case TileZone.topRight:
        next = Rect.fromLTWH(halfW, 0, halfW, halfH);
      case TileZone.bottomLeft:
        next = Rect.fromLTWH(0, halfH, halfW, halfH);
      case TileZone.bottomRight:
        next = Rect.fromLTWH(halfW, halfH, halfW, halfH);
    }

    w.preMaxRect = null;
    w.state = WindowState.normal;
    w.rect = _clampNormalRect(next);
    focus(id, persist: false);
    _persistDebounced();
    notifyListeners();
  }

  /// 拖动结束时：靠近边缘则自动贴边（阈值约 24px）。
  void snapDragEnd(String id) {
    final w = _find(id);
    if (w == null || w.state != WindowState.normal) return;
    if (desktopSize == Size.zero) return;

    const edge = 24.0;
    final r = w.rect;
    final workH = math.max(0.0, desktopSize.height - taskbarH);
    final cx = r.center.dx;
    final cy = r.center.dy;
    final nearLeft = r.left <= edge;
    final nearRight = r.right >= desktopSize.width - edge;
    final nearTop = r.top <= edge;
    final nearBottom = r.bottom >= workH - edge;

    TileZone? zone;
    if (nearLeft && nearTop) {
      zone = TileZone.topLeft;
    } else if (nearRight && nearTop) {
      zone = TileZone.topRight;
    } else if (nearLeft && nearBottom) {
      zone = TileZone.bottomLeft;
    } else if (nearRight && nearBottom) {
      zone = TileZone.bottomRight;
    } else if (nearLeft && cy > workH * 0.25 && cy < workH * 0.75) {
      zone = TileZone.left;
    } else if (nearRight && cy > workH * 0.25 && cy < workH * 0.75) {
      zone = TileZone.right;
    } else if (nearTop && cx > desktopSize.width * 0.25 && cx < desktopSize.width * 0.75) {
      // 顶边中部：最大化更符合直觉
      toggleMaximize(id);
      return;
    } else if (nearBottom) {
      zone = TileZone.bottom;
    }

    if (zone != null) tile(id, zone);
  }

  /// 退出桌面模式：落盘后清空窗口（触发各 App dispose 回收 shell/转发）。
  /// 下次进入会重新 [restoreLayout]。
  Future<void> leaveDesktop() async {
    if (_disposed) return;
    _persistTimer?.cancel();
    _persistTimer = null;
    await _persistNow();
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

  /// 进入桌面模式时调用：从磁盘还原；失败则空列表由视图开默认终端。
  Future<void> restoreLayout() async {
    if (_layoutRestored || _disposed) return;
    final data = await _store.load(hostKey);
    if (_disposed) return;
    // 等 load 完成后再标记，避免 bootstrap 与还原竞态
    _layoutRestored = true;
    if (data == null || data.windows.isEmpty) {
      notifyListeners();
      return;
    }
    _windows.clear();
    var maxZ = 0.0;
    var hasPrimaryTerminal = false;
    for (final item in data.windows) {
      final type = _parseType(item.type);
      if (type == null) continue;
      final state = _parseState(item.state);
      final rect = _rectFromFractions(item.rect);
      final args = Map<String, dynamic>.from(item.args);
      if (type == DesktopAppType.terminal && args['usePrimary'] == true) {
        hasPrimaryTerminal = true;
      }
      final win = DesktopWindow(
        id: _nextId(),
        type: type,
        title: defaultTitle(type, args),
        rect: _clampNormalRect(rect),
        state: state,
        z: item.z,
        focused: false,
        args: args,
      );
      _windows.add(win);
      if (item.z > maxZ) maxZ = item.z;
    }
    // 至少保留一个主终端窗口，复用会话 PTY 缓冲
    if (!hasPrimaryTerminal) {
      DesktopWindow? firstTerm;
      for (final w in _windows) {
        if (w.type == DesktopAppType.terminal) {
          firstTerm = w;
          break;
        }
      }
      if (firstTerm != null) {
        firstTerm.args['usePrimary'] = true;
      } else {
        _windows.insert(
          0,
          DesktopWindow(
            id: _nextId(),
            type: DesktopAppType.terminal,
            title: defaultTitle(DesktopAppType.terminal, const {'usePrimary': true}),
            rect: _clampNormalRect(_staggeredDefaultRect()),
            args: const {'usePrimary': true},
            z: ++maxZ,
          ),
        );
      }
    }
    _zSeq = maxZ;
    _idSeq = math.max(_idSeq, _windows.length);
    // 聚焦 z 最大的非最小化窗口
    DesktopWindow? best;
    for (final w in _windows) {
      if (w.state == WindowState.minimized) continue;
      if (best == null || w.z > best.z) best = w;
    }
    if (best != null) {
      focus(best.id, persist: false);
    }
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
      return open(
        DesktopAppType.terminal,
        args: const {'usePrimary': true},
      );
    }
    return open(DesktopAppType.terminal);
  }

  @override
  void dispose() {
    _disposed = true;
    _persistTimer?.cancel();
    _persistTimer = null;
    // 同步落盘一次
    unawaited(_persistNow());
    _windows.clear();
    super.dispose();
  }

  // --- internals ---

  DesktopWindow? _find(String id) {
    for (final w in _windows) {
      if (w.id == id) return w;
    }
    return null;
  }

  Rect _staggeredDefaultRect() {
    final i = _windows.length;
    final workH = math.max(minHeight, desktopSize.height - taskbarH);
    final workW = math.max(minWidth, desktopSize.width);
    final w = (workW * 0.52).clamp(minWidth, workW);
    final h = (workH * 0.58).clamp(minHeight, workH);
    final left = 40.0 + (i % 6) * 28.0;
    final top = 36.0 + (i % 6) * 28.0;
    return Rect.fromLTWH(left, top, w, h);
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

  Rect _rectFromFractions(List<double> frac) {
    if (desktopSize == Size.zero) {
      return Rect.fromLTWH(
        frac[0] * 800,
        frac[1] * 600,
        math.max(minWidth, frac[2] * 800),
        math.max(minHeight, frac[3] * 600),
      );
    }
    final workH = math.max(1.0, desktopSize.height - taskbarH);
    return Rect.fromLTWH(
      frac[0] * desktopSize.width,
      frac[1] * workH,
      math.max(minWidth, frac[2] * desktopSize.width),
      math.max(minHeight, frac[3] * workH),
    );
  }

  List<double> _fractionsFromRect(Rect r) {
    if (desktopSize == Size.zero ||
        desktopSize.width <= 0 ||
        desktopSize.height <= 0) {
      return [0.04, 0.06, 0.5, 0.6];
    }
    final workH = math.max(1.0, desktopSize.height - taskbarH);
    return [
      (r.left / desktopSize.width).clamp(0.0, 1.0),
      (r.top / workH).clamp(0.0, 1.0),
      (r.width / desktopSize.width).clamp(0.05, 1.0),
      (r.height / workH).clamp(0.05, 1.0),
    ];
  }

  void _persistDebounced() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persistNow());
    });
  }

  Future<void> _persistNow() async {
    if (_disposed) return;
    final items = <DesktopLayoutWindow>[];
    for (final w in _windows) {
      items.add(
        DesktopLayoutWindow(
          type: w.type.name,
          args: Map<String, dynamic>.from(w.args),
          rect: _fractionsFromRect(
            w.state == WindowState.maximized && w.preMaxRect != null
                ? w.preMaxRect!
                : w.rect,
          ),
          state: w.state.name,
          z: w.z,
        ),
      );
    }
    await _store.save(
      DesktopLayoutData(hostKey: hostKey, windows: items),
    );
  }

  static DesktopAppType? _parseType(String raw) {
    for (final t in DesktopAppType.values) {
      if (t.name == raw) return t;
    }
    return null;
  }

  static WindowState _parseState(String raw) {
    for (final s in WindowState.values) {
      if (s.name == raw) return s;
    }
    return WindowState.normal;
  }
}
