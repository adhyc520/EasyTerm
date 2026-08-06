import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ssh_workspace_controller.dart';
import '../services/workbench_desktop_shortcuts.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';
import 'apps/browser_app.dart';
import 'apps/containers_app.dart';
import 'apps/disk_usage_app.dart';
import 'apps/editor_app.dart';
import 'apps/file_manager_app.dart';
import 'apps/logs_app.dart';
import 'apps/monitor_app.dart';
import 'apps/task_manager_app.dart';
import 'apps/terminal_app.dart';
import 'apps/transfers_app.dart';
import 'desktop_taskbar.dart';
import 'desktop_window_frame.dart';
import 'desktop_window_manager.dart';

/// 远程可视化桌面表面：背景 + 窗口层 + 任务栏。
class RemoteDesktopView extends StatefulWidget {
  const RemoteDesktopView({
    super.key,
    required this.wm,
    required this.controller,
    required this.settings,
  });

  final DesktopWindowManager wm;
  final SshWorkspaceController controller;
  final WorkbenchSettingsStore settings;

  @override
  State<RemoteDesktopView> createState() => _RemoteDesktopViewState();
}

class _RemoteDesktopViewState extends State<RemoteDesktopView> {
  bool _bootstrapped = false;
  bool _openedDefaultTerminal = false;
  bool? _lastConnected;
  bool? _lastDropped;
  bool? _lastConnecting;
  String? _lastError;

  DesktopWindowManager get wm => widget.wm;
  SshWorkspaceController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _syncConnectionSnapshot();
    controller.addListener(_onController);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void didUpdateWidget(covariant RemoteDesktopView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      _syncConnectionSnapshot();
    }
    if (!identical(oldWidget.wm, widget.wm)) {
      _bootstrapped = false;
      _openedDefaultTerminal = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    }
  }

  @override
  void dispose() {
    controller.removeListener(_onController);
    super.dispose();
  }

  void _syncConnectionSnapshot() {
    _lastConnected = controller.connected;
    _lastDropped = controller.dropped;
    _lastConnecting = controller.connecting;
    _lastError = controller.error;
  }

  void _onController() {
    if (!mounted) return;
    // 仅连接态变化时重建，避免 SFTP/指标通知整桌面重建抢走 WebView/输入框焦点。
    if (controller.connected == _lastConnected &&
        controller.dropped == _lastDropped &&
        controller.connecting == _lastConnecting &&
        controller.error == _lastError) {
      return;
    }
    _syncConnectionSnapshot();
    setState(() {});
  }

  Future<void> _bootstrap() async {
    if (!mounted || _bootstrapped) return;
    if (wm.desktopSize == Size.zero) return;
    _bootstrapped = true;
    if (!wm.layoutRestored) {
      await wm.prepareFreshDesktop();
    }
    if (!mounted) return;
    if (!_openedDefaultTerminal && wm.windows.isEmpty) {
      _openedDefaultTerminal = true;
      // 首个终端复用主 shell，保留断线缓冲
      wm.openTerminal(preferPrimary: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final dropped = controller.dropped || !controller.connected;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.width > 0 && size.height > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            wm.setDesktopSize(size);
            if (!_bootstrapped) {
              unawaited(_bootstrap());
            }
          });
        }

        return CallbackShortcuts(
          bindings: {
            ...workbenchBindActivators(
              workbenchMetaOrControl(LogicalKeyboardKey.keyW),
              () {
                final id = wm.focusedWindow?.id;
                if (id != null) unawaited(wm.requestClose(id));
              },
            ),
            ...workbenchBindActivators(
              workbenchMetaOrControl(LogicalKeyboardKey.keyM),
              () {
                final id = wm.focusedWindow?.id;
                if (id != null) wm.minimize(id);
              },
            ),
            ...workbenchBindActivators(
              workbenchMetaOrControl(LogicalKeyboardKey.keyN),
              () => wm.openTerminal(preferPrimary: false),
            ),
            ...workbenchBindActivators(
              workbenchMetaOrControl(LogicalKeyboardKey.backquote),
              () => wm.cycleFocus(),
            ),
            ...workbenchBindActivators(
              workbenchMetaOrControl(LogicalKeyboardKey.backquote, shift: true),
              () => wm.cycleFocus(reverse: true),
            ),
            ...workbenchBindActivators(
              workbenchMetaOrControl(LogicalKeyboardKey.arrowLeft, alt: true),
              () {
                final id = wm.focusedWindow?.id;
                if (id != null) wm.tile(id, TileZone.left);
              },
            ),
            ...workbenchBindActivators(
              workbenchMetaOrControl(LogicalKeyboardKey.arrowRight, alt: true),
              () {
                final id = wm.focusedWindow?.id;
                if (id != null) wm.tile(id, TileZone.right);
              },
            ),
            ...workbenchBindActivators(
              workbenchMetaOrControl(LogicalKeyboardKey.arrowUp, alt: true),
              () {
                final id = wm.focusedWindow?.id;
                if (id != null) {
                  final w = wm.focusedWindow;
                  if (w != null && w.state != WindowState.maximized) {
                    wm.toggleMaximize(id);
                  }
                }
              },
            ),
            ...workbenchBindActivators(
              workbenchMetaOrControl(LogicalKeyboardKey.arrowDown, alt: true),
              () {
                final w = wm.focusedWindow;
                if (w == null) return;
                if (w.state == WindowState.maximized) {
                  wm.toggleMaximize(w.id);
                } else {
                  wm.minimize(w.id);
                }
              },
            ),
          },
          // CallbackShortcuts 自带不可聚焦 Focus；勿再包一层可聚焦 Focus，
          // 否则会抢走终端硬件键盘焦点（按键进不了 xterm）。
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 背景不监听 wm：拖动/缩放时不应重建桌面图标（其内部也有鼠标 annotation）。
              Positioned.fill(
                child: _DesktopBackground(
                  onOpenApp: (type) {
                    if (type == DesktopAppType.terminal) {
                      wm.openTerminal();
                    } else if (type == DesktopAppType.editor) {
                      // 编辑器需具体路径；桌面图标改为打开文件管理器。
                      wm.open(DesktopAppType.files);
                    } else {
                      wm.open(type);
                    }
                  },
                ),
              ),
              // 窗口层：仅此层随 wm 几何/清单变化重建。
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                bottom: DesktopWindowManager.taskbarH,
                child: ListenableBuilder(
                  listenable: wm,
                  builder: (context, _) {
                    final visible = wm.windows
                        .where((w) => w.state != WindowState.minimized)
                        .toList()
                      ..sort((a, b) => a.z.compareTo(b.z));
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        if (wm.snapPreviewRect != null)
                          Positioned(
                            left: wm.snapPreviewRect!.left,
                            top: wm.snapPreviewRect!.top,
                            width: wm.snapPreviewRect!.width,
                            height: wm.snapPreviewRect!.height,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: wb.accentBlue.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color:
                                        wb.accentBlue.withValues(alpha: 0.55),
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        for (final w in visible)
                          _DesktopWindowHost(
                            key: ValueKey(w.id),
                            windowId: w.id,
                            wm: wm,
                            controller: controller,
                            settings: widget.settings,
                          ),
                      ],
                    );
                  },
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DesktopTaskbar(wm: wm),
              ),
              // 掉线浮层
              if (dropped)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.45),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: Material(
                          color: wb.panelElevated,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.cloud_off_rounded,
                                  size: 40,
                                  color: Color(0xFFEF4444),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  controller.connecting ? '正在重连…' : '连接已断开',
                                  style: TextStyle(
                                    color: wb.primaryText,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (controller.error != null &&
                                    controller.error!.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    controller.error!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: wb.textMuted,
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                                if (!controller.connecting) ...[
                                  const SizedBox(height: 16),
                                  FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: wb.accentBlue,
                                      ),
                                      onPressed: () =>
                                          unawaited(controller.reconnect()),
                                      icon: const Icon(Icons.refresh_rounded),
                                      label: const Text('重连'),
                                    ),
                                  ] else ...[
                                    const SizedBox(height: 16),
                                    CircularProgressIndicator(
                                      color: wb.accentBlue,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

/// 单个窗口宿主：几何变化只更新 [Positioned]；内容子树在实例不变时跳过重建，
/// 避免拖动/缩放时反复重建内部 InkWell/Scrollbar 的 MouseRegion。
class _DesktopWindowHost extends StatefulWidget {
  const _DesktopWindowHost({
    super.key,
    required this.windowId,
    required this.wm,
    required this.controller,
    required this.settings,
  });

  final String windowId;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;
  final WorkbenchSettingsStore settings;

  @override
  State<_DesktopWindowHost> createState() => _DesktopWindowHostState();
}

class _DesktopWindowHostState extends State<_DesktopWindowHost> {
  Widget? _content;
  DesktopAppType? _contentType;

  DesktopWindow? get _window {
    for (final w in widget.wm.windows) {
      if (w.id == widget.windowId) return w;
    }
    return null;
  }

  Widget _buildContent(DesktopWindow window) {
    switch (window.type) {
      case DesktopAppType.terminal:
        return TerminalApp(
          key: ValueKey('term-${window.id}'),
          window: window,
          wm: widget.wm,
          controller: widget.controller,
          settings: widget.settings,
        );
      case DesktopAppType.files:
        return FileManagerApp(
          key: ValueKey('files-${window.id}'),
          window: window,
          wm: widget.wm,
          controller: widget.controller,
        );
      case DesktopAppType.browser:
        return BrowserApp(
          key: ValueKey('browser-${window.id}'),
          window: window,
          wm: widget.wm,
          controller: widget.controller,
        );
      case DesktopAppType.monitor:
        return MonitorApp(
          key: ValueKey('mon-${window.id}'),
          window: window,
          wm: widget.wm,
          controller: widget.controller,
        );
      case DesktopAppType.tasks:
        return TaskManagerApp(
          key: ValueKey('tasks-${window.id}'),
          window: window,
          wm: widget.wm,
          controller: widget.controller,
        );
      case DesktopAppType.logs:
        return LogsApp(
          key: ValueKey('logs-${window.id}'),
          window: window,
          wm: widget.wm,
          controller: widget.controller,
        );
      case DesktopAppType.containers:
        return ContainersApp(
          key: ValueKey('ct-${window.id}'),
          window: window,
          wm: widget.wm,
          controller: widget.controller,
        );
      case DesktopAppType.diskUsage:
        return DiskUsageApp(
          key: ValueKey('du-${window.id}'),
          window: window,
          wm: widget.wm,
          controller: widget.controller,
        );
      case DesktopAppType.transfers:
        return TransfersApp(
          key: ValueKey('xfer-${window.id}'),
          window: window,
          wm: widget.wm,
          controller: widget.controller,
        );
      case DesktopAppType.editor:
        return EditorApp(
          key: ValueKey('edit-${window.id}'),
          window: window,
          wm: widget.wm,
          controller: widget.controller,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = _window;
    if (w == null) return const SizedBox.shrink();
    if (_content == null || _contentType != w.type) {
      _contentType = w.type;
      _content = _buildContent(w);
    }
    final r = w.displayRect(
      widget.wm.desktopSize,
      DesktopWindowManager.taskbarH,
    );
    return Positioned(
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      child: DesktopWindowFrame(
        window: w,
        wm: widget.wm,
        // 同一 content 实例 → Element 可跳过内容子树更新。
        child: _content!,
      ),
    );
  }
}

class _DesktopBackground extends StatelessWidget {
  const _DesktopBackground({required this.onOpenApp});

  final void Function(DesktopAppType type) onOpenApp;

  static const _shortcuts = <(DesktopAppType, IconData, String)>[
    (DesktopAppType.terminal, Icons.terminal_rounded, '终端'),
    (DesktopAppType.files, Icons.folder_rounded, '文件'),
    (DesktopAppType.browser, Icons.language_rounded, '浏览器'),
    (DesktopAppType.monitor, Icons.monitor_heart_rounded, '监控'),
    (DesktopAppType.tasks, Icons.memory_rounded, '任务管理器'),
    (DesktopAppType.logs, Icons.article_rounded, '日志'),
    (DesktopAppType.containers, Icons.view_in_ar_rounded, '容器'),
    (DesktopAppType.diskUsage, Icons.pie_chart_rounded, '磁盘占用'),
    (DesktopAppType.transfers, Icons.swap_vert_rounded, '传输'),
    (DesktopAppType.editor, Icons.folder_open_rounded, '打开文件'),
  ];

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            wb.bg,
            Color.lerp(wb.bg, wb.panel, 0.55)!,
            Color.lerp(wb.panel, const Color(0xFF1A2332), 0.35)!,
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: CustomPaint(
        painter: _GridPainter(color: wb.border.withValues(alpha: 0.22)),
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 64),
            child: Wrap(
              direction: Axis.vertical,
              spacing: 12,
              runSpacing: 16,
              children: [
                for (final s in _shortcuts)
                  _DesktopShortcutIcon(
                    icon: s.$2,
                    label: s.$3,
                    onOpen: () => onOpenApp(s.$1),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopShortcutIcon extends StatelessWidget {
  const _DesktopShortcutIcon({
    required this.icon,
    required this.label,
    required this.onOpen,
  });

  final IconData icon;
  final String label;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    // 不用 MouseRegion hover：桌面频繁重建时 onEnter/onExit 易触发 mouse_tracker 断言。
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        onDoubleTap: onOpen,
        borderRadius: BorderRadius.circular(10),
        hoverColor: wb.accentBlue.withValues(alpha: 0.16),
        child: SizedBox(
          width: 76,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 32, color: wb.primaryText),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: wb.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const step = 48.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.color != color;
}
