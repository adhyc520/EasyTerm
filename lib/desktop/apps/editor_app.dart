import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../util/editor_highlight.dart';
import '../../util/editor_syntax.dart';
import '../../util/remote_paths.dart';
import '../desktop_window_manager.dart';

/// 桌面内联远程编辑器：经 [SshWorkspaceController.sftp] 按绝对路径读写。
class EditorApp extends StatefulWidget {
  const EditorApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<EditorApp> createState() => _EditorAppState();
}

class _EditorAppState extends State<EditorApp> {
  final SyntaxEditingController _text = SyntaxEditingController();
  Timer? _poll;
  Timer? _syntaxDebounce;
  int? _remoteMtime;
  bool _remoteChanged = false;
  bool _saving = false;
  bool _loading = true;
  String? _error;
  bool _dirty = false;
  bool _suppressDirty = false;
  EditorSyntaxIssue? _syntaxIssue;

  EditorLanguage get _language => _text.language;

  String get _path {
    final raw = widget.window.args['path']?.toString() ?? '';
    if (raw.isEmpty) return '';
    if (isRemoteAbsolutePath(raw)) return normalizeRemotePath(raw);
    return remoteJoin(widget.controller.remoteCwd, raw);
  }

  @override
  void initState() {
    super.initState();
    widget.window.onWillClose = _confirmCloseIfDirty;
    _text.addListener(_onTextChanged);
    unawaited(_load());
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _checkRemote());
  }

  void _onTextChanged() {
    if (!_suppressDirty && !_dirty) {
      setState(() => _dirty = true);
    }
    _scheduleSyntaxCheck();
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

  @override
  void dispose() {
    widget.window.onWillClose = null;
    _poll?.cancel();
    _syntaxDebounce?.cancel();
    _text.removeListener(_onTextChanged);
    _text.dispose();
    super.dispose();
  }

  Future<bool> _confirmCloseIfDirty() async {
    if (!_dirty || !mounted) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final wb = ctx.wb;
        return AlertDialog(
          backgroundColor: wb.panelElevated,
          title: Text('未保存的更改', style: TextStyle(color: wb.primaryText)),
          content: Text(
            '关闭「${remoteBasename(_path)}」将丢失未保存的修改。',
            style: TextStyle(color: wb.secondaryText),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('不保存'),
            ),
            FilledButton(
              onPressed: () async {
                await _save();
                if (ctx.mounted) Navigator.pop(ctx, !_dirty);
              },
              child: const Text('保存并关闭'),
            ),
          ],
        );
      },
    );
    return ok == true;
  }

  Future<Uint8List?> _readAbsolute(String path) async {
    final client = widget.controller.sftp;
    if (client == null) return null;
    final file = await client.open(path, mode: SftpFileOpenMode.read);
    try {
      final stat = await file.stat();
      final size = stat.size ?? 0;
      if (size > kMaxEditorBytes) {
        throw StateError('文件过大（$size 字节），上限为 $kMaxEditorBytes 字节');
      }
      return await file.readBytes();
    } finally {
      await file.close();
    }
  }

  Future<void> _writeAbsolute(String path, Uint8List bytes) async {
    final client = widget.controller.sftp;
    if (client == null) throw StateError('SFTP 未就绪');
    final file = await client.open(
      path,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(bytes);
    } finally {
      await file.close();
    }
  }

  Future<int?> _mtimeAbsolute(String path) async {
    final client = widget.controller.sftp;
    if (client == null) return null;
    final attrs = await client.stat(path);
    return attrs.modifyTime;
  }

  Future<void> _load() async {
    final path = _path;
    if (path.isEmpty) {
      setState(() {
        _loading = false;
        _error = '未指定文件路径';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!widget.controller.connected || widget.controller.sftp == null) {
        setState(() {
          _loading = false;
          _error = '未连接';
        });
        return;
      }
      final bytes = await _readAbsolute(path);
      if (!mounted) return;
      if (bytes == null) {
        setState(() {
          _loading = false;
          _error = '无法读取文件';
        });
        return;
      }
      if (!looksLikeTextBytes(bytes)) {
        setState(() {
          _loading = false;
          _error = '看起来不是文本文件';
        });
        return;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      _text.language = editorLanguageFromPath(path);
      _suppressDirty = true;
      _text.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _suppressDirty = false;
      _runSyntaxCheckNow();
      _remoteMtime = await _mtimeAbsolute(path);
      widget.window.title = remoteBasename(path);
      widget.wm.requestRebuild();
      setState(() {
        _loading = false;
        _dirty = false;
        _remoteChanged = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _checkRemote() async {
    if (!mounted || _saving || _loading || _path.isEmpty) return;
    if (!widget.controller.connected) return;
    try {
      final t = await _mtimeAbsolute(_path);
      if (!mounted || t == null) return;
      if (_remoteMtime != null && t != _remoteMtime) {
        setState(() => _remoteChanged = true);
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    final path = _path;
    if (path.isEmpty) return;
    setState(() => _saving = true);
    try {
      final bytes = Uint8List.fromList(utf8.encode(_text.text));
      if (bytes.length > kMaxEditorBytes) {
        throw StateError('内容超过上限 $kMaxEditorBytes 字节');
      }
      await _writeAbsolute(path, bytes);
      _remoteMtime = await _mtimeAbsolute(path);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _remoteChanged = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;

    if (_loading) {
      return ColoredBox(
        color: wb.bg,
        child: Center(
          child: CircularProgressIndicator(color: wb.accentBlue),
        ),
      );
    }

    if (_error != null) {
      return ColoredBox(
        color: wb.bg,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, style: TextStyle(color: wb.textMuted)),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => unawaited(_load()),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
            unawaited(_save()),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            unawaited(_save()),
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: wb.bg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: wb.panel,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: wb.textMuted,
                          ),
                        ),
                      ),
                      if (_language != EditorLanguage.plain)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            editorLanguageLabel(_language),
                            style: TextStyle(
                              fontSize: 11,
                              color: wb.textMuted,
                            ),
                          ),
                        ),
                      if (_dirty)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            '未保存',
                            style: TextStyle(
                              fontSize: 11,
                              color: wb.folder,
                            ),
                          ),
                        ),
                      TextButton.icon(
                        onPressed: _saving ? null : () => unawaited(_save()),
                        icon: _saving
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save_rounded, size: 16),
                        label: const Text('保存'),
                      ),
                    ],
                  ),
                ),
              ),
              if (_remoteChanged)
                Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 18,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '远端文件已更改',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => unawaited(_load()),
                          child: const Text('重新加载'),
                        ),
                        TextButton(
                          onPressed: () =>
                              setState(() => _remoteChanged = false),
                          child: const Text('忽略'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_syntaxIssue != null)
                Material(
                  color: wb.folder.withValues(alpha: 0.18),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          size: 18,
                          color: wb.folder,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '语法错误 · ${_syntaxIssue!.displayMessage}',
                            style: TextStyle(
                              color: wb.primaryText,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    controller: _text,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.35,
                      color: wb.primaryText,
                    ),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: wb.panel,
                      border: OutlineInputBorder(
                        borderSide: BorderSide(color: wb.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: wb.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: wb.accentBlue),
                      ),
                      isCollapsed: true,
                      contentPadding: const EdgeInsets.all(12),
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
