import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/workbench_theme.dart';

/// 桌面 UI 常量：圆角、间距、时长（对齐 macOS 视觉节奏）。
abstract final class DesktopUi {
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusPill = 999;
  static const double toolbarH = 40;
  static const double dockIcon = 32;
  static const double traffic = 12;
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration med = Duration(milliseconds: 220);

  static BorderRadius get rSm => BorderRadius.circular(radiusSm);
  static BorderRadius get rMd => BorderRadius.circular(radiusMd);
  static BorderRadius get rLg => BorderRadius.circular(radiusLg);

  static ShapeBorder popupShape(WorkbenchColors wb) => RoundedRectangleBorder(
        borderRadius: rMd,
        side: BorderSide(color: wb.border.withValues(alpha: 0.85)),
      );

  static List<BoxShadow> softShadow({bool elevated = false}) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: elevated ? 0.38 : 0.22),
          blurRadius: elevated ? 28 : 16,
          offset: Offset(0, elevated ? 12 : 6),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
      ];
}

/// 毛玻璃面板（Dock / Exposé / Spotlight / 菜单 / 桌面图标）。
class DesktopGlass extends StatelessWidget {
  const DesktopGlass({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding,
    this.sigma = 28,
    this.opacity = 0.72,
    this.border = true,
    this.elevated = false,
    this.shadow = true,
  });

  final Widget child;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final double sigma;
  final double opacity;
  final bool border;
  final bool elevated;
  /// 小尺寸图标等可关掉大阴影，避免发糊。
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = borderRadius ?? DesktopUi.rLg;
    final fill = (isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7))
        .withValues(alpha: opacity);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: shadow
            ? DesktopUi.softShadow(elevated: elevated)
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.16),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: radius,
              border: border
                  ? Border.all(
                      color: (isDark ? Colors.white : Colors.black).withValues(
                        alpha: isDark ? 0.22 : 0.14,
                      ),
                    )
                  : null,
            ),
            child: padding == null
                ? child
                : Padding(padding: padding!, child: child),
          ),
        ),
      ),
    );
  }
}

/// Windows / Linux 风格标题栏按钮（最小化 · 最大化 · 关闭，靠右）。
class DesktopCaptionButtons extends StatelessWidget {
  const DesktopCaptionButtons({
    super.key,
    required this.onMinimize,
    required this.onMaximize,
    required this.onClose,
    this.maximized = false,
  });

  final VoidCallback onMinimize;
  final VoidCallback onMaximize;
  final VoidCallback onClose;
  final bool maximized;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionBtn(
          icon: Icons.remove_rounded,
          tooltip: '最小化',
          onPressed: onMinimize,
          color: wb.textMuted,
        ),
        _CaptionBtn(
          icon: maximized
              ? Icons.filter_none_rounded
              : Icons.crop_square_rounded,
          tooltip: maximized ? '还原' : '最大化',
          onPressed: onMaximize,
          color: wb.textMuted,
        ),
        _CaptionBtn(
          icon: Icons.close_rounded,
          tooltip: '关闭',
          onPressed: onClose,
          color: wb.textMuted,
          danger: true,
        ),
      ],
    );
  }
}

class _CaptionBtn extends StatefulWidget {
  const _CaptionBtn({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.color,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color color;
  final bool danger;

  @override
  State<_CaptionBtn> createState() => _CaptionBtnState();
}

class _CaptionBtnState extends State<_CaptionBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = !_hover
        ? Colors.transparent
        : widget.danger
            ? const Color(0xFFE81123)
            : Colors.white.withValues(alpha: 0.08);
    final fg = _hover && widget.danger ? Colors.white : widget.color;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: DesktopUi.fast,
            width: 40,
            height: 28,
            alignment: Alignment.center,
            color: bg,
            child: Icon(widget.icon, size: 14, color: fg),
          ),
        ),
      ),
    );
  }
}

/// macOS 风格红绿灯（关 / 最小化 / 最大化）。
class DesktopTrafficLights extends StatefulWidget {
  const DesktopTrafficLights({
    super.key,
    required this.onClose,
    required this.onMinimize,
    required this.onMaximize,
    this.focused = true,
    this.maximized = false,
  });

  final VoidCallback onClose;
  final VoidCallback onMinimize;
  final VoidCallback onMaximize;
  final bool focused;
  final bool maximized;

  @override
  State<DesktopTrafficLights> createState() => _DesktopTrafficLightsState();
}

class _DesktopTrafficLightsState extends State<DesktopTrafficLights> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final showGlyph = _hover || !widget.focused;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Light(
            color: widget.focused
                ? const Color(0xFFFF5F57)
                : const Color(0xFF5A5A5E),
            glyph: Icons.close_rounded,
            showGlyph: showGlyph && widget.focused,
            tooltip: '关闭',
            onTap: widget.onClose,
          ),
          const SizedBox(width: 8),
          _Light(
            color: widget.focused
                ? const Color(0xFFFEBC2E)
                : const Color(0xFF5A5A5E),
            glyph: Icons.remove_rounded,
            showGlyph: showGlyph && widget.focused,
            tooltip: '最小化',
            onTap: widget.onMinimize,
          ),
          const SizedBox(width: 8),
          _Light(
            color: widget.focused
                ? const Color(0xFF28C840)
                : const Color(0xFF5A5A5E),
            glyph: widget.maximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            showGlyph: showGlyph && widget.focused,
            tooltip: widget.maximized ? '还原' : '最大化',
            onTap: widget.onMaximize,
          ),
        ],
      ),
    );
  }
}

class _Light extends StatefulWidget {
  const _Light({
    required this.color,
    required this.glyph,
    required this.showGlyph,
    required this.tooltip,
    required this.onTap,
  });

  final Color color;
  final IconData glyph;
  final bool showGlyph;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_Light> createState() => _LightState();
}

class _LightState extends State<_Light> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final size = DesktopUi.traffic;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) {
          setState(() => _down = false);
          widget.onTap();
        },
        child: SizedBox(
          width: size + 4,
          height: size + 4,
          child: Center(
            child: AnimatedContainer(
              duration: DesktopUi.fast,
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: _down ? 0.75 : 1),
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.12),
                  width: 0.5,
                ),
              ),
              child: widget.showGlyph
                  ? Icon(
                      widget.glyph,
                      size: 8,
                      color: Colors.black.withValues(alpha: 0.55),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// 各 App 顶栏：统一高度、底部分隔、毛玻璃感底色。
class DesktopAppToolbar extends StatelessWidget {
  const DesktopAppToolbar({
    super.key,
    required this.child,
    this.height = DesktopUi.toolbarH,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
  });

  final Widget child;
  final double height;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Container(
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: wb.panelElevated.withValues(alpha: 0.55),
        border: Border(
          bottom: BorderSide(color: wb.border.withValues(alpha: 0.85)),
        ),
      ),
      child: child,
    );
  }
}

/// App 标题文字样式。
class DesktopAppTitle extends StatelessWidget {
  const DesktopAppTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        color: wb.primaryText,
      ),
    );
  }
}

/// 小胶囊标签（包管理器 / 防火墙后端等）。
class DesktopMetaChip extends StatelessWidget {
  const DesktopMetaChip({
    super.key,
    required this.label,
    this.leading,
    this.accent = false,
  });

  final String label;
  final Widget? leading;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent
            ? wb.accentBlue.withValues(alpha: 0.14)
            : wb.panel.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(DesktopUi.radiusPill),
        border: Border.all(
          color: accent
              ? wb.accentBlue.withValues(alpha: 0.35)
              : wb.border.withValues(alpha: 0.8),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: accent ? wb.accentBlue : wb.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// 统一紧凑 IconButton。
class DesktopToolIcon extends StatelessWidget {
  const DesktopToolIcon({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.active = false,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final btn = IconButton(
      tooltip: tooltip,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: enabled ? onPressed : null,
      icon: Icon(
        icon,
        color: !enabled
            ? wb.textMuted.withValues(alpha: 0.4)
            : active
                ? wb.accentBlue
                : wb.textMuted,
      ),
    );
    return btn;
  }
}

/// TabBar 统一外观。
TabBar desktopTabBar({
  required TabController controller,
  required List<Widget> tabs,
  required WorkbenchColors wb,
}) {
  return TabBar(
    controller: controller,
    labelColor: wb.accentBlue,
    unselectedLabelColor: wb.textMuted,
    indicatorColor: wb.accentBlue,
    indicatorSize: TabBarIndicatorSize.label,
    dividerColor: wb.border.withValues(alpha: 0.6),
    labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    unselectedLabelStyle:
        const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
    tabs: tabs,
  );
}

/// 现代化列表行（用于用户/包/规则等）。
class DesktopListRow extends StatefulWidget {
  const DesktopListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.selected = false,
    this.onTap,
    this.onSecondaryTap,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onSecondaryTap;

  @override
  State<DesktopListRow> createState() => _DesktopListRowState();
}

class _DesktopListRowState extends State<DesktopListRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final bg = widget.selected
        ? wb.accentBlue.withValues(alpha: 0.14)
        : _hover
            ? wb.primaryText.withValues(alpha: 0.05)
            : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTap: widget.onSecondaryTap,
        child: AnimatedContainer(
          duration: DesktopUi.fast,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: DesktopUi.rSm,
            border: widget.selected
                ? Border.all(color: wb.accentBlue.withValues(alpha: 0.35))
                : null,
          ),
          child: Row(
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DefaultTextStyle(
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: wb.primaryText,
                      ),
                      child: widget.title,
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 2),
                      DefaultTextStyle(
                        style: TextStyle(fontSize: 11, color: wb.textMuted),
                        child: widget.subtitle!,
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
      ),
    );
  }
}
