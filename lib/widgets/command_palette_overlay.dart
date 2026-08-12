import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/command_bookmark_store.dart';
import '../theme/workbench_theme.dart';

/// Overlay palette to search / pick / add command bookmarks.
class CommandPaletteOverlay extends StatefulWidget {
  const CommandPaletteOverlay({
    super.key,
    required this.store,
    required this.onSelect,
    required this.onClose,
    this.host,
  });

  final CommandBookmarkStore store;
  final ValueChanged<String> onSelect;
  final VoidCallback onClose;

  /// Optional host for [CommandBookmark.hostPattern] filtering.
  final String? host;

  @override
  State<CommandPaletteOverlay> createState() => _CommandPaletteOverlayState();
}

class _CommandPaletteOverlayState extends State<CommandPaletteOverlay> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  int _selected = 0;
  List<CommandBookmark> _filtered = [];

  @override
  void initState() {
    super.initState();
    _query.addListener(_refilter);
    widget.store.addListener(_refilter);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.store.ensureLoaded();
      if (!mounted) return;
      _refilter();
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.store.removeListener(_refilter);
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _refilter() {
    final list = widget.store.search(_query.text, host: widget.host);
    setState(() {
      _filtered = list;
      if (_selected >= _filtered.length) {
        _selected = _filtered.isEmpty ? 0 : _filtered.length - 1;
      }
    });
  }

  Future<void> _runSelected() async {
    if (_filtered.isEmpty) return;
    final b = _filtered[_selected.clamp(0, _filtered.length - 1)];
    await widget.store.recordUse(b.id);
    widget.onClose();
    widget.onSelect(b.command);
  }

  Future<void> _openAddDialog() async {
    final labelCtrl = TextEditingController();
    final cmdCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final wb = ctx.wb;
        return AlertDialog(
          backgroundColor: wb.panelElevated,
          title: Text('新增命令书签', style: TextStyle(color: wb.primaryText)),
          content: SizedBox(
            width: (MediaQuery.sizeOf(ctx).width - 48).clamp(280.0, 420.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: labelCtrl,
                    decoration: const InputDecoration(
                      labelText: '名称',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: cmdCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '命令',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: '备注（可选）',
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (ok == true && mounted) {
      try {
        await widget.store.create(
          label: labelCtrl.text,
          command: cmdCtrl.text,
          description: descCtrl.text,
        );
        _refilter();
      } catch (_) {}
    }
    labelCtrl.dispose();
    cmdCtrl.dispose();
    descCtrl.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_filtered.isEmpty) return KeyEventResult.handled;
      setState(() => _selected = (_selected + 1) % _filtered.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_filtered.isEmpty) return KeyEventResult.handled;
      setState(
        () => _selected =
            (_selected - 1 + _filtered.length) % _filtered.length,
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      unawaited(_runSelected());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
              child: Material(
                color: wb.panelElevated,
                elevation: 12,
                borderRadius: BorderRadius.circular(12),
                child: Focus(
                  focusNode: _focus,
                  onKeyEvent: _onKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                        child: TextField(
                          controller: _query,
                          autofocus: true,
                          style: TextStyle(color: wb.primaryText),
                          decoration: InputDecoration(
                            hintText: '搜索命令书签…',
                            hintStyle: TextStyle(color: wb.textMuted),
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              color: wb.textMuted,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            isDense: true,
                          ),
                        ),
                      ),
                      Flexible(
                        child: _filtered.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  _query.text.isEmpty
                                      ? '暂无书签，点击下方新增'
                                      : '无匹配',
                                  style: TextStyle(color: wb.textMuted),
                                ),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                itemCount: _filtered.length,
                                itemBuilder: (context, i) {
                                  final b = _filtered[i];
                                  final sel = i == _selected;
                                  return ListTile(
                                    dense: true,
                                    selected: sel,
                                    selectedTileColor:
                                        wb.accentBlue.withValues(alpha: 0.18),
                                    leading: Icon(
                                      Icons.bookmark_rounded,
                                      size: 18,
                                      color: wb.textMuted,
                                    ),
                                    title: Text(
                                      b.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: wb.primaryText),
                                    ),
                                    subtitle: Text(
                                      b.command.split('\n').first +
                                          (b.description == null ||
                                                  b.description!.isEmpty
                                              ? ''
                                              : ' · ${b.description}'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: wb.textMuted,
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                    trailing: b.useCount > 0
                                        ? Text(
                                            '×${b.useCount}',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: wb.textMuted,
                                            ),
                                          )
                                        : null,
                                    onTap: () {
                                      _selected = i;
                                      unawaited(_runSelected());
                                    },
                                  );
                                },
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                        child: Row(
                          children: [
                            TextButton.icon(
                              onPressed: () => unawaited(_openAddDialog()),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('新增'),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                '↑↓ 选择 · Enter 执行 · Esc 关闭',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.end,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: wb.textMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
