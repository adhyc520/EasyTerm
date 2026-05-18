// ignore_for_file: implementation_imports
//
// 文件夹拖出：与普通文件一样使用 ImmediateMultiDrag（移动约 4px 后启动拖动）；
// 单击仍然进入目录，因为 Tap 仅在 pointer-up 且未达手势容差时获胜，与立即拖动互不冲突。
// 目录下载很慢，若使用与普通文件相同的 [DragItemWidget.createItem]（先下载再快照），拖影常常失败；
// [PreSnapshotDragItemWidget] 仅用于文件夹：先快照再下载。
//
// **手势须在 [WidgetSnapshotter] 之外**：[WidgetSnapshotter] 首次注册快照时会重建子树；
// 若 [RawGestureDetector] 在它的 inner 子树里会被拆掉，表现为目录完全拖不动。
//
// 鼠标使用 4px 容差（与 super_drag 文件拖曳一致），避免 Flutter 默认 ~1px 导致误判。
//
// 注意：文件夹不能使用 [BaseDraggableRenderWidget]，否则 macOS 会在用户尚未表达拖动意图前就触发
// 配置拉取并长时间阻塞下载。手动 [raw.DragContext.startDrag] 让我们能在数据准备好后再调起原生拖放。

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:super_drag_and_drop/src/into_raw.dart';
import 'package:super_native_extensions/raw_drag_drop.dart' as raw;

/// 目录拖出准备（下载到临时目录）阶段，与该 [DragSession] 关联的中止标志。
/// 通过 [Expando] 而非全局变量保存，避免用户连续点击不同目录时多个准备任务互相干扰。
final Expando<_SftpDragToken> _sftpFolderDragTokenForSession =
    Expando<_SftpDragToken>('SftpFolderDragToken');

/// 返回与给定 [session] 关联的目录拖出准备是否应当中止；
/// 用于 [SftpFolder] 拖出准备阶段（下载到临时目录）期间，让传输层可以提前结束。
bool sftpFolderDragShouldAbort(DragSession session) {
  return _sftpFolderDragTokenForSession[session]?.ended ?? false;
}

// ─── 仅 SFTP 文件夹：先快照再执行 dragItemProvider ──────────────────────────────

final Object _kFolderLiftSnapshotKey = Object();
final Object _kFolderDragSnapshotKey = Object();

class _SftpFolderDragHostScope extends InheritedWidget {
  const _SftpFolderDragHostScope({
    required this.hostState,
    required super.child,
  });

  final PreSnapshotDragItemWidgetState hostState;

  static PreSnapshotDragItemWidgetState? maybeOf(BuildContext context) {
    final scope =
        context.getInheritedWidgetOfExactType<_SftpFolderDragHostScope>();
    return scope?.hostState;
  }

  @override
  bool updateShouldNotify(_SftpFolderDragHostScope oldWidget) =>
      oldWidget.hostState != hostState;
}

/// 与 [DragItemWidget] API 相同，但 [createItem] 先截拖影再 await [dragItemProvider]。
class PreSnapshotDragItemWidget extends StatefulWidget {
  const PreSnapshotDragItemWidget({
    super.key,
    required this.child,
    required this.dragItemProvider,
    required this.allowedOperations,
    this.liftBuilder,
    this.dragBuilder,
    this.canAddItemToExistingSession = false,
  });

  final Widget? Function(BuildContext context, Widget child)? liftBuilder;
  final Widget? Function(BuildContext context, Widget child)? dragBuilder;
  final Widget child;
  final DragItemProvider dragItemProvider;
  final ValueGetter<List<DropOperation>> allowedOperations;
  final bool canAddItemToExistingSession;

  @override
  State<StatefulWidget> createState() => PreSnapshotDragItemWidgetState();
}

class _FolderDragPreviewImage {
  _FolderDragPreviewImage({
    required this.image,
    this.liftImage,
  });

  final TargetedWidgetSnapshot image;
  final TargetedWidgetSnapshot? liftImage;
}

class PreSnapshotDragItemWidgetState extends State<PreSnapshotDragItemWidget> {
  final GlobalKey<WidgetSnapshotterState> _snapshotterKey =
      GlobalKey<WidgetSnapshotterState>();

  // 不在 [Listener] 中做 pointer-down 预注册 / 滚动挂起：
  // 一旦原生拖放接管鼠标，Flutter 再也不会触发 [PointerUpEvent]/[PointerCancelEvent]，
  // 任何在 pointer-down 时获取的 [ScrollHoldController] 都会泄漏并冻结 [ListView]。
  // [_capturePreview] 通过 [WidgetSnapshotterState.getSnapshot] 自行做懒注册和释放。

  Future<_FolderDragPreviewImage?> _capturePreview(Offset location) async {
    final snapshotter = _snapshotterKey.currentState;
    if (snapshotter == null || !snapshotter.mounted) return null;

    TargetedWidgetSnapshot? liftSnapshot;
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      liftSnapshot = await snapshotter.getSnapshot(
        location,
        _kFolderLiftSnapshotKey,
        () => widget.liftBuilder?.call(context, widget.child),
      );
    }

    final snapshot = await snapshotter.getSnapshot(
      location,
      _kFolderDragSnapshotKey,
      () => widget.dragBuilder?.call(context, widget.child),
    );

    if (snapshot == null) return null;
    return _FolderDragPreviewImage(image: snapshot, liftImage: liftSnapshot);
  }

  Future<DragConfigurationItem?> createItem(
    Offset location,
    DragSession session,
  ) async {
    final preview = await _capturePreview(location);
    if (preview == null) return null;

    final request = DragItemRequest(location: location, session: session);
    final item = await widget.dragItemProvider(request);
    if (item == null) return null;

    return DragConfigurationItem(
      item: item,
      image: preview.image,
      liftImage: preview.liftImage,
    );
  }

  Future<List<DropOperation>> getAllowedOperations() async {
    return widget.allowedOperations();
  }

  @override
  Widget build(BuildContext context) {
    return _SftpFolderDragHostScope(
      hostState: this,
      child: SftpFolderDelayedDraggable(
        hitTestBehavior: HitTestBehavior.opaque,
        child: WidgetSnapshotter(
          key: _snapshotterKey,
          child: widget.child,
        ),
      ),
    );
  }
}

// ─── DragContext + 延迟 multidrag ─────────────────────────────────────────────

class _SftpDragToken implements Drag {
  bool _ended = false;

  @override
  void cancel() {
    _ended = true;
  }

  @override
  void end(DragEndDetails details) {
    _ended = true;
  }

  @override
  void update(DragUpdateDetails details) {}

  bool get ended => _ended;
}

Future<void> _sftpMaybeStartDragWithSession(
  raw.DragContext dragContext,
  BuildContext buildContext,
  Offset position,
  DragSession session,
  double devicePixelRatio,
  _SftpDragToken drag,
  DragConfigurationProvider dragConfiguration,
) async {
  DragConfiguration? configuration;
  try {
    configuration = await dragConfiguration(position, session);
  } catch (_) {
    configuration = null;
  }
  // 不论何种原因失败/中止，都必须取消会话，否则原生侧会泄漏一个未启动的拖动 session，
  // 后续的拖动准备和点击都可能被卡住。
  if (drag.ended || configuration == null) {
    dragContext.cancelSession(session);
    return;
  }
  final rawConfiguration = await configuration.intoRaw(devicePixelRatio);
  // intoRaw 之后再校验一次：在序列化期间用户可能已经松手或者 widget 已被卸载。
  if (!buildContext.mounted || drag.ended) {
    rawConfiguration.disposeImages();
    dragContext.cancelSession(session);
    return;
  }
  session.dragCompleted.addListener(() {
    rawConfiguration.disposeImages();
  });
  try {
    await dragContext.startDrag(
      buildContext: buildContext,
      session: session,
      configuration: rawConfiguration,
      position: position,
    );
  } catch (_) {
    // startDrag 抛出（原生侧异常）时务必释放图像并取消会话，
    // 否则下一次拖动准备会被该悬空会话阻塞，引起面板「卡死」。
    rawConfiguration.disposeImages();
    dragContext.cancelSession(session);
  }
}

Drag? _sftpMaybeStartDrag(
  BuildContext buildContext,
  int? pointer,
  Offset position_,
  double devicePixelRatio,
  DragConfigurationProvider dragConfiguration,
) {
  final position = Offset(
    (position_.dx * devicePixelRatio).roundToDouble() / devicePixelRatio,
    (position_.dy * devicePixelRatio).roundToDouble() / devicePixelRatio,
  );
  final drag = _SftpDragToken();
  unawaited(() async {
    DragSession? session;
    try {
      final dragContext = await raw.DragContext.instance();
      if (!buildContext.mounted) return;
      session = dragContext.newSession(pointer: pointer);
      // 关联当前 session 与 drag token：[sftpFolderDragShouldAbort] 让 dragItemProvider
      // 可以查询「用户是否已松手」，且仅作用于本次会话，不会被另一次并发的拖动准备覆盖。
      _sftpFolderDragTokenForSession[session] = drag;
      // 目录下载可能耗时数秒，固定 50ms 后看 [session.dragging] 总是 false，会导致
      // 原生侧实际启动拖动后，鼠标 hover 仍滞留在 Flutter 端。改为在 dragging 真的为 true
      // 时再把 pointer 从 mouseTracker 里移除。
      if (pointer != null) {
        void onDraggingChanged() {
          final s = session;
          if (s == null || !s.dragging.value) return;
          s.dragging.removeListener(onDraggingChanged);
          final event = PointerRemovedEvent(
            pointer: pointer,
            kind: PointerDeviceKind.mouse,
          );
          RendererBinding.instance.mouseTracker.updateWithEvent(
            event,
            HitTestResult(),
          );
        }

        session.dragging.addListener(onDraggingChanged);
      }
      await _sftpMaybeStartDragWithSession(
        dragContext,
        buildContext,
        position,
        session,
        devicePixelRatio,
        drag,
        dragConfiguration,
      );
    } finally {
      // 主动断开 Expando 关联（虽然会随 session GC 自动失效，但显式 null 化更清晰）。
      if (session != null) {
        _sftpFolderDragTokenForSession[session] = null;
      }
    }
  }());
  return drag;
}

double _folderDragSlop(
  PointerDeviceKind kind,
  DeviceGestureSettings? settings,
) {
  switch (kind) {
    case PointerDeviceKind.mouse:
      // 与 super_drag 的文件拖曳保持一致（4px）。继续上调会让「拖动还要按一下」更明显，
      // 继续下调又容易把点击中的微抖当成拖动，导致单击不进目录。
      return 4;
    default:
      return computeHitSlop(kind, settings);
  }
}

/// 文件夹立即拖动的 per-pointer 状态：与 super_drag 的文件拖动一致，
/// 在累计位移超过 [_folderDragSlop] 后接受手势；之前的微小抖动让 Tap 仍可获胜并完成「单击进入目录」。
class _SftpFolderImmediatePointerState extends MultiDragPointerState {
  _SftpFolderImmediatePointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
  );

  @override
  void checkForResolutionAfterMove() {
    assert(pendingDelta != null);
    if (pendingDelta!.distance > _folderDragSlop(kind, gestureSettings)) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
  }
}

Future<DragConfiguration?> _sftpDragConfigurationForFolderHost(
  BuildContext context,
  Offset location,
  DragSession session,
) async {
  final host = _SftpFolderDragHostScope.maybeOf(context);
  if (host == null) return null;
  final allowedOperations =
      List<DropOperation>.from(await host.getAllowedOperations());
  if (allowedOperations.isEmpty) return null;
  final dragItem = await host.createItem(location, session);
  if (dragItem == null) return null;
  return DragConfiguration(
    items: [dragItem],
    allowedOperations: allowedOperations,
  );
}

class _SftpFolderImmediateMultiDragGestureRecognizer
    extends ImmediateMultiDragGestureRecognizer {
  _SftpFolderImmediateMultiDragGestureRecognizer({
    required this.isLocationDraggable,
  });

  final LocationIsDraggable isLocationDraggable;
  int? lastPointer;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _SftpFolderImmediatePointerState(
      event.position,
      event.kind,
      gestureSettings,
    );
  }

  @override
  void acceptGesture(int pointer) {
    lastPointer = pointer;
    super.acceptGesture(pointer);
  }

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryMouseButton) {
      return false;
    }
    if (!isLocationDraggable(event.position)) {
      return false;
    }
    return super.isPointerAllowed(event);
  }
}

class _SftpFolderDesktopDragDetector extends StatelessWidget {
  const _SftpFolderDesktopDragDetector({
    required this.dragConfiguration,
    required this.isLocationDraggable,
    required this.hitTestBehavior,
    required this.child,
  });

  final DragConfigurationProvider dragConfiguration;
  final LocationIsDraggable isLocationDraggable;
  final HitTestBehavior hitTestBehavior;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    return RawGestureDetector(
      behavior: hitTestBehavior,
      gestures: <Type, GestureRecognizerFactory>{
        _SftpFolderImmediateMultiDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
                _SftpFolderImmediateMultiDragGestureRecognizer>(
          () => _SftpFolderImmediateMultiDragGestureRecognizer(
            isLocationDraggable: isLocationDraggable,
          ),
          (_SftpFolderImmediateMultiDragGestureRecognizer recognizer) {
            recognizer.onStart = (offset) => _sftpMaybeStartDrag(
                  context,
                  recognizer.lastPointer,
                  offset,
                  devicePixelRatio,
                  dragConfiguration,
                );
          },
        ),
      },
      child: child,
    );
  }
}

/// 桌面端文件夹行的立即拖动手势包装（移动约 4px 后启动拖动；不会拦截单击事件）。
class SftpFolderDelayedDraggable extends StatelessWidget {
  const SftpFolderDelayedDraggable({
    super.key,
    required this.child,
    this.hitTestBehavior = HitTestBehavior.deferToChild,
    this.isLocationDraggable = _defaultIsLocationDraggable,
  });

  final Widget child;
  final HitTestBehavior hitTestBehavior;
  final LocationIsDraggable isLocationDraggable;

  static bool _defaultIsLocationDraggable(Offset position) => true;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        return _SftpFolderDesktopDragDetector(
          hitTestBehavior: hitTestBehavior,
          dragConfiguration: (location, session) =>
              _sftpDragConfigurationForFolderHost(context, location, session),
          isLocationDraggable: isLocationDraggable,
          child: child,
        );
      },
    );
  }
}
