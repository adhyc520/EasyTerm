import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/command_history_service.dart';
import '../theme/workbench_theme.dart';

/// Ctrl+R style overlay: filter history as you type; Enter selects a command.
class CommandHistorySearch extends StatefulWidget {
  const CommandHistorySearch({
    super.key,
    required this.history,
    required this.hostKey,
    required this.onSelect,
    this.onClose,
    this.initialQuery = '',
  });

  final CommandHistoryService history;
  final String hostKey;
  final ValueChanged<String> onSelect;
  final VoidCallback? onClose;
  final String initialQuery;

  /// Show as a modal barrier + bottom overlay; returns selected command or null.
  static Future<String?> show(
    BuildContext context, {
    required CommandHistoryService history,
    required String hostKey,
  }) {
    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'command-history',
      barrierColor: Colors.black54,
      pageBuilder: (ctx, anim, secondary) {
        return CommandHistorySearch(
          history: history,
          hostKey: hostKey,
          onSelect: (cmd) => Navigator.pop(ctx, cmd),
          onClose: () => Navigator.pop(ctx),
        );
      },
      transitionBuilder: (ctx, anim, secondary, child) {
        return FadeTransition(opacity: anim, child: child);
      },
    );
  }

  @override
  State<CommandHistorySearch> createState() => _CommandHistorySearchState();
}

class _CommandHistorySearchState extends State<CommandHistorySearch> {
  late final TextEditingController _query;
  final FocusNode _focus = FocusNode();
  List<CommandRecord> _matches = const [];
  int _highlight = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController(text: widget.initialQuery);
    _query.addListener(_onQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
      unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.removeListener(_onQueryChanged);
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 80), () {
      unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    final q = _query.text;
    final list = await widget.history.searchHistory(
      q,
      hostKey: widget.hostKey,
      limit: 40,
    );
    if (!mounted) return;
    setState(() {
      _matches = list;
      _highlight = list.isEmpty ? 0 : _highlight.clamp(0, list.length - 1);
    });
  }

  void _selectIndex(int i) {
    if (i < 0 || i >= _matches.length) return;
    widget.onSelect(_matches[i].command);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose?.call();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_matches.isEmpty) return KeyEventResult.handled;
      setState(() => _highlight = (_highlight + 1) % _matches.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_matches.isEmpty) return KeyEventResult.handled;
      setState(
        () => _highlight =
            (_highlight - 1 + _matches.length) % _matches.length,
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _selectIndex(_highlight);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Material(
            color: wb.panelElevated,
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 360),
              child: Focus(
                onKeyEvent: _onKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                      child: Row(
                        children: [
                          Icon(Icons.history, size: 18, color: wb.textMuted),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '命令历史',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: wb.primaryText,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Enter 选择 · Esc 关闭',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                color: wb.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: _query,
                        focusNode: _focus,
                        autofocus: true,
                        style: TextStyle(
                          color: wb.primaryText,
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          hintText: '过滤命令…',
                          hintStyle: TextStyle(color: wb.textMuted),
                          isDense: true,
                          prefixIcon: Icon(
                            Icons.search,
                            size: 18,
                            color: wb.textMuted,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onSubmitted: (_) => _selectIndex(_highlight),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Flexible(
                      child: _matches.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                '无匹配记录',
                                style: TextStyle(color: wb.textMuted),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.only(bottom: 8),
                              itemCount: _matches.length,
                              itemBuilder: (ctx, i) {
                                final r = _matches[i];
                                final selected = i == _highlight;
                                return InkWell(
                                  onTap: () => _selectIndex(i),
                                  onHover: (h) {
                                    if (h) setState(() => _highlight = i);
                                  },
                                  child: Container(
                                    color: selected
                                        ? wb.accentBlue.withValues(alpha: 0.15)
                                        : null,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 8,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          r.command,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: wb.primaryText,
                                            fontFamily: 'monospace',
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${r.cwd} · ${_fmtTime(r.timestamp)}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: wb.textMuted,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    return '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}
