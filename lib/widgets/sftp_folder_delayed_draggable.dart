// ignore_for_file: implementation_imports
//
// 桌面端文件夹拖出使用 [DelayedMultiDragGestureRecognizer]：先按住约 [holdDuration]
// 且几乎不移动，再拖动即可拖出。通过 raw.DragContext 手动控制原生拖放会话，
// 确保拖放数据（目录下载到临时路径）准备好后才启动原生拖放，避免阻塞。
//
// 注意：不包裹 BaseDraggableRenderWidget，否则 macOS 上原生拖动事件会绕过延迟手势
// 直接触发 getDragConfiguration，导致长时间阻塞在目录下载中。

import 'dart:async' show unawaited;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:super_drag_and_drop/src/into_raw.dart';
import 'package:super_native_extensions/raw_drag_drop.dart' as raw;

/// 默认：按住约半秒不移动后再拖，避免与单击进入目录冲突。
const Duration kSftpFolderDragHoldDuration = Duration(milliseconds: 550);

/// 目录拖出准备（下载到临时目录）期间用于中止传输；由 [_sftpMaybeStartDrag] 设置。
bool Function()? sftpFolderDragPreparationShouldAbort;

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
  final configuration = await dragConfiguration(position, session);
  if (drag.ended) {
    dragContext.cancelSession(session);
    return;
  }
  if (configuration != null) {
    final rawConfiguration = await configuration.intoRaw(devicePixelRatio);
    if (buildContext.mounted) {
      session.dragCompleted.addListener(() {
        rawConfiguration.disposeImages();
      });
      await dragContext.startDrag(
        buildContext: buildContext,
        session: session,
        configuration: rawConfiguration,
        position: position,
      );
    } else {
      rawConfiguration.disposeImages();
    }
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
    sftpFolderDragPreparationShouldAbort = () => drag.ended;
    try {
      final dragContext = await raw.DragContext.instance();
      if (!buildContext.mounted) return;
      final session = dragContext.newSession(pointer: pointer);
      if (pointer != null) {
        Future<void>.delayed(const Duration(milliseconds: 50), () {
          if (session.dragging.value) {
            final event = PointerRemovedEvent(
              pointer: pointer,
              kind: PointerDeviceKind.mouse,
            );
            RendererBinding.instance.mouseTracker.updateWithEvent(
              event,
              HitTestResult(),
            );
          }
        });
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
      sftpFolderDragPreparationShouldAbort = null;
    }
  }());
  return drag;
}

Future<DragConfiguration?> _sftpDragConfigurationForSingleAncestorItem(
  BuildContext context,
  Offset location,
  DragSession session,
) async {
  final state = context.findAncestorStateOfType<DragItemWidgetState>();
  if (state == null) return null;
  final allowedOperations = List<DropOperation>.from(await state.getAllowedOperations());
  if (allowedOperations.isEmpty) return null;
  final dragItem = await state.createItem(location, session);
  if (dragItem == null) return null;
  return DragConfiguration(
    items: [dragItem],
    allowedOperations: allowedOperations,
  );
}

class _SftpDelayedMultiDragGestureRecognizer extends DelayedMultiDragGestureRecognizer {
  _SftpDelayedMultiDragGestureRecognizer({
    required super.delay,
    required this.isLocationDraggable,
  });

  final LocationIsDraggable isLocationDraggable;
  int? lastPointer;

  @override
  void acceptGesture(int pointer) {
    lastPointer = pointer;
    super.acceptGesture(pointer);
  }

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse && event.buttons != kPrimaryMouseButton) {
      return false;
    }
    if (!isLocationDraggable(event.position)) {
      return false;
    }
    return super.isPointerAllowed(event);
  }
}

class _SftpDelayedDesktopDragDetector extends StatelessWidget {
  const _SftpDelayedDesktopDragDetector({
    required this.dragConfiguration,
    required this.isLocationDraggable,
    required this.hitTestBehavior,
    required this.holdDuration,
    required this.child,
  });

  final DragConfigurationProvider dragConfiguration;
  final LocationIsDraggable isLocationDraggable;
  final HitTestBehavior hitTestBehavior;
  final Duration holdDuration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    return RawGestureDetector(
      behavior: hitTestBehavior,
      gestures: <Type, GestureRecognizerFactory>{
        _SftpDelayedMultiDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<_SftpDelayedMultiDragGestureRecognizer>(
          () => _SftpDelayedMultiDragGestureRecognizer(
            delay: holdDuration,
            isLocationDraggable: isLocationDraggable,
          ),
          (_SftpDelayedMultiDragGestureRecognizer recognizer) {
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

/// 与 [DraggableWidget] 类似，但桌面指针使用长按静止后再拖动手势，便于目录行同时支持单击进入。
class SftpFolderDelayedDraggable extends StatelessWidget {
  const SftpFolderDelayedDraggable({
    super.key,
    required this.child,
    this.holdDuration = kSftpFolderDragHoldDuration,
    this.hitTestBehavior = HitTestBehavior.deferToChild,
    this.isLocationDraggable = _defaultIsLocationDraggable,
  });

  final Widget child;
  final Duration holdDuration;
  final HitTestBehavior hitTestBehavior;
  final LocationIsDraggable isLocationDraggable;

  static bool _defaultIsLocationDraggable(Offset position) => true;

  @override
  Widget build(BuildContext context) {
    // 不使用 BaseDraggableRenderWidget：它会在 macOS 上拦截原生拖动事件并立即
    // 调用 getDragConfiguration，绕过延迟手势；对于目录拖出（需要先下载到临时目录），
    // 必须由 _SftpDelayedDesktopDragDetector 手动控制 raw.DragContext 生命周期。
    return Builder(
      builder: (context) {
        return _SftpDelayedDesktopDragDetector(
          hitTestBehavior: hitTestBehavior,
          dragConfiguration: (location, session) =>
              _sftpDragConfigurationForSingleAncestorItem(context, location, session),
          isLocationDraggable: isLocationDraggable,
          holdDuration: holdDuration,
          child: child,
        );
      },
    );
  }
}
