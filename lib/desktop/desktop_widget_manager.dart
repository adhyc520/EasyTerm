import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/terminal_session_controller.dart';
import '../services/remote_exec_capable.dart';
import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';
import 'desktop_widgets/clock_widget.dart';
import 'desktop_widgets/desktop_widget.dart';
import 'desktop_widgets/monitor_widget.dart';
import 'desktop_widgets/quick_actions_widget.dart';
import 'desktop_widgets/sticky_note_widget.dart';
import 'desktop_window_manager.dart';

class PlacedDesktopWidget {
  PlacedDesktopWidget({
    required this.instanceId,
    required this.kindId,
    required this.config,
  });

  final String instanceId;
  final String kindId;
  DesktopWidgetConfig config;

  Map<String, Object?> toJson() => {
        'instanceId': instanceId,
        'kindId': kindId,
        ...config.toJson(),
      };

  factory PlacedDesktopWidget.fromJson(Map<String, Object?> j) {
    return PlacedDesktopWidget(
      instanceId: j['instanceId'] as String? ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      kindId: j['kindId'] as String? ?? 'clock',
      config: DesktopWidgetConfig.fromJson(j),
    );
  }
}

/// 桌面小部件管理：放置 / 拖拽 / 持久化。
class DesktopWidgetManager extends ChangeNotifier {
  DesktopWidgetManager({
    required this.wm,
    required this.controller,
  });

  final DesktopWindowManager wm;
  final TerminalSessionController controller;

  static const _prefsKey = 'desktop_widgets.v1';

  final List<PlacedDesktopWidget> _items = [];
  bool _loaded = false;
  bool showWidgets = true;

  late final List<DesktopWidgetKind> catalog = [
    ClockDesktopWidget(),
    MonitorDesktopWidget(controller),
    QuickActionsDesktopWidget(wm),
    StickyNoteDesktopWidget(),
  ];

  List<PlacedDesktopWidget> get items => List.unmodifiable(_items);

  DesktopWidgetKind? kindById(String id) {
    for (final k in catalog) {
      if (k.id == id) return k;
    }
    return null;
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    _items.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final e in list) {
          if (e is Map) {
            _items.add(PlacedDesktopWidget.fromJson(Map<String, Object?>.from(e)));
          }
        }
      } catch (e, st) {
        debugPrint('DesktopWidgetManager load: $e\n$st');
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> add(String kindId) async {
    final kind = kindById(kindId);
    if (kind == null) return;
    final cfg = kind.defaultConfig();
    // 轻微错开避免叠在同一位置
    cfg.position += Offset(_items.length * 16.0, _items.length * 12.0);
    _items.add(
      PlacedDesktopWidget(
        instanceId: DateTime.now().millisecondsSinceEpoch.toString(),
        kindId: kindId,
        config: cfg,
      ),
    );
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String instanceId) async {
    _items.removeWhere((e) => e.instanceId == instanceId);
    await _persist();
    notifyListeners();
  }

  Future<void> updatePosition(String instanceId, Offset pos) async {
    final i = _items.indexWhere((e) => e.instanceId == instanceId);
    if (i < 0) return;
    _items[i].config.position = pos;
    await _persist();
    notifyListeners();
  }

  void setShowWidgets(bool v) {
    if (showWidgets == v) return;
    showWidgets = v;
    notifyListeners();
  }
}

/// 渲染所有桌面小部件（壁纸之上、窗口之下）。
class DesktopWidgetsLayer extends StatefulWidget {
  const DesktopWidgetsLayer({super.key, required this.manager});

  final DesktopWidgetManager manager;

  @override
  State<DesktopWidgetsLayer> createState() => _DesktopWidgetsLayerState();
}

class _DesktopWidgetsLayerState extends State<DesktopWidgetsLayer> {
  @override
  void initState() {
    super.initState();
    widget.manager.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.manager,
      builder: (context, _) {
        if (!widget.manager.showWidgets) {
          return const SizedBox.shrink();
        }
        final wb = context.wb;
        return Stack(
          children: [
            for (final item in widget.manager.items)
              if (item.config.visible)
                Positioned(
                  left: item.config.position.dx,
                  top: item.config.position.dy,
                  width: item.config.size.width,
                  height: item.config.size.height,
                  child: _DraggableWidgetShell(
                    wb: wb,
                    title: widget.manager.kindById(item.kindId)?.name ?? '',
                    onRemove: () => widget.manager.remove(item.instanceId),
                    onDragEnd: (delta) {
                      final next = item.config.position + delta;
                      widget.manager.updatePosition(
                        item.instanceId,
                        Offset(
                          next.dx.clamp(0, 4000),
                          next.dy.clamp(0, 4000),
                        ),
                      );
                    },
                    child: widget.manager
                            .kindById(item.kindId)
                            ?.build(context, item.config) ??
                        const SizedBox.shrink(),
                  ),
                ),
          ],
        );
      },
    );
  }
}

class _DraggableWidgetShell extends StatefulWidget {
  const _DraggableWidgetShell({
    required this.wb,
    required this.title,
    required this.child,
    required this.onRemove,
    required this.onDragEnd,
  });

  final WorkbenchColors wb;
  final String title;
  final Widget child;
  final VoidCallback onRemove;
  final void Function(Offset delta) onDragEnd;

  @override
  State<_DraggableWidgetShell> createState() => _DraggableWidgetShellState();
}

class _DraggableWidgetShellState extends State<_DraggableWidgetShell> {
  Offset _drag = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: _drag,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() => _drag += d.delta),
        onPanEnd: (_) {
          widget.onDragEnd(_drag);
          setState(() => _drag = Offset.zero);
        },
        onSecondaryTapDown: (d) async {
          final selected = await showMenu<String>(
            context: context,
            position: RelativeRect.fromLTRB(
              d.globalPosition.dx,
              d.globalPosition.dy,
              d.globalPosition.dx,
              d.globalPosition.dy,
            ),
            items: const [
              PopupMenuItem(value: 'remove', child: Text('删除小部件')),
            ],
          );
          if (selected == 'remove') widget.onRemove();
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.wb.panel.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: widget.wb.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                child: Text(
                  widget.title,
                  style: TextStyle(
                    color: widget.wb.textMuted,
                    fontSize: 11,
                  ),
                ),
              ),
              Expanded(child: widget.child),
            ],
          ),
        ),
      ),
    );
  }
}
