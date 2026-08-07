import 'package:flutter/material.dart';

import '../theme/workbench_theme.dart';

/// Tab 条模型：browser / editor 共用。
abstract class DesktopTabModel {
  String get title;
  bool get dirty;
  bool get pinned => false;

  /// Stable identity for [ReorderableListView] / scroll-into-view (never list index).
  Object get tabKey;
}

typedef DesktopTabLabelBuilder<T> = Widget Function(BuildContext context, T tab);
typedef DesktopTabIconBuilder<T> = Widget? Function(BuildContext context, T tab);

/// 横向可重排 tab 条：关闭命中区 ≥28×28，活动 tab 滚入视口。
class DesktopTabStrip<T extends DesktopTabModel> extends StatefulWidget {
  const DesktopTabStrip({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onSelect,
    required this.onClose,
    this.onReorder,
    this.onContextMenu,
    this.maxTabs = 8,
    this.buildLabel,
    this.buildIcon,
  });

  final List<T> tabs;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final void Function(int oldIndex, int newIndex)? onReorder;
  final void Function(int index, Offset globalPosition)? onContextMenu;
  final int maxTabs;
  final DesktopTabLabelBuilder<T>? buildLabel;
  final DesktopTabIconBuilder<T>? buildIcon;

  @override
  State<DesktopTabStrip<T>> createState() => _DesktopTabStripState<T>();
}

class _DesktopTabStripState<T extends DesktopTabModel>
    extends State<DesktopTabStrip<T>> {
  final _scroll = ScrollController();
  final Map<Object, GlobalKey> _keys = {};

  @override
  void didUpdateWidget(covariant DesktopTabStrip<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pruneKeys();
    if (oldWidget.activeIndex != widget.activeIndex ||
        oldWidget.tabs.length != widget.tabs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureVisible());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _pruneKeys() {
    final live = widget.tabs.map((t) => t.tabKey).toSet();
    _keys.removeWhere((k, _) => !live.contains(k));
  }

  GlobalKey _keyFor(Object tabKey) => _keys.putIfAbsent(tabKey, GlobalKey.new);

  void _ensureVisible() {
    final i = widget.activeIndex;
    if (i < 0 || i >= widget.tabs.length) return;
    final ctx = _keyFor(widget.tabs[i].tabKey).currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final tabs = widget.tabs;
    final count = tabs.length;
    final strip = widget.onReorder == null
        ? ListView.builder(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            itemCount: count,
            itemBuilder: (context, i) => _buildTab(context, i, wb),
          )
        : ReorderableListView.builder(
            scrollController: _scroll,
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            itemCount: count,
            onReorder: (oldIndex, newIndex) {
              var ni = newIndex;
              if (ni > oldIndex) ni -= 1;
              widget.onReorder!(oldIndex, ni);
            },
            itemBuilder: (context, i) => KeyedSubtree(
              key: ValueKey(tabs[i].tabKey),
              child: ReorderableDragStartListener(
                index: i,
                child: _buildTab(context, i, wb),
              ),
            ),
          );

    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(child: strip),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              '$count/${widget.maxTabs}',
              style: TextStyle(fontSize: 11, color: wb.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTab(BuildContext context, int i, WorkbenchColors wb) {
    final tab = widget.tabs[i];
    final active = i == widget.activeIndex;
    final icon = widget.buildIcon?.call(context, tab);
    final label = widget.buildLabel?.call(context, tab) ??
        Text(
          tab.dirty ? '● ${tab.title}' : tab.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: active ? wb.primaryText : wb.secondaryText,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        );

    return GestureDetector(
      key: _keyFor(tab.tabKey),
      onSecondaryTapUp: widget.onContextMenu == null
          ? null
          : (d) => widget.onContextMenu!(i, d.globalPosition),
      child: InkWell(
        onTap: () => widget.onSelect(i),
        child: Container(
          constraints: const BoxConstraints(minWidth: 88, maxWidth: 180),
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
          padding: const EdgeInsets.only(left: 10, right: 2),
          decoration: BoxDecoration(
            color: active
                ? wb.panelElevated
                : wb.panel.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? wb.accentBlue.withValues(alpha: 0.45) : wb.border,
            ),
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                icon,
                const SizedBox(width: 6),
              ],
              Expanded(child: label),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  tooltip: '关闭',
                  onPressed: () => widget.onClose(i),
                  icon: Icon(
                    Icons.close,
                    size: 16,
                    color: wb.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
