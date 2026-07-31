import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/session_pane.dart';
import '../services/session_tabs_controller.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';
import 'session_workspace.dart';

/// 渲染标签内的分屏树：左右 / 上下可拖拽，点击聚焦窗格。
class SessionPaneLayout extends StatelessWidget {
  const SessionPaneLayout({
    super.key,
    required this.tabs,
    required this.tab,
    required this.tabIndex,
    required this.workbenchSettings,
    this.pickingSnippetTarget = false,
    this.onPickSnippetTarget,
  });

  final SessionTabsController tabs;
  final SessionTab tab;
  final int tabIndex;
  final WorkbenchSettingsStore workbenchSettings;

  /// 代码块多终端选择：点击已连接窗格作为运行目标。
  final bool pickingSnippetTarget;
  final ValueChanged<int>? onPickSnippetTarget;

  @override
  Widget build(BuildContext context) {
    return _PaneNodeView(
      tabs: tabs,
      tab: tab,
      tabIndex: tabIndex,
      node: tab.root,
      workbenchSettings: workbenchSettings,
      showChrome: tab.hasSplit,
      pickingSnippetTarget: pickingSnippetTarget,
      onPickSnippetTarget: onPickSnippetTarget,
    );
  }
}

class _PaneNodeView extends StatelessWidget {
  const _PaneNodeView({
    required this.tabs,
    required this.tab,
    required this.tabIndex,
    required this.node,
    required this.workbenchSettings,
    required this.showChrome,
    required this.pickingSnippetTarget,
    required this.onPickSnippetTarget,
  });

  final SessionTabsController tabs;
  final SessionTab tab;
  final int tabIndex;
  final SessionPaneNode node;
  final WorkbenchSettingsStore workbenchSettings;
  final bool showChrome;
  final bool pickingSnippetTarget;
  final ValueChanged<int>? onPickSnippetTarget;

  @override
  Widget build(BuildContext context) {
    return switch (node) {
      SessionPaneLeaf(:final paneId, :final controller) => _PaneLeafFrame(
        tabs: tabs,
        tab: tab,
        tabIndex: tabIndex,
        paneId: paneId,
        controller: controller,
        workbenchSettings: workbenchSettings,
        showChrome: showChrome,
        pickingSnippetTarget: pickingSnippetTarget,
        onPickSnippetTarget: onPickSnippetTarget,
      ),
      final SessionPaneSplit split => _PaneSplitView(
        tabs: tabs,
        tab: tab,
        tabIndex: tabIndex,
        split: split,
        workbenchSettings: workbenchSettings,
        showChrome: showChrome,
        pickingSnippetTarget: pickingSnippetTarget,
        onPickSnippetTarget: onPickSnippetTarget,
      ),
    };
  }
}

class _PaneSplitView extends StatelessWidget {
  const _PaneSplitView({
    required this.tabs,
    required this.tab,
    required this.tabIndex,
    required this.split,
    required this.workbenchSettings,
    required this.showChrome,
    required this.pickingSnippetTarget,
    required this.onPickSnippetTarget,
  });

  final SessionTabsController tabs;
  final SessionTab tab;
  final int tabIndex;
  final SessionPaneSplit split;
  final WorkbenchSettingsStore workbenchSettings;
  final bool showChrome;
  final bool pickingSnippetTarget;
  final ValueChanged<int>? onPickSnippetTarget;

  static const double _splitter = 5;

  @override
  Widget build(BuildContext context) {
    final horizontal = split.axis == SessionPaneAxis.horizontal;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = horizontal ? constraints.maxWidth : constraints.maxHeight;
        final firstExtent = ((total - _splitter) * split.ratio).clamp(
          80.0,
          (total - _splitter - 80).clamp(80.0, double.infinity),
        );

        Widget childA = _PaneNodeView(
          tabs: tabs,
          tab: tab,
          tabIndex: tabIndex,
          node: split.first,
          workbenchSettings: workbenchSettings,
          showChrome: showChrome,
          pickingSnippetTarget: pickingSnippetTarget,
          onPickSnippetTarget: onPickSnippetTarget,
        );
        Widget childB = _PaneNodeView(
          tabs: tabs,
          tab: tab,
          tabIndex: tabIndex,
          node: split.second,
          workbenchSettings: workbenchSettings,
          showChrome: showChrome,
          pickingSnippetTarget: pickingSnippetTarget,
          onPickSnippetTarget: onPickSnippetTarget,
        );

        final splitter = MouseRegion(
          cursor: horizontal
              ? SystemMouseCursors.resizeColumn
              : SystemMouseCursors.resizeRow,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: horizontal
                ? (d) {
                    final next =
                        (split.ratio + d.delta.dx / (total - _splitter)).clamp(
                          0.15,
                          0.85,
                        );
                    tabs.setSplitRatio(split, next);
                  }
                : null,
            onVerticalDragUpdate: horizontal
                ? null
                : (d) {
                    final next =
                        (split.ratio + d.delta.dy / (total - _splitter)).clamp(
                          0.15,
                          0.85,
                        );
                    tabs.setSplitRatio(split, next);
                  },
            child: Container(
              width: horizontal ? _splitter : null,
              height: horizontal ? null : _splitter,
              color: context.wb.border,
            ),
          ),
        );

        if (horizontal) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: firstExtent, child: childA),
              splitter,
              Expanded(child: childB),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: firstExtent, child: childA),
            splitter,
            Expanded(child: childB),
          ],
        );
      },
    );
  }
}

class _PaneLeafFrame extends StatelessWidget {
  const _PaneLeafFrame({
    required this.tabs,
    required this.tab,
    required this.tabIndex,
    required this.paneId,
    required this.controller,
    required this.workbenchSettings,
    required this.showChrome,
    required this.pickingSnippetTarget,
    required this.onPickSnippetTarget,
  });

  final SessionTabsController tabs;
  final SessionTab tab;
  final int tabIndex;
  final int paneId;
  final SshWorkspaceController controller;
  final WorkbenchSettingsStore workbenchSettings;
  final bool showChrome;
  final bool pickingSnippetTarget;
  final ValueChanged<int>? onPickSnippetTarget;

  @override
  Widget build(BuildContext context) {
    final focused = tab.focusedPaneId == paneId;
    final l10n = AppLocalizations.of(context)!;
    final canPick = pickingSnippetTarget && controller.connected;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (pickingSnippetTarget) {
          if (canPick) onPickSnippetTarget?.call(paneId);
          return;
        }
        tabs.focusPane(tabIndex, paneId);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: showChrome || pickingSnippetTarget
              ? Border.all(
                  color: pickingSnippetTarget
                      ? (canPick
                            ? context.wb.accentBlue
                            : context.wb.border.withValues(alpha: 0.35))
                      : focused
                      ? context.wb.accentBlue
                      : context.wb.border.withValues(alpha: 0.6),
                  width: (focused || canPick) ? 1.5 : 1,
                )
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showChrome)
              Material(
                color: focused
                    ? context.wb.accentBlue.withValues(alpha: 0.12)
                    : context.wb.panelElevated,
                child: SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      Icon(
                        Icons.terminal_rounded,
                        size: 14,
                        color: focused
                            ? context.wb.accentBlue
                            : context.wb.textMuted,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${controller.username}@${controller.host}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: focused
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: focused
                                ? context.wb.primaryText
                                : context.wb.secondaryText,
                          ),
                        ),
                      ),
                      if (!pickingSnippetTarget) ...[
                        PopupMenuButton<String>(
                          tooltip: l10n.paneMenuTooltip,
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          icon: Icon(
                            Icons.more_horiz_rounded,
                            size: 16,
                            color: context.wb.textMuted,
                          ),
                          onSelected: (v) => _onPaneMenu(v),
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'splitRight',
                              child: Text(l10n.paneSplitRight),
                            ),
                            PopupMenuItem(
                              value: 'splitLeft',
                              child: Text(l10n.paneSplitLeft),
                            ),
                            PopupMenuItem(
                              value: 'splitDown',
                              child: Text(l10n.paneSplitDown),
                            ),
                            PopupMenuItem(
                              value: 'splitUp',
                              child: Text(l10n.paneSplitUp),
                            ),
                            const PopupMenuDivider(),
                            PopupMenuItem(
                              value: 'close',
                              child: Text(l10n.paneClose),
                            ),
                          ],
                        ),
                        IconButton(
                          tooltip: l10n.paneClose,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => tabs.closePane(tabIndex, paneId),
                          icon: Icon(
                            Icons.close_rounded,
                            size: 14,
                            color: context.wb.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SessionWorkspace(
                    key: ValueKey<Object>('pane-$paneId'),
                    controller: controller,
                    workbenchSettings: workbenchSettings,
                    autofocusTerminal: focused && !pickingSnippetTarget,
                  ),
                  if (pickingSnippetTarget)
                    Positioned.fill(
                      child: Material(
                        color: canPick
                            ? context.wb.accentBlue.withValues(alpha: 0.18)
                            : Colors.black.withValues(alpha: 0.45),
                        child: InkWell(
                          onTap: canPick
                              ? () => onPickSnippetTarget?.call(paneId)
                              : null,
                          child: Center(
                            child: canPick
                                ? DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: context.wb.panel.withValues(
                                        alpha: 0.92,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: context.wb.accentBlue,
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.play_arrow_rounded,
                                            color: context.wb.accentBlue,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            l10n.codeSnippetClickToRun,
                                            style: TextStyle(
                                              color: context.wb.primaryText,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onPaneMenu(String value) {
    tabs.focusPane(tabIndex, paneId);
    switch (value) {
      case 'splitRight':
        tabs.splitPane(
          tabIndex: tabIndex,
          targetPaneId: paneId,
          axis: SessionPaneAxis.horizontal,
          placement: SessionSplitPlacement.after,
        );
      case 'splitLeft':
        tabs.splitPane(
          tabIndex: tabIndex,
          targetPaneId: paneId,
          axis: SessionPaneAxis.horizontal,
          placement: SessionSplitPlacement.before,
        );
      case 'splitDown':
        tabs.splitPane(
          tabIndex: tabIndex,
          targetPaneId: paneId,
          axis: SessionPaneAxis.vertical,
          placement: SessionSplitPlacement.after,
        );
      case 'splitUp':
        tabs.splitPane(
          tabIndex: tabIndex,
          targetPaneId: paneId,
          axis: SessionPaneAxis.vertical,
          placement: SessionSplitPlacement.before,
        );
      case 'close':
        tabs.closePane(tabIndex, paneId);
    }
  }
}
