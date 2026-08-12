import 'package:flutter/material.dart';

import '../theme/workbench_theme.dart';
import 'desktop_app_registry.dart';
import 'desktop_window_manager.dart';

/// 窗口 Exposé：缩略卡片概览（标题 + 应用图标），点击聚焦并关闭。
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
      color: Colors.black.withValues(alpha: 0.55),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Text(
                    '窗口概览',
                    style: TextStyle(
                      color: wb.primaryText,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: onClose,
                    icon: Icon(Icons.close, color: wb.textMuted),
                  ),
                ],
              ),
            ),
            Expanded(
              child: windows.isEmpty
                  ? Center(
                      child: Text(
                        '当前工作区没有打开的窗口',
                        style: TextStyle(color: wb.textMuted),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(20),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 240,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 1.35,
                      ),
                      itemCount: windows.length,
                      itemBuilder: (context, i) {
                        final w = windows[i];
                        final meta = metaFor(w.type);
                        return _ExposeCard(
                          title: w.title,
                          subtitle:
                              '${w.rect.width.round()}×${w.rect.height.round()}',
                          icon: meta.icon,
                          accent: wb.accentBlue,
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
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: ListenableBuilder(
                listenable: wm,
                builder: (context, _) {
                  return Wrap(
                    spacing: 8,
                    children: [
                      for (var i = 0; i < wm.workspaces.length; i++)
                        ChoiceChip(
                          label: Text('桌面 ${i + 1}'),
                          selected: i == wm.activeWorkspaceIndex,
                          onSelected: (_) {
                            wm.switchWorkspace(i);
                          },
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
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
    required this.accent,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: wb.panel.withValues(alpha: _hover ? 0.95 : 0.82),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hover ? widget.accent : wb.border,
              width: _hover ? 2 : 1,
            ),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: widget.accent.withValues(alpha: 0.25),
                      blurRadius: 16,
                    ),
                  ]
                : null,
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(widget.icon, size: 28, color: widget.accent),
              const Spacer(),
              Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: wb.primaryText,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
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
    );
  }
}
