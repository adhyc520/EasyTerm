import 'package:flutter/material.dart';

/// Horizontal action strip that scrolls instead of overflowing a parent [Row].
///
/// Place inside [Flexible] (or give it another bounded width). Returning
/// [Flexible] from this widget would break Flex parent-data rules.
///
/// ```dart
/// Row(
///   children: [
///     Expanded(child: filterField),
///     Flexible(child: DesktopScrollableActions(children: buttons)),
///   ],
/// )
/// ```
class DesktopScrollableActions extends StatelessWidget {
  const DesktopScrollableActions({
    super.key,
    required this.children,
    this.height = 36,
    this.alignment = Alignment.centerRight,
    this.padding = EdgeInsets.zero,
  });

  final List<Widget> children;
  final double height;
  final AlignmentGeometry alignment;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Align(
        alignment: alignment,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: padding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// Full-width toolbar row that scrolls horizontally when children are too wide.
///
/// Prefer this when the entire toolbar (not just trailing actions) must shrink
/// without a flex sibling — e.g. form rows of fixed-width fields.
class DesktopHScrollRow extends StatelessWidget {
  const DesktopHScrollRow({
    super.key,
    required this.children,
    this.height,
    this.padding = EdgeInsets.zero,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  final List<Widget> children;
  final double? height;
  final EdgeInsetsGeometry padding;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        child: Row(
          crossAxisAlignment: crossAxisAlignment,
          children: children,
        ),
      ),
    );
  }
}
