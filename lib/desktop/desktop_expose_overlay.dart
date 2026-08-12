import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/workbench_theme.dart';
import 'desktop_app_registry.dart';
import 'desktop_window_manager.dart';
import 'widgets/desktop_ui.dart';

/// Mission Control 风格窗口概览。
class DesktopExposeOverlay extends StatelessWidget {
  const DesktopExposeOverlay({
    super.key,
    required this.wm,
    required this.onClose,
  });

  final DesktopWindowManager wm;
  final VoidCallback onClose;

  static const _maxCards = 20;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final windows = wm.windows
        .where((w) => w.state != WindowState.minimized)
        .take(_maxCards)
        .toList();

    return Material(
      color: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: onClose,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.42),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 16, 8),
                  child: Row(
                    children: [
                      Text(
                        '调度中心',
                        style: TextStyle(
                          color: wb.primaryText,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const Spacer(),
                      DesktopToolIcon(
                        icon: Icons.close_rounded,
                        tooltip: '关闭',
                        onPressed: onClose,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: windows.isEmpty
                      ? Center(
                          child: Text(
                            '当前桌面没有打开的窗口',
                            style: TextStyle(
                              color: wb.textMuted,
                              fontSize: 15,
                            ),
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.fromLTRB(28, 12, 28, 12),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 280,
                            mainAxisSpacing: 20,
                            crossAxisSpacing: 20,
                            childAspectRatio: 1.4,
                          ),
                          itemCount: windows.length,
                          itemBuilder: (context, i) {
                            final w = windows[i];
                            final meta = metaFor(w.type);
                            return _ExposeCard(
                              title: w.title,
                              subtitle: meta.label,
                              icon: meta.icon,
                              focused: w.focused,
                              onTap: () {
                                wm.focus(w.id);
                                if (w.state == WindowState.minimized) {
                                  wm.restore(w.id);
                                }
                                onClose();
                              },
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: DesktopGlass(
                    opacity: 0.7,
                    borderRadius: BorderRadius.circular(18),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: ListenableBuilder(
                      listenable: wm,
                      builder: (context, _) {
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < wm.workspaces.length; i++) ...[
                              if (i > 0) const SizedBox(width: 6),
                              _SpaceChip(
                                label: '桌面 ${i + 1}',
                                selected: i == wm.activeWorkspaceIndex,
                                count: wm.workspaces[i].windows.length,
                                onTap: () => wm.switchWorkspace(i),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SpaceChip extends StatelessWidget {
  const _SpaceChip({
    required this.label,
    required this.selected,
    required this.count,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Material(
      color: selected
          ? wb.accentBlue.withValues(alpha: 0.2)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(DesktopUi.radiusPill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DesktopUi.radiusPill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? wb.accentBlue : wb.secondaryText,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    color: wb.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ExposeCard extends StatefulWidget {
  const _ExposeCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.focused,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool focused;
  final VoidCallback onTap;

  @override
  State<_ExposeCard> createState() => _ExposeCardState();
}

class _ExposeCardState extends State<_ExposeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.03 : 1.0,
          duration: DesktopUi.fast,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: DesktopUi.fast,
            decoration: BoxDecoration(
              color: wb.panel.withValues(alpha: _hover ? 0.95 : 0.8),
              borderRadius: DesktopUi.rMd,
              border: Border.all(
                color: widget.focused || _hover
                    ? wb.accentBlue.withValues(alpha: 0.7)
                    : wb.border.withValues(alpha: 0.65),
                width: widget.focused || _hover ? 1.5 : 1,
              ),
              boxShadow: DesktopUi.softShadow(elevated: _hover),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: wb.accentBlue.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(widget.icon, size: 22, color: wb.accentBlue),
                ),
                const Spacer(),
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: wb.primaryText,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.subtitle,
                  style: TextStyle(color: wb.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
