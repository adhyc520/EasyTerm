import 'package:flutter/material.dart';

import '../../theme/workbench_theme.dart';
import 'desktop_widget.dart';

class StickyNoteDesktopWidget extends DesktopWidgetKind {
  @override
  String get id => 'sticky_note';

  @override
  String get name => '便签';

  @override
  IconData get icon => Icons.sticky_note_2_rounded;

  @override
  DesktopWidgetConfig defaultConfig() => DesktopWidgetConfig(
        position: const Offset(280, 32),
        size: const Size(220, 160),
      );

  @override
  Widget build(BuildContext context, DesktopWidgetConfig config) {
    return const _StickyNoteBody();
  }
}

class _StickyNoteBody extends StatefulWidget {
  const _StickyNoteBody();

  @override
  State<_StickyNoteBody> createState() => _StickyNoteBodyState();
}

class _StickyNoteBodyState extends State<_StickyNoteBody> {
  late final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Padding(
      padding: const EdgeInsets.all(10),
      child: TextField(
        controller: _controller,
        maxLines: null,
        expands: true,
        style: TextStyle(color: wb.primaryText, fontSize: 13),
        decoration: InputDecoration(
          hintText: '写点什么…',
          hintStyle: TextStyle(color: wb.textMuted),
          border: InputBorder.none,
          isDense: true,
        ),
      ),
    );
  }
}
