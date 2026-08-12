import 'dart:async';

import 'package:flutter/material.dart';

import '../services/editor_find_history_store.dart';
import '../theme/workbench_theme.dart';

/// A single find match in editor text.
@immutable
class EditorFindHit {
  const EditorFindHit(this.start, this.length);

  final int start;
  final int length;

  int get end => start + length;

  TextRange get range => TextRange(start: start, end: end);
}

bool editorIsWordCharCode(int cu) {
  return (cu >= 0x30 && cu <= 0x39) ||
      (cu >= 0x41 && cu <= 0x5A) ||
      (cu >= 0x61 && cu <= 0x7A) ||
      cu == 0x5F ||
      cu >= 0x80;
}

bool editorIsWholeWordMatch(String text, int start, int length) {
  if (start > 0 && editorIsWordCharCode(text.codeUnitAt(start - 1))) {
    return false;
  }
  final end = start + length;
  if (end < text.length && editorIsWordCharCode(text.codeUnitAt(end))) {
    return false;
  }
  return true;
}

/// Compute find hits for [text] given [query] and options.
List<EditorFindHit> computeEditorFindHits(
  String text,
  String query, {
  bool caseSensitive = false,
  bool regex = false,
  bool wholeWord = false,
}) {
  if (query.isEmpty) return const [];
  final hits = <EditorFindHit>[];

  if (regex) {
    var pattern = query;
    if (wholeWord) {
      pattern = '\\b(?:$query)\\b';
    }
    final re = RegExp(
      pattern,
      caseSensitive: caseSensitive,
      multiLine: true,
    );
    for (final m in re.allMatches(text)) {
      if (m.end > m.start) {
        hits.add(EditorFindHit(m.start, m.end - m.start));
      }
    }
    return hits;
  }

  final haystack = caseSensitive ? text : text.toLowerCase();
  final needle = caseSensitive ? query : query.toLowerCase();
  var from = 0;
  while (true) {
    final i = haystack.indexOf(needle, from);
    if (i < 0) break;
    if (!wholeWord || editorIsWholeWordMatch(text, i, query.length)) {
      hits.add(EditorFindHit(i, query.length));
    }
    from = i + (query.isEmpty ? 1 : query.length);
  }
  return hits;
}

/// Character offset of the start of 1-based [line] in [text].
int editorLineStartOffset(String text, int line) {
  if (line < 1) return 0;
  var offset = 0;
  var cur = 1;
  while (cur < line) {
    final i = text.indexOf('\n', offset);
    if (i < 0) return text.length;
    offset = i + 1;
    cur++;
  }
  return offset;
}

/// 1-based line number for a character [offset].
int editorLineOfOffset(String text, int offset) {
  if (offset <= 0) return 1;
  final clamped = offset.clamp(0, text.length);
  return '\n'.allMatches(text.substring(0, clamped)).length + 1;
}

/// Replace [hit] preserving a normal [TextEditingValue] update so that a
/// focused [TextField] with [UndoHistoryController] can record the change.
///
/// Note: Flutter's [UndoHistoryController] has no begin/end transaction API;
/// bulk edits should use a single value assignment (see [onSetText]).
/// Replace [hit] with [replacement] via a single [TextEditingValue] write.
///
/// Pair with [TextField.undoController]: Flutter has no begin/end transaction
/// API on [UndoHistoryController], so bulk edits should use [EditorFindReplaceController.onSetText].
void editorReplaceHit(
  TextEditingController tec,
  EditorFindHit hit,
  String replacement,
) {
  final text = tec.text;
  final before = text.substring(0, hit.start);
  final after = text.substring(hit.start + hit.length);
  final next = before + replacement + after;
  tec.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(
      offset: before.length + replacement.length,
    ),
    composing: TextRange.empty,
  );
}

/// Insert indent / outdent helpers shared by editors.
void editorInsertIndent(TextEditingController tec, {String indent = '  '}) {
  final value = tec.value;
  final sel = value.selection;
  if (!sel.isValid) return;
  final start = sel.start;
  final end = sel.end;
  final text = value.text;
  if (sel.isCollapsed) {
    final next = text.replaceRange(start, start, indent);
    tec.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + indent.length),
    );
    return;
  }
  // Indent each line in selection.
  final lineStart = text.lastIndexOf('\n', start > 0 ? start - 1 : 0);
  final from = lineStart < 0 ? 0 : lineStart + 1;
  final chunk = text.substring(from, end);
  final indented = chunk.split('\n').map((l) => '$indent$l').join('\n');
  final next = text.replaceRange(from, end, indented);
  tec.value = TextEditingValue(
    text: next,
    selection: TextSelection(
      baseOffset: from,
      extentOffset: from + indented.length,
    ),
  );
}

void editorOutdent(TextEditingController tec, {String indent = '  '}) {
  final value = tec.value;
  final sel = value.selection;
  if (!sel.isValid) return;
  final text = value.text;
  final start = sel.start;
  final end = sel.isCollapsed ? sel.start : sel.end;
  final lineStart = text.lastIndexOf('\n', start > 0 ? start - 1 : 0);
  final from = lineStart < 0 ? 0 : lineStart + 1;
  final to = sel.isCollapsed
      ? () {
          final nl = text.indexOf('\n', start);
          return nl < 0 ? text.length : nl;
        }()
      : end;
  final chunk = text.substring(from, to);
  final outdented = chunk.split('\n').map(_outdentLine).join('\n');
  final next = text.replaceRange(from, to, outdented);
  final delta = chunk.length - outdented.length;
  tec.value = TextEditingValue(
    text: next,
    selection: sel.isCollapsed
        ? TextSelection.collapsed(
            offset: (start -
                    (start > from
                        ? delta.clamp(0, start - from)
                        : 0))
                .clamp(0, next.length),
          )
        : TextSelection(
            baseOffset: from,
            extentOffset: from + outdented.length,
          ),
  );
}

String _outdentLine(String line) {
  if (line.startsWith('  ')) return line.substring(2);
  if (line.startsWith('\t')) return line.substring(1);
  if (line.startsWith(' ')) return line.substring(1);
  return line;
}

/// Find / replace controller decoupled from a specific editor host.
class EditorFindReplaceController extends ChangeNotifier {
  EditorFindReplaceController();

  bool open = false;
  bool replaceMode = false;
  bool caseSensitive = false;
  bool regex = false;
  bool wholeWord = false;
  bool regexInvalid = false;

  final TextEditingController findCtrl = TextEditingController();
  final TextEditingController replaceCtrl = TextEditingController();

  List<EditorFindHit> hits = const [];
  int index = -1;

  List<String> history = const [];

  /// Host: map [hit] to TextField selection and scroll into view.
  void Function(EditorFindHit hit)? onApplySelection;

  /// Host: current document text.
  String Function()? getText;

  /// Host: replace [hit] with [replacement] (may use UndoHistoryController).
  void Function(EditorFindHit hit, String replacement)? onReplace;

  /// Host: set entire document text in one shot (replace-all, single undo).
  void Function(String text, TextSelection selection)? onSetText;

  /// Host: optional snackbar for invalid regex.
  void Function(String message)? onMessage;

  List<TextRange> get hitRanges =>
      hits.map((h) => h.range).toList(growable: false);

  EditorFindHit? get currentHit =>
      index >= 0 && index < hits.length ? hits[index] : null;

  Future<void> loadHistory() async {
    history = await EditorFindHistoryStore.load();
    notifyListeners();
  }

  Future<void> _rememberQuery() async {
    final q = findCtrl.text.trim();
    if (q.isEmpty) return;
    final next = await EditorFindHistoryStore.push(q);
    if (!_alive) return;
    history = next;
    notifyListeners();
  }

  bool _alive = true;

  void setOpen(bool value, {bool replace = false}) {
    open = value;
    if (value) {
      replaceMode = replace;
      unawaited(loadHistory());
    } else {
      _rememberQuery();
    }
    notifyListeners();
  }

  void toggleReplaceMode() {
    replaceMode = !replaceMode;
    if (!open) open = true;
    notifyListeners();
  }

  void rebuildHits() {
    regexInvalid = false;
    final q = findCtrl.text;
    final text = getText?.call() ?? '';
    final previousIndex = index;
    if (q.isEmpty) {
      hits = const [];
      index = -1;
      notifyListeners();
      return;
    }
    try {
      hits = computeEditorFindHits(
        text,
        q,
        caseSensitive: caseSensitive,
        regex: regex,
        wholeWord: wholeWord,
      );
      if (hits.isEmpty) {
        index = -1;
      } else if (previousIndex >= 0 && previousIndex < hits.length) {
        index = previousIndex;
      } else {
        index = 0;
      }
    } on FormatException {
      regexInvalid = true;
      hits = const [];
      index = -1;
    }
    notifyListeners();
  }

  void applyCurrent() {
    final hit = currentHit;
    if (hit == null) return;
    onApplySelection?.call(hit);
  }

  void findNext({bool reverse = false}) {
    if (hits.isEmpty && !regexInvalid) rebuildHits();
    if (regexInvalid) {
      onMessage?.call('无效的正则表达式');
      notifyListeners();
      return;
    }
    if (hits.isEmpty) {
      notifyListeners();
      return;
    }
    if (reverse) {
      index = (index - 1 + hits.length) % hits.length;
    } else {
      index = (index + 1) % hits.length;
    }
    notifyListeners();
    applyCurrent();
    unawaited(_rememberQuery());
  }

  void replaceOne() {
    if (findCtrl.text.isEmpty) return;
    final text = getText?.call() ?? '';
    final replace = onReplace;
    if (replace == null) return;

    EditorFindHit? hit = currentHit;
    // Prefer matching current selection if it is a hit.
    // Host may have selection; we still use hit list.
    if (hit == null) {
      findNext();
      return;
    }

    // Verify hit still matches current text bounds.
    if (hit.end > text.length) {
      rebuildHits();
      hit = currentHit;
      if (hit == null) return;
    }

    replace(hit, replaceCtrl.text);
    rebuildHits();
    applyCurrent();
  }

  void replaceAll() {
    final q = findCtrl.text;
    if (q.isEmpty) return;
    rebuildHits();
    if (hits.isEmpty) return;
    final snapshot = List<EditorFindHit>.from(hits);
    final replacement = replaceCtrl.text;
    var text = getText?.call() ?? '';
    for (var i = snapshot.length - 1; i >= 0; i--) {
      final hit = snapshot[i];
      text = text.replaceRange(hit.start, hit.end, replacement);
    }
    final setText = onSetText;
    if (setText != null) {
      setText(text, TextSelection.collapsed(offset: text.length));
    } else {
      final replace = onReplace;
      if (replace == null) return;
      for (var i = snapshot.length - 1; i >= 0; i--) {
        replace(snapshot[i], replacement);
      }
    }
    rebuildHits();
  }

  void setCaseSensitive(bool v) {
    caseSensitive = v;
    rebuildHits();
    applyCurrent();
  }

  void setRegex(bool v) {
    regex = v;
    rebuildHits();
    applyCurrent();
  }

  void setWholeWord(bool v) {
    wholeWord = v;
    rebuildHits();
    applyCurrent();
  }

  void useHistoryQuery(String q) {
    findCtrl.text = q;
    rebuildHits();
    applyCurrent();
  }

  @override
  void dispose() {
    _alive = false;
    findCtrl.dispose();
    replaceCtrl.dispose();
    super.dispose();
  }
}

/// Shared find / replace bar UI.
class EditorFindBar extends StatelessWidget {
  const EditorFindBar({
    super.key,
    required this.controller,
    this.compact = false,
  });

  final EditorFindReplaceController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        return Material(
          color: wb.panelElevated,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _FindField(
                        controller: c,
                        wb: wb,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _FindOptionChip(
                              wb: wb,
                              label: 'Aa',
                              tooltip: '区分大小写',
                              selected: c.caseSensitive,
                              onTap: () =>
                                  c.setCaseSensitive(!c.caseSensitive),
                            ),
                            _FindOptionChip(
                              wb: wb,
                              label: '.*',
                              tooltip: '正则表达式',
                              selected: c.regex,
                              onTap: () => c.setRegex(!c.regex),
                            ),
                            _FindOptionChip(
                              wb: wb,
                              label: 'W',
                              tooltip: '全词匹配',
                              selected: c.wholeWord,
                              onTap: () => c.setWholeWord(!c.wholeWord),
                            ),
                            TextButton(
                              onPressed: () => c.findNext(reverse: true),
                              child: const Text('上一个'),
                            ),
                            TextButton(
                              onPressed: () => c.findNext(),
                              child: const Text('下一个'),
                            ),
                            Text(
                              c.findCtrl.text.isEmpty
                                  ? ''
                                  : (c.hits.isEmpty
                                      ? '无匹配'
                                      : '${c.index + 1}/${c.hits.length}'),
                              style: TextStyle(
                                fontSize: 11,
                                color: wb.textMuted,
                              ),
                            ),
                            IconButton(
                              iconSize: 18,
                              onPressed: () => c.setOpen(false),
                              icon: Icon(Icons.close, color: wb.textMuted),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (c.replaceMode) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: c.replaceCtrl,
                          style: TextStyle(
                            fontSize: 13,
                            color: wb.primaryText,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '替换为',
                            hintStyle: TextStyle(color: wb.textMuted),
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      Flexible(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: c.replaceOne,
                                child: const Text('替换'),
                              ),
                              TextButton(
                                onPressed: c.replaceAll,
                                child: const Text('全部替换'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FindField extends StatelessWidget {
  const _FindField({required this.controller, required this.wb});

  final EditorFindReplaceController controller;
  final WorkbenchColors wb;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final errorBorder = OutlineInputBorder(
      borderSide: BorderSide(color: Theme.of(context).colorScheme.error),
    );
    final errorFocused = OutlineInputBorder(
      borderSide: BorderSide(
        color: Theme.of(context).colorScheme.error,
        width: 1.5,
      ),
    );

    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: c.findCtrl,
            autofocus: true,
            style: TextStyle(fontSize: 13, color: wb.primaryText),
            decoration: InputDecoration(
              isDense: true,
              hintText: '查找',
              hintStyle: TextStyle(color: wb.textMuted),
              border: const OutlineInputBorder(),
              enabledBorder: c.regexInvalid ? errorBorder : null,
              focusedBorder: c.regexInvalid ? errorFocused : null,
            ),
            onChanged: (_) {
              c.rebuildHits();
              c.applyCurrent();
            },
            onSubmitted: (_) => c.findNext(),
          ),
        ),
        if (c.history.isNotEmpty)
          PopupMenuButton<String>(
            tooltip: '查找历史',
            icon: Icon(Icons.history, size: 18, color: wb.textMuted),
            onSelected: c.useHistoryQuery,
            itemBuilder: (ctx) => [
              for (final q in c.history)
                PopupMenuItem(value: q, child: Text(q)),
            ],
          ),
      ],
    );
  }
}

class _FindOptionChip extends StatelessWidget {
  const _FindOptionChip({
    required this.wb,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final WorkbenchColors wb;
  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.only(right: 2),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? wb.accentBlue.withValues(alpha: 0.22)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: selected ? wb.accentBlue : wb.border,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                color: selected ? wb.accentBlue : wb.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared goto-line dialog; returns 1-based line or null.
Future<int?> showGotoLineDialog(BuildContext context) {
  return showDialog<int>(
    context: context,
    builder: (ctx) => const _GotoLineDialog(),
  );
}

/// Owns [TextEditingController] so it is not disposed while the dialog
/// route exit animation still holds the [TextField].
class _GotoLineDialog extends StatefulWidget {
  const _GotoLineDialog();

  @override
  State<_GotoLineDialog> createState() => _GotoLineDialogState();
}

class _GotoLineDialogState extends State<_GotoLineDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop(context, int.tryParse(_ctrl.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return AlertDialog(
      backgroundColor: wb.panelElevated,
      title: Text('跳转到行', style: TextStyle(color: wb.primaryText)),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        style: TextStyle(color: wb.primaryText),
        decoration: const InputDecoration(hintText: '行号'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('跳转'),
        ),
      ],
    );
  }
}
