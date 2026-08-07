import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../util/desktop_drop_paths.dart';
import '../../util/editor_highlight.dart';
import '../../util/editor_syntax.dart';
import '../../util/remote_paths.dart';
import '../desktop_window_manager.dart';

/// 桌面内联远程编辑器：多标签、查找替换、跳行；经 SFTP 按绝对路径读写。
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

class _EditorTab {
  _EditorTab(this.path)
      : text = SyntaxEditingController(),
        dirty = false;

  String path;
  final SyntaxEditingController text;
  int? remoteMtime;
  bool remoteChanged = false;
  bool dirty;
  bool suppressDirty = false;
  EditorSyntaxIssue? syntaxIssue;
  bool loading = true;
  String? error;

  EditorLanguage get language => text.language;

  void dispose() {
    text.dispose();
  }
}

class _EditorAppState extends State<EditorApp> {
  final List<_EditorTab> _tabs = [];
  int _active = 0;
  Timer? _poll;
  Timer? _syntaxDebounce;
  bool _saving = false;

  bool _findOpen = false;
  bool _replaceMode = false;
  final _findCtrl = TextEditingController();
  final _replaceCtrl = TextEditingController();
  int _findIndex = -1;
  List<int> _findHits = const [];

  static const _maxTabs = 8;

  _EditorTab? get _tab =>
      _tabs.isEmpty ? null : _tabs[_active.clamp(0, _tabs.length - 1)];

  @override
  void initState() {
    super.initState();
    widget.window.onWillClose = _confirmCloseIfDirty;
    widget.window.tryOpenEditorPath = _tryOpenPath;
    final initial = _normalizePath(
      widget.window.args['path']?.toString() ?? '',
    );
    if (initial.isNotEmpty) {
      unawaited(_addTab(initial));
    } else {
      setState(() {});
    }
    widget.window.onConnectionRestored = _onConnectionRestored;
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _checkRemote());
  }

  void _onConnectionRestored() {
    if (!mounted) return;
    unawaited(_checkAllRemoteAfterReconnect());
  }

  Future<void> _checkAllRemoteAfterReconnect() async {
    for (final tab in List<_EditorTab>.from(_tabs)) {
      if (!mounted) return;
      try {
        final t = await _mtimeAbsolute(tab.path);
        if (!mounted || t == null) continue;
        if (tab.remoteMtime != null && t != tab.remoteMtime) {
          setState(() => tab.remoteChanged = true);
        } else {
          tab.remoteMtime ??= t;
        }
      } catch (_) {}
    }
  }

  String _normalizePath(String raw) {
    if (raw.isEmpty) return '';
    if (isRemoteAbsolutePath(raw)) return normalizeRemotePath(raw);
    return remoteJoin(widget.controller.remoteCwd, raw);
  }

  bool _tryOpenPath(String raw) {
    final path = _normalizePath(raw);
    if (path.isEmpty) return false;
    final i = _tabs.indexWhere((t) => t.path == path);
    if (i >= 0) {
      setState(() => _active = i);
      _syncTitle();
      widget.wm.focus(widget.window.id);
      return true;
    }
    if (_tabs.length >= _maxTabs) return false;
    unawaited(_addTab(path));
    widget.wm.focus(widget.window.id);
    return true;
  }

  Future<void> _addTab(String path) async {
    final tab = _EditorTab(path);
    tab.text.addListener(() => _onTextChanged(tab));
    setState(() {
      _tabs.add(tab);
      _active = _tabs.length - 1;
    });
    await _load(tab);
  }

  void _onTextChanged(_EditorTab tab) {
    if (!tab.suppressDirty && !tab.dirty) {
      setState(() => tab.dirty = true);
      _syncTitle();
    }
    if (identical(tab, _tab)) _scheduleSyntaxCheck(tab);
  }

  void _scheduleSyntaxCheck(_EditorTab tab) {
    _syntaxDebounce?.cancel();
    if (tab.language == EditorLanguage.plain) {
      if (tab.syntaxIssue != null) setState(() => tab.syntaxIssue = null);
      return;
    }
    _syntaxDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      final issue = validateEditorSyntax(tab.language, tab.text.text);
      if (issue?.message != tab.syntaxIssue?.message ||
          issue?.line != tab.syntaxIssue?.line) {
        setState(() => tab.syntaxIssue = issue);
      }
    });
  }

  void _runSyntaxCheckNow(_EditorTab tab) {
    _syntaxDebounce?.cancel();
    if (tab.language == EditorLanguage.plain) {
      tab.syntaxIssue = null;
      return;
    }
    tab.syntaxIssue = validateEditorSyntax(tab.language, tab.text.text);
  }

  void _syncTitle() {
    final tab = _tab;
    if (tab == null) {
      widget.window.title = '编辑器';
    } else {
      final name = remoteBasename(tab.path);
      widget.window.title = '${tab.dirty ? '● ' : ''}$name';
    }
    widget.wm.requestRebuild();
  }

  @override
  void dispose() {
    widget.window.onWillClose = null;
    widget.window.onConnectionRestored = null;
    widget.window.tryOpenEditorPath = null;
    _poll?.cancel();
    _syntaxDebounce?.cancel();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    for (final t in _tabs) {
      t.dispose();
    }
    super.dispose();
  }

  Future<bool> _confirmCloseIfDirty() async {
    final dirtyTabs = _tabs.where((t) => t.dirty).toList();
    if (dirtyTabs.isEmpty || !mounted) return true;
    final names = dirtyTabs.map((t) => remoteBasename(t.path)).join('、');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final wb = ctx.wb;
        return AlertDialog(
          backgroundColor: wb.panelElevated,
          title: Text('未保存的更改', style: TextStyle(color: wb.primaryText)),
          content: Text(
            '关闭将丢失未保存的修改：$names',
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
                for (final t in dirtyTabs) {
                  await _save(t);
                }
                if (ctx.mounted) {
                  Navigator.pop(ctx, dirtyTabs.every((t) => !t.dirty));
                }
              },
              child: const Text('全部保存并关闭'),
            ),
          ],
        );
      },
    );
    return ok == true;
  }

  Future<bool> _confirmDiscardTab(_EditorTab tab) async {
    if (!tab.dirty || !mounted) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final wb = ctx.wb;
        return AlertDialog(
          backgroundColor: wb.panelElevated,
          title: Text('未保存的更改', style: TextStyle(color: wb.primaryText)),
          content: Text(
            '关闭「${remoteBasename(tab.path)}」将丢失未保存的修改。',
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
                await _save(tab);
                if (ctx.mounted) Navigator.pop(ctx, !tab.dirty);
              },
              child: const Text('保存并关闭'),
            ),
          ],
        );
      },
    );
    return ok == true;
  }

  Future<void> _closeTab(int index) async {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    if (tab.dirty) {
      final allow = await _confirmDiscardTab(tab);
      if (!allow) return;
    }
    tab.dispose();
    setState(() {
      _tabs.removeAt(index);
      if (_tabs.isEmpty) {
        _active = 0;
      } else if (_active >= _tabs.length) {
        _active = _tabs.length - 1;
      } else if (_active > index) {
        _active--;
      }
    });
    _syncTitle();
    if (_tabs.isEmpty) {
      unawaited(widget.wm.requestClose(widget.window.id));
    }
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
      mode: SftpFileOpenMode.create |
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

  Future<void> _load(_EditorTab tab) async {
    setState(() {
      tab.loading = true;
      tab.error = null;
    });
    try {
      if (!widget.controller.connected || widget.controller.sftp == null) {
        setState(() {
          tab.loading = false;
          tab.error = '未连接';
        });
        return;
      }
      final bytes = await _readAbsolute(tab.path);
      if (!mounted) return;
      if (bytes == null) {
        setState(() {
          tab.loading = false;
          tab.error = '无法读取文件';
        });
        return;
      }
      if (!looksLikeTextBytes(bytes)) {
        setState(() {
          tab.loading = false;
          tab.error = '看起来不是文本文件';
        });
        return;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      tab.text.language = editorLanguageFromPath(tab.path);
      tab.suppressDirty = true;
      tab.text.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      tab.suppressDirty = false;
      _runSyntaxCheckNow(tab);
      tab.remoteMtime = await _mtimeAbsolute(tab.path);
      setState(() {
        tab.loading = false;
        tab.dirty = false;
        tab.remoteChanged = false;
      });
      _syncTitle();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        tab.loading = false;
        tab.error = '$e';
      });
    }
  }

  Future<void> _checkRemote() async {
    final tab = _tab;
    if (!mounted || _saving || tab == null || tab.loading) return;
    if (!widget.controller.connected) return;
    try {
      final t = await _mtimeAbsolute(tab.path);
      if (!mounted || t == null) return;
      if (tab.remoteMtime != null && t != tab.remoteMtime) {
        setState(() => tab.remoteChanged = true);
      }
    } catch (_) {}
  }

  Future<void> _save([_EditorTab? target]) async {
    final tab = target ?? _tab;
    if (tab == null) return;
    setState(() => _saving = true);
    try {
      final bytes = Uint8List.fromList(utf8.encode(tab.text.text));
      if (bytes.length > kMaxEditorBytes) {
        throw StateError('内容超过上限 $kMaxEditorBytes 字节');
      }
      await _writeAbsolute(tab.path, bytes);
      tab.remoteMtime = await _mtimeAbsolute(tab.path);
      if (!mounted) return;
      setState(() {
        tab.dirty = false;
        tab.remoteChanged = false;
      });
      _syncTitle();
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

  void _rebuildFindHits() {
    final tab = _tab;
    final q = _findCtrl.text;
    if (tab == null || q.isEmpty) {
      _findHits = const [];
      _findIndex = -1;
      return;
    }
    final text = tab.text.text;
    final hits = <int>[];
    var from = 0;
    while (true) {
      final i = text.indexOf(q, from);
      if (i < 0) break;
      hits.add(i);
      from = i + q.length;
    }
    _findHits = hits;
    _findIndex = hits.isEmpty ? -1 : 0;
  }

  void _selectFindHit() {
    final tab = _tab;
    if (tab == null || _findIndex < 0 || _findIndex >= _findHits.length) return;
    final start = _findHits[_findIndex];
    final end = start + _findCtrl.text.length;
    tab.text.selection = TextSelection(baseOffset: start, extentOffset: end);
  }

  void _findNext({bool reverse = false}) {
    if (_findHits.isEmpty) _rebuildFindHits();
    if (_findHits.isEmpty) {
      setState(() {});
      return;
    }
    setState(() {
      if (reverse) {
        _findIndex = (_findIndex - 1 + _findHits.length) % _findHits.length;
      } else {
        _findIndex = (_findIndex + 1) % _findHits.length;
      }
    });
    _selectFindHit();
  }

  void _replaceOne() {
    final tab = _tab;
    if (tab == null || _findCtrl.text.isEmpty) return;
    final sel = tab.text.selection;
    final q = _findCtrl.text;
    if (sel.isValid &&
        !sel.isCollapsed &&
        tab.text.text.substring(sel.start, sel.end) == q) {
      final next = tab.text.text.replaceRange(sel.start, sel.end, _replaceCtrl.text);
      tab.text.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(
          offset: sel.start + _replaceCtrl.text.length,
        ),
      );
      _rebuildFindHits();
      setState(() {});
      _selectFindHit();
      return;
    }
    _findNext();
  }

  void _replaceAll() {
    final tab = _tab;
    final q = _findCtrl.text;
    if (tab == null || q.isEmpty) return;
    final next = tab.text.text.replaceAll(q, _replaceCtrl.text);
    tab.text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    _rebuildFindHits();
    setState(() {});
  }

  Future<void> _gotoLine() async {
    final tab = _tab;
    if (tab == null || !mounted) return;
    final ctrl = TextEditingController();
    final line = await showDialog<int>(
      context: context,
      builder: (ctx) {
        final wb = ctx.wb;
        return AlertDialog(
          backgroundColor: wb.panelElevated,
          title: Text('跳转到行', style: TextStyle(color: wb.primaryText)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            style: TextStyle(color: wb.primaryText),
            decoration: const InputDecoration(hintText: '行号'),
            onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v.trim())),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
              child: const Text('跳转'),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    if (line == null || line < 1) return;
    final text = tab.text.text;
    var offset = 0;
    var cur = 1;
    while (cur < line) {
      final i = text.indexOf('\n', offset);
      if (i < 0) {
        offset = text.length;
        break;
      }
      offset = i + 1;
      cur++;
    }
    tab.text.selection = TextSelection.collapsed(offset: offset);
    setState(() {});
  }

  void _onDrop(DropDoneDetails detail) {
    final paths = resolveDesktopDropPaths(detail);
    for (final raw in paths) {
      final path = _normalizePath(raw);
      if (path.isEmpty) continue;
      if (!_tryOpenPath(path)) {
        widget.wm.open(
          DesktopAppType.editor,
          args: {'path': path},
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final tab = _tab;

    if (_tabs.isEmpty) {
      return DropTarget(
        onDragDone: _onDrop,
        child: ColoredBox(
          color: wb.bg,
          child: Center(
            child: Text('拖入文件以打开', style: TextStyle(color: wb.textMuted)),
          ),
        ),
      );
    }

    if (tab == null) return const SizedBox.shrink();

    return DropTarget(
      onDragDone: _onDrop,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
              unawaited(_save()),
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
              unawaited(_save()),
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
            setState(() {
              _findOpen = true;
              _replaceMode = false;
            });
          },
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
            setState(() {
              _findOpen = true;
              _replaceMode = false;
            });
          },
          const SingleActivator(LogicalKeyboardKey.keyH, meta: true): () {
            setState(() {
              _findOpen = true;
              _replaceMode = true;
            });
          },
          const SingleActivator(LogicalKeyboardKey.keyH, control: true): () {
            setState(() {
              _findOpen = true;
              _replaceMode = true;
            });
          },
          const SingleActivator(LogicalKeyboardKey.keyG, meta: true): () =>
              _findNext(),
          const SingleActivator(LogicalKeyboardKey.keyG, control: true): () =>
              _findNext(),
          const SingleActivator(LogicalKeyboardKey.keyG, meta: true, shift: true):
              () => _findNext(reverse: true),
          const SingleActivator(
            LogicalKeyboardKey.keyG,
            control: true,
            shift: true,
          ): () => _findNext(reverse: true),
          const SingleActivator(LogicalKeyboardKey.keyL, meta: true): () =>
              unawaited(_gotoLine()),
          const SingleActivator(LogicalKeyboardKey.keyL, control: true): () =>
              unawaited(_gotoLine()),
        },
        child: Focus(
          autofocus: true,
          child: ColoredBox(
            color: wb.bg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_tabs.length > 1 || true)
                  Material(
                    color: wb.panelElevated,
                    child: SizedBox(
                      height: 34,
                      child: Row(
                        children: [
                          Expanded(
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: _tabs.length,
                              itemBuilder: (context, i) {
                                final t = _tabs[i];
                                final sel = i == _active;
                                return InkWell(
                                  onTap: () {
                                    setState(() => _active = i);
                                    _syncTitle();
                                  },
                                  child: Container(
                                    constraints: const BoxConstraints(
                                      maxWidth: 160,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border(
                                        bottom: BorderSide(
                                          color: sel
                                              ? wb.accentBlue
                                              : Colors.transparent,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            '${t.dirty ? '● ' : ''}${remoteBasename(t.path)}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: sel
                                                  ? wb.primaryText
                                                  : wb.secondaryText,
                                            ),
                                          ),
                                        ),
                                        InkWell(
                                          onTap: () => unawaited(_closeTab(i)),
                                          child: Icon(
                                            Icons.close,
                                            size: 14,
                                            color: wb.textMuted,
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
                Material(
                  color: wb.panel,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tab.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: wb.textMuted,
                            ),
                          ),
                        ),
                        if (tab.language != EditorLanguage.plain)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(
                              editorLanguageLabel(tab.language),
                              style: TextStyle(
                                fontSize: 11,
                                color: wb.textMuted,
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: '查找',
                          iconSize: 18,
                          onPressed: () => setState(() {
                            _findOpen = !_findOpen;
                            _replaceMode = false;
                          }),
                          icon: Icon(Icons.search_rounded, color: wb.textMuted),
                        ),
                        TextButton.icon(
                          onPressed:
                              _saving ? null : () => unawaited(_save()),
                          icon: _saving
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_rounded, size: 16),
                          label: const Text('保存'),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_findOpen)
                  Material(
                    color: wb.panelElevated,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _findCtrl,
                                  autofocus: true,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: wb.primaryText,
                                  ),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    hintText: '查找',
                                    hintStyle: TextStyle(color: wb.textMuted),
                                    border: const OutlineInputBorder(),
                                  ),
                                  onChanged: (_) {
                                    _rebuildFindHits();
                                    setState(() {});
                                    _selectFindHit();
                                  },
                                  onSubmitted: (_) => _findNext(),
                                ),
                              ),
                              TextButton(
                                onPressed: () => _findNext(reverse: true),
                                child: const Text('上一个'),
                              ),
                              TextButton(
                                onPressed: () => _findNext(),
                                child: const Text('下一个'),
                              ),
                              Text(
                                _findHits.isEmpty
                                    ? ''
                                    : '${_findIndex + 1}/${_findHits.length}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: wb.textMuted,
                                ),
                              ),
                              IconButton(
                                iconSize: 18,
                                onPressed: () =>
                                    setState(() => _findOpen = false),
                                icon: Icon(Icons.close, color: wb.textMuted),
                              ),
                            ],
                          ),
                          if (_replaceMode) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _replaceCtrl,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: wb.primaryText,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      hintText: '替换为',
                                      hintStyle:
                                          TextStyle(color: wb.textMuted),
                                      border: const OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: _replaceOne,
                                  child: const Text('替换'),
                                ),
                                TextButton(
                                  onPressed: _replaceAll,
                                  child: const Text('全部替换'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (tab.remoteChanged)
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
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
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
                            onPressed: () => unawaited(_load(tab)),
                            child: const Text('重新加载'),
                          ),
                          TextButton(
                            onPressed: () =>
                                setState(() => tab.remoteChanged = false),
                            child: const Text('忽略'),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (tab.syntaxIssue != null)
                  Material(
                    color: wb.folder.withValues(alpha: 0.18),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Text(
                        '语法错误 · ${tab.syntaxIssue!.displayMessage}',
                        style: TextStyle(color: wb.primaryText, fontSize: 13),
                      ),
                    ),
                  ),
                Expanded(child: _buildBody(tab, wb)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(_EditorTab tab, WorkbenchColors wb) {
    if (tab.loading) {
      return Center(child: CircularProgressIndicator(color: wb.accentBlue));
    }
    if (tab.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tab.error!, style: TextStyle(color: wb.textMuted)),
            TextButton(
              onPressed: () => unawaited(_load(tab)),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: TextField(
        controller: tab.text,
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
    );
  }
}
