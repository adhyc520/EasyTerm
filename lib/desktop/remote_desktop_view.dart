import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ssh_workspace_controller.dart';
import '../services/workbench_desktop_shortcuts.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';
import 'apps/browser_app.dart';
import 'apps/editor_app.dart';
import 'apps/file_manager_app.dart';
import 'apps/monitor_app.dart';
import 'apps/task_manager_app.dart';
import 'apps/terminal_app.dart';
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

  DesktopWindowManager get wm => widget.wm;
  SshWorkspaceController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onController);
    wm.addListener(_onWm);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void didUpdateWidget(covariant RemoteDesktopView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
    if (!identical(oldWidget.wm, widget.wm)) {
      oldWidget.wm.removeListener(_onWm);
      widget.wm.addListener(_onWm);
      _bootstrapped = false;
      _openedDefaultTerminal = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
    }
  }

  @override
  void dispose() {
    controller.removeListener(_onController);
    wm.removeListener(_onWm);
    super.dispose();
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  void _onWm() {
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    if (!mounted || _bootstrapped) return;
    if (wm.desktopSize == Size.zero) return;
    _bootstrapped = true;
    if (!wm.layoutRestored) {
      await wm.restoreLayout();
    }
    if (!mounted) return;
    if (!_openedDefaultTerminal && wm.windows.isEmpty) {
      _openedDefaultTerminal = true;
      // 首个终端复用主 shell，保留断线缓冲
      wm.openTerminal(preferPrimary: true);
    }
  }

  Widget _buildContent(DesktopWindow window) {
    switch (window.type) {
      case DesktopAppType.terminal:
        return TerminalApp(
          key: ValueKey('term-${window.id}'),
          window: window,
          wm: wm,
          controller: controller,
          settings: widget.settings,
        );
      case DesktopAppType.files:
        return FileManagerApp(
          key: ValueKey('files-${window.id}'),
          window: window,
          wm: wm,
          controller: controller,
        );
      case DesktopAppType.browser:
        return BrowserApp(
          key: ValueKey('browser-${window.id}'),
          window: window,
          wm: wm,
          controller: controller,
        );
      case DesktopAppType.monitor:
        return MonitorApp(
          key: ValueKey('mon-${window.id}'),
          window: window,
          wm: wm,
          controller: controller,
        );
      case DesktopAppType.tasks:
        return TaskManagerApp(
          key: ValueKey('tasks-${window.id}'),
          window: window,
          wm: wm,
          controller: controller,
        );
      case DesktopAppType.editor:
        return EditorApp(
          key: ValueKey('edit-${window.id}'),
          window: window,
          wm: wm,
          controller: controller,
        );
    }
  }

  Widget _positionedWindow(DesktopWindow w) {
    final r = w.displayRect(wm.desktopSize, DesktopWindowManager.taskbarH);
    return Positioned(
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      child: DesktopWindowFrame(
        key: ValueKey(w.id),
        window: w,
        wm: wm,
        child: _buildContent(w),
      ),
    );
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

        final visible = wm.windows
            .where((w) => w.state != WindowState.minimized)
            .toList()
          ..sort((a, b) => a.z.compareTo(b.z));

        return CallbackShortcuts(
          bindings: {
            ...workbenchBindActivators(
              workbenchMetaOrControl(LogicalKeyboardKey.keyW),
              () {
                final id = wm.focusedWindow?.id;
                if (id != null) wm.close(id);
              },
            ),
            ...workbenchBindActivators(
              workbenchMetaOrControl(LogicalKeyboardKey.keyM),
              () {
                final id = wm.focusedWindow?.id;
                if (id != null) wm.minimize(id);
              },
            ),
          },
          child: Focus(
            autofocus: true,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 背景 + 桌面快捷方式
                Positioned.fill(
                  child: _DesktopBackground(
                    onOpenApp: (type) {
                      if (type == DesktopAppType.terminal) {
                        wm.openTerminal();
                      } else {
                        wm.open(type);
                      }
                    },
                  ),
                ),
                // 窗口层
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  bottom: DesktopWindowManager.taskbarH,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (final w in visible) _positionedWindow(w),
                    ],
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
                                    controller.connecting
                                        ? '正在重连…'
                                        : '连接已断开',
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
          ),
        );
      },
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
    (DesktopAppType.editor, Icons.edit_note_rounded, '编辑器'),
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

class _DesktopShortcutIcon extends StatefulWidget {
  const _DesktopShortcutIcon({
    required this.icon,
    required this.label,
    required this.onOpen,
  });

  final IconData icon;
  final String label;
  final VoidCallback onOpen;

  @override
  State<_DesktopShortcutIcon> createState() => _DesktopShortcutIconState();
}

class _DesktopShortcutIconState extends State<_DesktopShortcutIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onDoubleTap: widget.onOpen,
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 76,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: _hover
                ? wb.accentBlue.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hover
                  ? wb.accentBlue.withValues(alpha: 0.35)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 32, color: wb.primaryText),
              const SizedBox(height: 6),
              Text(
                widget.label,
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
