import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/ssh_workspace_controller.dart';
import '../util/editor_highlight.dart';
import '../util/editor_syntax.dart';

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
  Timer? _poll;
  Timer? _syntaxDebounce;
  int? _remoteMtime;
  bool _remoteChanged = false;
  bool _saving = false;
  EditorLanguage get _language => _text.language;
  EditorSyntaxIssue? _syntaxIssue;

  @override
  void initState() {
    super.initState();
    _remoteMtime = widget.initialRemoteMtime;
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _checkRemote());
    _text.addListener(_onTextChanged);
    _runSyntaxCheckNow();
  }

  void _onTextChanged() => _scheduleSyntaxCheck();

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

  @override
  void dispose() {
    _poll?.cancel();
    _syntaxDebounce?.cancel();
    _text.removeListener(_onTextChanged);
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
            _save(),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            _save(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              _language == EditorLanguage.plain
                  ? widget.fileName
                  : '${widget.fileName} · ${editorLanguageLabel(_language)}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
            ),
            actions: [
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
                          color:
                              Theme.of(context).colorScheme.onTertiaryContainer,
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
                  child: TextField(
                    controller: _text,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.35,
                    ),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isCollapsed: true,
                      contentPadding: EdgeInsets.all(12),
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
