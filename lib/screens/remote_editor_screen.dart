import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_desktop_shortcuts.dart';
import '../theme/workbench_theme.dart';
import '../util/editor_highlight.dart';
import '../util/editor_syntax.dart';
import '../widgets/editor_find_bar.dart';

class RemoteEditorScreen extends StatefulWidget {
  const RemoteEditorScreen({
    super.key,
    required this.controller,
    required this.fileName,
    required this.initialText,
    this.initialRemoteMtime,
  });

  final SshWorkspaceController controller;
  final String fileName;
  final String initialText;
  final int? initialRemoteMtime;

  @override
  State<RemoteEditorScreen> createState() => _RemoteEditorScreenState();
}

class _RemoteEditorScreenState extends State<RemoteEditorScreen> {
  late final SyntaxEditingController _text = SyntaxEditingController(
    text: widget.initialText,
    language: editorLanguageFromPath(widget.fileName),
  );
  final ScrollController _scroll = ScrollController();
  final ScrollController _gutterScroll = ScrollController();
  final UndoHistoryController _undo = UndoHistoryController();
  late final EditorFindReplaceController _find = EditorFindReplaceController();

  Timer? _poll;
  Timer? _syntaxDebounce;
  int? _remoteMtime;
  bool _remoteChanged = false;
  bool _saving = false;
  bool _applyingFindHits = false;
  String _lastFindSourceText = '';
  EditorLanguage get _language => _text.language;
  EditorSyntaxIssue? _syntaxIssue;

  static const _lineHeight = 13.0 * 1.35;

  @override
  void initState() {
    super.initState();
    _remoteMtime = widget.initialRemoteMtime;
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _checkRemote());
    _text.addListener(_onTextChanged);
    _scroll.addListener(_syncGutterScroll);
    _find.getText = () => _text.text;
    _find.onApplySelection = _applyFindHit;
    _find.onReplace = _replaceHit;
    _find.onSetText = (text, sel) {
      _text.value = TextEditingValue(text: text, selection: sel);
    };
    _find.onMessage = (msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    };
    _find.addListener(_onFindChanged);
    _runSyntaxCheckNow();
  }

  void _onFindChanged() {
    _applyingFindHits = true;
    try {
      _text.setFindHits(_find.hitRanges, currentIndex: _find.index);
    } finally {
      _applyingFindHits = false;
    }
    if (mounted) setState(() {});
  }

  void _applyFindHit(EditorFindHit hit) {
    _text.selection = TextSelection(
      baseOffset: hit.start,
      extentOffset: hit.end,
    );
    final line = editorLineOfOffset(_text.text, hit.start);
    _scrollToLine(line);
  }

  void _replaceHit(EditorFindHit hit, String replacement) {
    editorReplaceHit(_text, hit, replacement);
  }

  void _scrollToLine(int line) {
    if (!_scroll.hasClients) return;
    final target = ((line - 1) * _lineHeight).clamp(
      _scroll.position.minScrollExtent,
      _scroll.position.maxScrollExtent,
    );
    _scroll.jumpTo(target);
    _syncGutterScroll();
  }

  void _syncGutterScroll() {
    if (!_scroll.hasClients || !_gutterScroll.hasClients) return;
    final target = _scroll.offset.clamp(
      _gutterScroll.position.minScrollExtent,
      _gutterScroll.position.maxScrollExtent,
    );
    if ((_gutterScroll.offset - target).abs() > 0.5) {
      _gutterScroll.jumpTo(target);
    }
  }

  void _onTextChanged() {
    if (_applyingFindHits) return;
    _scheduleSyntaxCheck();
    if (_find.open && _text.text != _lastFindSourceText) {
      _lastFindSourceText = _text.text;
      _find.rebuildHits();
    }
    if (mounted) setState(() {});
  }

  void _scheduleSyntaxCheck() {
    _syntaxDebounce?.cancel();
    if (_language == EditorLanguage.plain) {
      if (_syntaxIssue != null) setState(() => _syntaxIssue = null);
      return;
    }
    _syntaxDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final issue = validateEditorSyntax(_language, _text.text);
      if (issue?.message != _syntaxIssue?.message ||
          issue?.line != _syntaxIssue?.line) {
        setState(() => _syntaxIssue = issue);
      }
    });
  }

  void _runSyntaxCheckNow() {
    _syntaxDebounce?.cancel();
    if (_language == EditorLanguage.plain) {
      _syntaxIssue = null;
      return;
    }
    _syntaxIssue = validateEditorSyntax(_language, _text.text);
  }

  Future<void> _checkRemote() async {
    if (!mounted || _saving) return;
    try {
      final t = await widget.controller.remoteMtime(widget.fileName);
      if (!mounted || t == null) return;
      if (_remoteMtime != null && t != _remoteMtime) {
        setState(() => _remoteChanged = true);
      }
    } catch (_) {}
  }

  Future<void> _reloadFromRemote() async {
    final bytes = await widget.controller.readRemoteFile(widget.fileName);
    if (bytes == null || !mounted) return;
    final text = utf8.decode(bytes, allowMalformed: true);
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _remoteMtime = await widget.controller.remoteMtime(widget.fileName);
    _runSyntaxCheckNow();
    setState(() => _remoteChanged = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final bytes = Uint8List.fromList(utf8.encode(_text.text));
      await widget.controller.writeRemoteFile(widget.fileName, bytes);
      _remoteMtime = await widget.controller.remoteMtime(widget.fileName);
      if (mounted) {
        setState(() => _remoteChanged = false);
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.remoteEditorSaved)));
      }
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.remoteEditorSaveFailed('$e'))));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _gotoLine() async {
    final line = await showGotoLineDialog(context);
    if (line == null || line < 1 || !mounted) return;
    final offset = editorLineStartOffset(_text.text, line);
    _text.selection = TextSelection.collapsed(offset: offset);
    _scrollToLine(line);
    setState(() {});
  }

  KeyEventResult _onEditorKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        editorOutdent(_text);
      } else {
        editorInsertIndent(_text);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _poll?.cancel();
    _syntaxDebounce?.cancel();
    _find.removeListener(_onFindChanged);
    _find.dispose();
    _text.removeListener(_onTextChanged);
    _text.dispose();
    _scroll.removeListener(_syncGutterScroll);
    _scroll.dispose();
    _gutterScroll.dispose();
    _undo.dispose();
    super.dispose();
  }

  int get _lineCount {
    final t = _text.text;
    if (t.isEmpty) return 1;
    return '\n'.allMatches(t).length + 1;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final wb = context.wb;
    final lineCount = _lineCount;
    final gutterW =
        (24.0 + lineCount.toString().length * 7).clamp(32.0, 60.0);

    final shortcuts = <ShortcutActivator, VoidCallback>{
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyS),
        () => unawaited(_save()),
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyF),
        () => _find.setOpen(true),
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyH),
        () => _find.setOpen(true, replace: true),
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyG),
        () => _find.findNext(),
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyG, shift: true),
        () => _find.findNext(reverse: true),
      ),
      ...workbenchBindActivators(
        workbenchMetaOrControl(LogicalKeyboardKey.keyL),
        () => unawaited(_gotoLine()),
      ),
    };

    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onEditorKey,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              _language == EditorLanguage.plain
                  ? widget.fileName
                  : '${widget.fileName} · ${editorLanguageLabel(_language)}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
            ),
            actions: [
              IconButton(
                tooltip: '查找',
                onPressed: () => _find.setOpen(!_find.open),
                icon: const Icon(Icons.search_rounded),
              ),
              IconButton(
                tooltip: '跳转到行',
                onPressed: () => unawaited(_gotoLine()),
                icon: const Icon(Icons.unfold_more_rounded),
              ),
              TextButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_rounded, size: 20),
                label: Text(l.remoteEditorSave),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_find.open) EditorFindBar(controller: _find),
              if (_remoteChanged)
                Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            l.remoteEditorRemoteChanged,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _reloadFromRemote,
                          child: Text(l.remoteEditorReload),
                        ),
                        TextButton(
                          onPressed: () =>
                              setState(() => _remoteChanged = false),
                          child: Text(l.remoteEditorIgnore),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_syntaxIssue != null)
                Material(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          color: Theme.of(context)
                              .colorScheme
                              .onTertiaryContainer,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            l.remoteEditorSyntaxError(
                              _syntaxIssue!.displayMessage,
                            ),
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onTertiaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: wb.border),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: gutterW,
                          child: ListenableBuilder(
                            listenable: _gutterScroll,
                            builder: (context, _) {
                              return SingleChildScrollView(
                                controller: _gutterScroll,
                                primary: false,
                                physics: const NeverScrollableScrollPhysics(),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    4,
                                    12,
                                    4,
                                    12,
                                  ),
                                  child: Text(
                                    [
                                      for (var i = 1; i <= lineCount; i++)
                                        '$i',
                                    ].join('\n'),
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 13,
                                      height: 1.35,
                                      color: wb.textMuted,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        VerticalDivider(width: 1, color: wb.border),
                        Expanded(
                          child: TextField(
                            controller: _text,
                            scrollController: _scroll,
                            undoController: _undo,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              height: 1.35,
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              isCollapsed: true,
                              contentPadding: EdgeInsets.all(12),
                            ),
                          ),
                        ),
                      ],
                    ),
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
