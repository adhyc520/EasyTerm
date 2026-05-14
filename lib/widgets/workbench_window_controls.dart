import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Whether this target uses a frameless shell with custom caption controls.
bool workbenchUsesCustomWindowChrome() =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// Placement of [WorkbenchWindowControls] to match each OS convention.
enum WorkbenchWindowControlsSide {
  /// Close, minimize, maximize on the leading edge (macOS traffic-light order).
  leadingMac,

  /// Minimize, maximize, close on the trailing edge (Windows order).
  trailingWindows,
}

/// Min / max / close drawn with [WindowCaptionButton] (Chrome-style icons).
class WorkbenchWindowControls extends StatefulWidget {
  const WorkbenchWindowControls({
    super.key,
    required this.side,
    this.brightness = Brightness.dark,
  });

  final WorkbenchWindowControlsSide side;
  final Brightness brightness;

  @override
  State<WorkbenchWindowControls> createState() => _WorkbenchWindowControlsState();
}

class _WorkbenchWindowControlsState extends State<WorkbenchWindowControls> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_syncMaximized());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    final v = await windowManager.isMaximized();
    if (mounted) setState(() => _maximized = v);
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  void onWindowRestore() => unawaited(_syncMaximized());

  @override
  Widget build(BuildContext context) {
    final b = widget.brightness;

    final minBtn = WindowCaptionButton.minimize(
      brightness: b,
      onPressed: () => windowManager.minimize(),
    );

    final maxBtn = _maximized
        ? WindowCaptionButton.unmaximize(
            brightness: b,
            onPressed: () => windowManager.unmaximize(),
          )
        : WindowCaptionButton.maximize(
            brightness: b,
            onPressed: () => windowManager.maximize(),
          );

    final closeBtn = WindowCaptionButton.close(
      brightness: b,
      onPressed: () => windowManager.close(),
    );

    final List<Widget> children;
    switch (widget.side) {
      case WorkbenchWindowControlsSide.leadingMac:
        children = [closeBtn, minBtn, maxBtn];
        break;
      case WorkbenchWindowControlsSide.trailingWindows:
        children = [minBtn, maxBtn, closeBtn];
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}
