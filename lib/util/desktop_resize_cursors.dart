import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 窗口缩放角光标。
///
/// macOS 的 Flutter 引擎未映射 [SystemMouseCursors.resizeUpLeftDownRight] /
/// [SystemMouseCursors.resizeUpRightDownLeft]，会静默回退为箭头；
/// 此处通过 MethodChannel 加载 HIServices 系统光标资源。
abstract final class DesktopResizeCursors {
  static MouseCursor get upLeftDownRight =>
      defaultTargetPlatform == TargetPlatform.macOS
          ? const _MacDiagonalResizeCursor._('nwse')
          : SystemMouseCursors.resizeUpLeftDownRight;

  static MouseCursor get upRightDownLeft =>
      defaultTargetPlatform == TargetPlatform.macOS
          ? const _MacDiagonalResizeCursor._('nesw')
          : SystemMouseCursors.resizeUpRightDownLeft;
}

class _MacDiagonalResizeCursor extends MouseCursor {
  const _MacDiagonalResizeCursor._(this.kind);

  /// `nwse` = ↖↘，`nesw` = ↗↙。
  final String kind;

  static const MethodChannel _channel =
      MethodChannel('easyterm/macos_resize_cursors');

  @override
  MouseCursorSession createSession(int device) =>
      _MacDiagonalResizeCursorSession(this, device);

  @override
  String get debugDescription => 'MacDiagonalResizeCursor($kind)';

  @override
  bool operator ==(Object other) =>
      other is _MacDiagonalResizeCursor && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;
}

class _MacDiagonalResizeCursorSession extends MouseCursorSession {
  _MacDiagonalResizeCursorSession(_MacDiagonalResizeCursor super.cursor, super.device);

  @override
  _MacDiagonalResizeCursor get cursor =>
      super.cursor as _MacDiagonalResizeCursor;

  @override
  Future<void> activate() async {
    try {
      await _MacDiagonalResizeCursor._channel.invokeMethod<void>(
        'activate',
        <String, dynamic>{'kind': cursor.kind},
      );
    } catch (_) {
      // Channel 未注册或失败时退回系统双向光标（至少有可见变化）。
      await SystemChannels.mouseCursor.invokeMethod<void>(
        'activateSystemCursor',
        <String, dynamic>{
          'device': device,
          'kind': 'resizeLeftRight',
        },
      );
    }
  }

  @override
  void dispose() {}
}
