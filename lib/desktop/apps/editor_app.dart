import 'dart:async';
import 'dart:convert';

import 'package:charset/charset.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/terminal_session_controller.dart';
import '../../services/remote_exec_capable.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../util/desktop_drop_paths.dart';
import '../../util/editor_highlight.dart';
import '../../util/editor_syntax.dart';
import '../../widgets/editor_find_bar.dart';
import '../../util/remote_paths.dart';
import '../desktop_tab_strip.dart';
import '../desktop_window_manager.dart';
import '../widgets/desktop_scrollable_actions.dart';

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
  final TerminalSessionController controller;

  @override
  State<EditorApp> createState() => _EditorAppState();
}

class _EditorTab implements DesktopTabModel {
  _EditorTab(this.path)
      : text = SyntaxEditingController(),
        focus = FocusNode(),
        find = EditorFindReplaceController(),
        scroll = ScrollController(),
        gutterScroll = ScrollController(),
        undo = UndoHistoryController(),
        dirty = false,
        tabKey = Object() {
    scroll.addListener(_syncGutter);
  }

  String path;
  @override
  final Object tabKey;
  final SyntaxEditingController text;
  final FocusNode focus;
  final EditorFindReplaceController find;
  final ScrollController scroll;
  final ScrollController gutterScroll;
  final UndoHistoryController undo;
  VoidCallback? _onFindChanged;
  bool applyingFindHits = false;
  String lastFindSourceText = '';
  int? remoteMtime;
  int? ignoredMtime;
  bool remoteChanged = false;
  @override
  bool dirty;
  bool suppressDirty = false;
  EditorSyntaxIssue? syntaxIssue;
  bool loading = true;
  String? error;
  bool readOnly = false;
  /// `utf-8`, `gbk`, or `binary/latin1` (lossless byte round-trip).
  String encoding = 'utf-8';
  bool crlf = false;
  bool hadUtf8Bom = false;
  String? encodingNote;
  /// Original remote bytes for「重新以编码打开」.
  Uint8List? sourceBytes;

  @override
  String get title => remoteBasename(path);

  @override
  bool get pinned => false;

  EditorLanguage get language => text.language;

  void _syncGutter() {
    if (!scroll.hasClients || !gutterScroll.hasClients) return;
    final target = scroll.offset.clamp(
      gutterScroll.position.minScrollExtent,
      gutterScroll.position.maxScrollExtent,
    );
    if ((gutterScroll.offset - target).abs() > 0.5) {
      gutterScroll.jumpTo(target);
    }
  }

  void dispose() {
    if (_onFindChanged != null) {
      find.removeListener(_onFindChanged!);
    }
    find.dispose();
    scroll.removeListener(_syncGutter);
    scroll.dispose();
    gutterScroll.dispose();
    undo.dispose();
    focus.dispose();
    text.dispose();
  }
}

class _DecodedEditorBytes {
  const _DecodedEditorBytes({
    required this.text,
    required this.encoding,
    required this.crlf,
    required this.hadUtf8Bom,
    this.encodingNote,
  });

  final String text;
  final String encoding;
  final bool crlf;
  final bool hadUtf8Bom;
  final String? encodingNote;
}

bool _isValidUtf8(List<int> bytes) {
  try {
    utf8.decode(bytes, allowMalformed: false);
    return true;
  } on FormatException {
    return false;
  }
}

_DecodedEditorBytes _decodeEditorBytes(Uint8List bytes) {
  var offset = 0;
  var hadUtf8Bom = false;
  String? forcedEncoding;

  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    offset = 3;
    hadUtf8Bom = true;
    forcedEncoding = 'utf-8';
  } else if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    // UTF-16 LE BOM — decode BMP + basic surrogates, edit as UTF-8 going forward.
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    var text = String.fromCharCodes(units);
    final crlf = text.contains('\r\n');
    if (crlf) text = text.replaceAll('\r\n', '\n');
    text = text.replaceAll('\r', '\n');
    return _DecodedEditorBytes(
      text: text,
      encoding: 'utf-8',
      crlf: crlf,
      hadUtf8Bom: false,
      encodingNote: '已从 UTF-16 LE 转换；保存将以 UTF-8 写入',
    );
  } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    var text = String.fromCharCodes(units);
    final crlf = text.contains('\r\n');
    if (crlf) text = text.replaceAll('\r\n', '\n');
    text = text.replaceAll('\r', '\n');
    return _DecodedEditorBytes(
      text: text,
      encoding: 'utf-8',
      crlf: crlf,
      hadUtf8Bom: false,
      encodingNote: '已从 UTF-16 BE 转换；保存将以 UTF-8 写入',
    );
  }

  final slice =
      offset == 0 ? bytes : Uint8List.sublistView(bytes, offset);
  final validUtf8 = forcedEncoding == 'utf-8' || _isValidUtf8(slice);
  late final String raw;
  late final String encoding;
  late final String? note;
  if (validUtf8) {
    raw = utf8.decode(slice);
    encoding = 'utf-8';
    note = null;
  } else {
    final picked = _pickNonUtf8Encoding(slice);
    raw = picked.text;
    encoding = picked.encoding;
    note = picked.encodingNote;
  }
  final crlf = raw.contains('\r\n');
  var text = crlf ? raw.replaceAll('\r\n', '\n') : raw;
  text = text.replaceAll('\r', '\n');
  return _DecodedEditorBytes(
    text: text,
    encoding: encoding,
    crlf: crlf,
    hadUtf8Bom: hadUtf8Bom,
    encodingNote: note,
  );
}

bool _hasCjk(String text) =>
    RegExp(r'[\u3400-\u9FFF\uF900-\uFAFF]').hasMatch(text);

_DecodedEditorBytes _pickNonUtf8Encoding(Uint8List slice) {
  final latin1Text = latin1.decode(slice);
  final highBit = slice.isEmpty
      ? 0.0
      : slice.where((b) => b > 0x7F).length / slice.length;

  String? gbkText;
  try {
    gbkText = gbk.decode(slice);
  } on FormatException {
    gbkText = null;
  }

  if (gbkText != null) {
    final plausible =
        _hasCjk(gbkText) || gbkText.length < latin1Text.length;
    // Prefer GBK when high-bit dense (typical multi-byte Chinese) or text looks Chinese.
    if (highBit > 0.3 || plausible) {
      return _DecodedEditorBytes(
        text: gbkText,
        encoding: 'gbk',
        crlf: false,
        hadUtf8Bom: false,
        encodingNote: '已按 GBK 打开',
      );
    }
  }

  return _DecodedEditorBytes(
    text: latin1Text,
    encoding: 'binary/latin1',
    crlf: false,
    hadUtf8Bom: false,
    encodingNote: '非 UTF-8，已按字节保留打开；保存将写回原字节映射',
  );
}

/// Re-decode stored bytes with an explicit encoding (no auto-detect).
_DecodedEditorBytes _decodeEditorBytesAs(
  Uint8List bytes,
  String encoding,
) {
  var offset = 0;
  var hadUtf8Bom = false;
  if (encoding == 'utf-8' &&
      bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    offset = 3;
    hadUtf8Bom = true;
  }
  final slice =
      offset == 0 ? bytes : Uint8List.sublistView(bytes, offset);

  late final String raw;
  late final String resolved;
  late final String? note;
  switch (encoding) {
    case 'gbk':
      raw = gbk.decode(slice);
      resolved = 'gbk';
      note = '已按 GBK 打开';
    case 'binary/latin1':
      raw = latin1.decode(slice);
      resolved = 'binary/latin1';
      note = '非 UTF-8，已按字节保留打开；保存将写回原字节映射';
    default:
      raw = utf8.decode(slice, allowMalformed: true);
      resolved = 'utf-8';
      note = null;
  }
  final crlf = raw.contains('\r\n');
  var text = crlf ? raw.replaceAll('\r\n', '\n') : raw;
  text = text.replaceAll('\r', '\n');
  return _DecodedEditorBytes(
    text: text,
    encoding: resolved,
    crlf: crlf,
    hadUtf8Bom: hadUtf8Bom,
    encodingNote: note,
  );
}

Uint8List _encodeEditorText(_EditorTab tab) {
  var body = tab.text.text;
  if (tab.crlf) {
    body = body.replaceAll('\n', '\r\n');
  }
  final List<int> encoded;
  if (tab.encoding == 'binary/latin1') {
    encoded = latin1.encode(body);
  } else if (tab.encoding == 'gbk') {
    encoded = gbk.encode(body);
  } else {
    encoded = utf8.encode(body);
  }
  return Uint8List.fromList(encoded);
}

String _encodingStatusLabel(String encoding) {
  switch (encoding) {
    case 'gbk':
      return 'GBK';
    case 'binary/latin1':
      return 'latin1';
    default:
      return 'UTF-8';
  }
}

class _EditorAppState extends State<EditorApp> {
  SshWorkspaceController get _ssh => widget.controller as SshWorkspaceController;

  final List<_EditorTab> _tabs = [];
  int _active = 0;
  Timer? _poll;
  Timer? _syntaxDebounce;
  bool _saving = false;

  bool _wrapLines = true;

  static const _lineHeight = 13.0 * 1.35;
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
    var any = false;
    for (final tab in List<_EditorTab>.from(_tabs)) {
      if (!mounted) return;
      try {
        final t = await _mtimeAbsolute(tab.path);
        if (!mounted || t == null) continue;
        if (tab.remoteMtime != null &&
            t > tab.remoteMtime! &&
            t != tab.ignoredMtime) {
          if (!tab.remoteChanged) {
            tab.remoteChanged = true;
            any = true;
          }
        } else {
          tab.remoteMtime ??= t;
        }
      } catch (_) {}
    }
    if (any && mounted) setState(() {});
  }

  void _reorderTabs(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final tab = _tabs.removeAt(oldIndex);
      _tabs.insert(newIndex, tab);
      if (_active == oldIndex) {
        _active = newIndex;
      } else if (oldIndex < _active && newIndex >= _active) {
        _active--;
      } else if (oldIndex > _active && newIndex <= _active) {
        _active++;
      }
    });
  }

  void _activateTab(int i) {
    if (i < 0 || i >= _tabs.length || i == _active) return;
    setState(() => _active = i);
    _syncTitle();
    final tab = _tab;
    if (tab != null && tab.find.open) {
      tab.find.rebuildHits();
      tab.find.applyCurrent();
    }
  }

  Future<void> _ignoreRemoteChange(_EditorTab tab) async {
    try {
      final t = await _mtimeAbsolute(tab.path);
      if (!mounted) return;
      setState(() {
        if (t != null) {
          tab.remoteMtime = t;
          tab.ignoredMtime = t;
        }
        tab.remoteChanged = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => tab.remoteChanged = false);
    }
  }

  String _normalizePath(String raw) {
    if (raw.isEmpty) return '';
    if (isRemoteAbsolutePath(raw)) return normalizeRemotePath(raw);
    return remoteJoin(_ssh.remoteCwd, raw);
  }

  bool _tryOpenPath(String raw) {
    final path = _normalizePath(raw);
    if (path.isEmpty) return false;
    final i = _tabs.indexWhere((t) => t.path == path);
    if (i >= 0) {
      _activateTab(i);
      widget.wm.focus(widget.window.id);
      return true;
    }
    if (_tabs.length >= _maxTabs) return false;
    unawaited(_addTab(path));
    widget.wm.focus(widget.window.id);
    return true;
  }

  Future<void> _promptOpenPath() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => const _EditorPathPromptDialog(
        title: '打开文件',
        confirmLabel: '打开',
      ),
    );
    if (raw == null || raw.isEmpty || !mounted) return;
    if (!_tryOpenPath(raw)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开（标签已满或路径无效）')),
      );
    }
  }

  Future<void> _promptSaveAs() async {
    final tab = _tab;
    if (tab == null) return;
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => _EditorPathPromptDialog(
        title: '另存为',
        confirmLabel: '保存',
        initialValue: tab.path,
      ),
    );
    if (raw == null || raw.isEmpty || !mounted) return;
    final path = _normalizePath(raw);
    if (path.isEmpty) return;
    setState(() => tab.path = path);
    _syncTitle();
    await _save(target: tab, clearReadOnlyOnSuccess: true);
  }

  Future<void> _addTab(String path) async {
    final tab = _EditorTab(path);
    tab.focus.onKeyEvent = (node, event) => _onEditorKey(tab, event);
    tab.text.addListener(() => _onTextChanged(tab));
    tab.find.getText = () => tab.text.text;
    tab.find.onApplySelection = (hit) => _applyFindHit(tab, hit);
    tab.find.onReplace = (hit, replacement) =>
        _replaceHit(tab, hit, replacement);
    tab.find.onSetText = (text, sel) {
      tab.text.value = TextEditingValue(text: text, selection: sel);
    };
    tab.find.onMessage = (msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    };
    tab._onFindChanged = () => _onFindChanged(tab);
    tab.find.addListener(tab._onFindChanged!);
    setState(() {
      _tabs.add(tab);
      _active = _tabs.length - 1;
    });
    await _load(tab);
  }

  KeyEventResult _onEditorKey(_EditorTab tab, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (tab.readOnly) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.tab) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        editorOutdent(tab.text);
      } else {
        editorInsertIndent(tab.text);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _insertNewlineWithIndent(tab);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onTextChanged(_EditorTab tab) {
    if (tab.applyingFindHits) return;
    if (!tab.suppressDirty && !tab.dirty) {
      setState(() => tab.dirty = true);
      _syncTitle();
    } else if (identical(tab, _tab) && mounted) {
      setState(() {});
    }
    if (identical(tab, _tab)) _scheduleSyntaxCheck(tab);
    if (tab.find.open && tab.text.text != tab.lastFindSourceText) {
      tab.lastFindSourceText = tab.text.text;
      tab.find.rebuildHits();
    }
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
                  await _save(target: t);
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
                await _save(target: tab);
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
    } else {
      final tab = _tab;
      if (tab != null && tab.find.open) {
        tab.find.rebuildHits();
        tab.find.applyCurrent();
      }
    }
  }

  Future<({Uint8List bytes, bool readOnly})?> _readAbsolute(String path) async {
    final client = _ssh.sftp;
    if (client == null) return null;
    final file = await client.open(path, mode: SftpFileOpenMode.read);
    try {
      final stat = await file.stat();
      final size = stat.size ?? 0;
      if (size > kMaxEditorBytes) {
        throw StateError('文件过大（$size 字节），上限为 $kMaxEditorBytes 字节');
      }
      final mode = stat.mode;
      final readOnly = mode != null && !mode.userWrite;
      final bytes = await file.readBytes();
      return (bytes: bytes, readOnly: readOnly);
    } finally {
      await file.close();
    }
  }

  Future<void> _writeAbsolute(String path, Uint8List bytes) async {
    final client = _ssh.sftp;
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
    final client = _ssh.sftp;
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
      if (!widget.controller.connected || _ssh.sftp == null) {
        setState(() {
          tab.loading = false;
          tab.error = '未连接';
        });
        return;
      }
      final loaded = await _readAbsolute(tab.path);
      if (!mounted) return;
      if (loaded == null) {
        setState(() {
          tab.loading = false;
          tab.error = '无法读取文件';
        });
        return;
      }
      final bytes = loaded.bytes;
      if (!looksLikeTextBytes(bytes)) {
        setState(() {
          tab.loading = false;
          tab.error = '看起来不是文本文件';
        });
        return;
      }
      final decoded = _decodeEditorBytes(bytes);
      tab.sourceBytes = bytes;
      tab.encoding = decoded.encoding;
      tab.crlf = decoded.crlf;
      tab.hadUtf8Bom = decoded.hadUtf8Bom;
      tab.encodingNote = decoded.encodingNote;
      tab.readOnly = loaded.readOnly;
      tab.text.language = editorLanguageFromPath(tab.path);
      tab.suppressDirty = true;
      tab.text.value = TextEditingValue(
        text: decoded.text,
        selection: TextSelection.collapsed(offset: decoded.text.length),
      );
      tab.suppressDirty = false;
      _runSyntaxCheckNow(tab);
      tab.remoteMtime = await _mtimeAbsolute(tab.path);
      tab.ignoredMtime = null;
      setState(() {
        tab.loading = false;
        tab.dirty = false;
        tab.remoteChanged = false;
      });
      _syncTitle();
      if (tab.find.open && identical(tab, _tab)) {
        tab.find.rebuildHits();
        tab.find.applyCurrent();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        tab.loading = false;
        tab.error = '$e';
      });
    }
  }

  Future<void> _checkRemote() async {
    if (!mounted || _saving || _tabs.isEmpty) return;
    if (!widget.controller.connected) return;
    var any = false;
    for (final tab in List<_EditorTab>.from(_tabs)) {
      if (tab.loading) continue;
      try {
        final t = await _mtimeAbsolute(tab.path);
        if (!mounted || t == null) continue;
        if (tab.remoteMtime != null &&
            t > tab.remoteMtime! &&
            t != tab.ignoredMtime) {
          if (!tab.remoteChanged) {
            tab.remoteChanged = true;
            any = true;
          }
        }
      } catch (_) {}
    }
    if (any && mounted) setState(() {});
  }

  Future<bool> _save({
    _EditorTab? target,
    bool clearReadOnlyOnSuccess = false,
  }) async {
    final tab = target ?? _tab;
    if (tab == null) return false;
    setState(() => _saving = true);
    try {
      final bytes = _encodeEditorText(tab);
      if (bytes.length > kMaxEditorBytes) {
        throw StateError('内容超过上限 $kMaxEditorBytes 字节');
      }
      await _writeAbsolute(tab.path, bytes);
      tab.remoteMtime = await _mtimeAbsolute(tab.path);
      tab.ignoredMtime = null;
      if (!mounted) return false;
      setState(() {
        tab.dirty = false;
        tab.remoteChanged = false;
        if (clearReadOnlyOnSuccess) tab.readOnly = false;
      });
      _syncTitle();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _forceUtf8Save(_EditorTab tab) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final wb = ctx.wb;
        return AlertDialog(
          backgroundColor: wb.panelElevated,
          title: Text('以 UTF-8 保存？', style: TextStyle(color: wb.primaryText)),
          content: Text(
            '当前按字节保留打开。强制 UTF-8 可能改变非 ASCII 字节。',
            style: TextStyle(color: wb.secondaryText),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('强制 UTF-8'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    setState(() {
      tab.encoding = 'utf-8';
      tab.encodingNote = null;
    });
    await _save(target: tab);
  }

  Future<void> _reopenWithEncoding(String encoding) async {
    final tab = _tab;
    if (tab == null) return;
    final bytes = tab.sourceBytes;
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无原始字节，请重新加载文件')),
      );
      return;
    }
    if (tab.dirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final wb = ctx.wb;
          return AlertDialog(
            backgroundColor: wb.panelElevated,
            title: Text(
              '重新以编码打开？',
              style: TextStyle(color: wb.primaryText),
            ),
            content: Text(
              '当前有未保存更改，重新打开将丢失这些更改。',
              style: TextStyle(color: wb.secondaryText),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('继续'),
              ),
            ],
          );
        },
      );
      if (ok != true || !mounted) return;
    }
    try {
      final decoded = _decodeEditorBytesAs(bytes, encoding);
      tab.encoding = decoded.encoding;
      tab.crlf = decoded.crlf;
      tab.hadUtf8Bom = decoded.hadUtf8Bom;
      tab.encodingNote = decoded.encodingNote;
      tab.suppressDirty = true;
      tab.text.value = TextEditingValue(
        text: decoded.text,
        selection: TextSelection.collapsed(offset: decoded.text.length),
      );
      tab.suppressDirty = false;
      _runSyntaxCheckNow(tab);
      setState(() => tab.dirty = false);
      _syncTitle();
      if (tab.find.open) {
        tab.find.rebuildHits();
        tab.find.applyCurrent();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法以该编码打开：$e')),
      );
    }
  }

  void _onFindChanged(_EditorTab tab) {
    tab.applyingFindHits = true;
    try {
      if (tab.find.open) {
        tab.text.setFindHits(tab.find.hitRanges, currentIndex: tab.find.index);
      } else {
        tab.text.clearFindHits();
      }
    } finally {
      tab.applyingFindHits = false;
    }
    if (identical(tab, _tab) && mounted) setState(() {});
  }

  void _applyFindHit(_EditorTab tab, EditorFindHit hit) {
    tab.text.selection = TextSelection(
      baseOffset: hit.start,
      extentOffset: hit.end,
    );
    _scrollToLine(tab, editorLineOfOffset(tab.text.text, hit.start));
    if (mounted) setState(() {});
  }

  void _replaceHit(_EditorTab tab, EditorFindHit hit, String replacement) {
    editorReplaceHit(tab.text, hit, replacement);
  }

  void _scrollToLine(_EditorTab tab, int line) {
    if (!tab.scroll.hasClients) return;
    final target = ((line - 1) * _lineHeight).clamp(
      tab.scroll.position.minScrollExtent,
      tab.scroll.position.maxScrollExtent,
    );
    tab.scroll.jumpTo(target);
    tab._syncGutter();
  }

  void _jumpToLine(_EditorTab tab, int line) {
    if (line < 1) return;
    final offset = editorLineStartOffset(tab.text.text, line);
    tab.text.selection = TextSelection.collapsed(offset: offset);
    _scrollToLine(tab, line);
    if (mounted) setState(() {});
  }

  Future<void> _gotoLine() async {
    final tab = _tab;
    if (tab == null || !mounted) return;
    final line = await showGotoLineDialog(context);
    if (line == null || line < 1 || !mounted) return;
    _jumpToLine(tab, line);
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('拖入文件以打开', style: TextStyle(color: wb.textMuted)),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () => unawaited(_promptOpenPath()),
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: const Text('打开'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (tab == null) return const SizedBox.shrink();

    return DropTarget(
      onDragDone: _onDrop,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
            if (_tab?.readOnly == true) return;
            unawaited(_save());
          },
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (_tab?.readOnly == true) return;
            unawaited(_save());
          },
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
            tab.find.setOpen(true);
          },
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
            tab.find.setOpen(true);
          },
          const SingleActivator(LogicalKeyboardKey.keyH, meta: true): () {
            tab.find.setOpen(true, replace: true);
          },
          const SingleActivator(LogicalKeyboardKey.keyH, control: true): () {
            tab.find.setOpen(true, replace: true);
          },
          const SingleActivator(LogicalKeyboardKey.keyG, meta: true): () =>
              tab.find.findNext(),
          const SingleActivator(LogicalKeyboardKey.keyG, control: true): () =>
              tab.find.findNext(),
          const SingleActivator(LogicalKeyboardKey.keyG, meta: true, shift: true):
              () => tab.find.findNext(reverse: true),
          const SingleActivator(
            LogicalKeyboardKey.keyG,
            control: true,
            shift: true,
          ): () => tab.find.findNext(reverse: true),
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
                Material(
                  color: wb.panelElevated,
                  child: DesktopTabStrip<_EditorTab>(
                    tabs: _tabs,
                    activeIndex: _active,
                    maxTabs: _maxTabs,
                    onSelect: _activateTab,
                    onClose: (i) => unawaited(_closeTab(i)),
                    onReorder: _reorderTabs,
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
                        Flexible(
                          child: DesktopScrollableActions(
                            children: [
                              if (tab.readOnly)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Chip(
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    padding: EdgeInsets.zero,
                                    label: Text(
                                      '只读',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: wb.textMuted,
                                      ),
                                    ),
                                    backgroundColor: wb.panelElevated,
                                    side: BorderSide(color: wb.border),
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
                                onPressed: () =>
                                    tab.find.setOpen(!tab.find.open),
                                icon: Icon(
                                  Icons.search_rounded,
                                  color: wb.textMuted,
                                ),
                              ),
                              IconButton(
                                tooltip: _wrapLines ? '关闭自动换行' : '开启自动换行',
                                iconSize: 18,
                                onPressed: () =>
                                    setState(() => _wrapLines = !_wrapLines),
                                icon: Icon(
                                  _wrapLines
                                      ? Icons.wrap_text_rounded
                                      : Icons.notes_rounded,
                                  color: _wrapLines
                                      ? wb.accentBlue
                                      : wb.textMuted,
                                ),
                              ),
                              TextButton(
                                onPressed: () => unawaited(_promptOpenPath()),
                                child: const Text('打开'),
                              ),
                              TextButton(
                                onPressed: _saving
                                    ? null
                                    : () => unawaited(_promptSaveAs()),
                                child: const Text('另存为'),
                              ),
                              TextButton.icon(
                                onPressed: _saving || tab.readOnly
                                    ? null
                                    : () => unawaited(_save()),
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
                              TextButton.icon(
                                onPressed: () {
                                  widget.wm.open(
                                    DesktopAppType.terminal,
                                    args: {
                                      'cwd': remoteDirname(tab.path),
                                    },
                                  );
                                },
                                icon: const Icon(
                                  Icons.terminal_rounded,
                                  size: 16,
                                ),
                                label: const Text('终端'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (tab.find.open) EditorFindBar(controller: tab.find),
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
                                unawaited(_ignoreRemoteChange(tab)),
                            child: const Text('忽略'),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (tab.encodingNote != null)
                  Material(
                    color: wb.folder.withValues(alpha: 0.18),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              tab.encodingNote!,
                              style: TextStyle(
                                color: wb.primaryText,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          if (tab.encoding == 'binary/latin1')
                            TextButton(
                              onPressed: () =>
                                  unawaited(_forceUtf8Save(tab)),
                              child: const Text('强制 UTF-8 保存'),
                            ),
                          IconButton(
                            tooltip: '关闭提示',
                            iconSize: 16,
                            onPressed: () =>
                                setState(() => tab.encodingNote = null),
                            icon: Icon(
                              Icons.close,
                              size: 16,
                              color: wb.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (tab.syntaxIssue != null)
                  Material(
                    color: wb.folder.withValues(alpha: 0.18),
                    child: Builder(
                      builder: (context) {
                        final issueLine = tab.syntaxIssue?.line;
                        return InkWell(
                          onTap: issueLine == null
                              ? null
                              : () => _jumpToLine(tab, issueLine),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '语法错误 · ${tab.syntaxIssue!.displayMessage}',
                                    style: TextStyle(
                                      color: wb.primaryText,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.keyboard_arrow_right_rounded,
                                  size: 18,
                                  color: wb.textMuted,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                Expanded(child: _buildBody(tab, wb)),
                Material(
                  color: wb.panelElevated,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: DesktopHScrollRow(
                      children: [
                        Text(
                          _caretLabel(tab),
                          style: TextStyle(
                            color: wb.secondaryText,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(width: 12),
                        PopupMenuButton<String>(
                          tooltip: '重新以编码打开',
                          onSelected: (v) =>
                              unawaited(_reopenWithEncoding(v)),
                          itemBuilder: (ctx) => [
                            PopupMenuItem(
                              value: 'utf-8',
                              enabled: tab.encoding != 'utf-8',
                              child: Text(
                                tab.encoding == 'utf-8'
                                    ? 'UTF-8（当前）'
                                    : '重新以 UTF-8 打开',
                              ),
                            ),
                            PopupMenuItem(
                              value: 'gbk',
                              enabled: tab.encoding != 'gbk',
                              child: Text(
                                tab.encoding == 'gbk'
                                    ? 'GBK（当前）'
                                    : '重新以 GBK 打开',
                              ),
                            ),
                            PopupMenuItem(
                              value: 'binary/latin1',
                              enabled: tab.encoding != 'binary/latin1',
                              child: Text(
                                tab.encoding == 'binary/latin1'
                                    ? 'latin1（当前）'
                                    : '重新以 latin1 打开',
                              ),
                            ),
                          ],
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'encoding: ${_encodingStatusLabel(tab.encoding)}',
                                style: TextStyle(
                                  color: wb.textMuted,
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '编码',
                                style: TextStyle(
                                  color: wb.accentBlue,
                                  fontSize: 11,
                                ),
                              ),
                              Icon(
                                Icons.arrow_drop_down,
                                size: 14,
                                color: wb.accentBlue,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          tab.crlf ? 'CRLF' : 'LF',
                          style: TextStyle(
                            color: wb.textMuted,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                        if (tab.hadUtf8Bom) ...[
                          const SizedBox(width: 12),
                          Text(
                            'BOM stripped',
                            style: TextStyle(
                              color: wb.textMuted,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _caretLabel(_EditorTab tab) {
    final text = tab.text.text;
    final offset = tab.text.selection.baseOffset.clamp(0, text.length);
    var line = 1;
    var col = 1;
    for (var i = 0; i < offset; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        line++;
        col = 1;
      } else {
        col++;
      }
    }
    final sel = tab.text.selection;
    final selected = sel.isValid && !sel.isCollapsed
        ? ' · 已选 ${sel.end - sel.start}'
        : '';
    return '行 $line, 列 $col$selected';
  }

  void _insertNewlineWithIndent(_EditorTab tab) {
    final value = tab.text.value;
    final sel = value.selection;
    if (!sel.isValid) return;
    final text = value.text;
    var lineStart = sel.start;
    while (lineStart > 0 && text[lineStart - 1] != '\n') {
      lineStart--;
    }
    final buf = StringBuffer();
    var i = lineStart;
    while (i < text.length) {
      final c = text[i];
      if (c == ' ' || c == '\t') {
        buf.write(c);
        i++;
      } else {
        break;
      }
    }
    final insert = '\n${buf.toString()}';
    final start = sel.start;
    final end = sel.end;
    final next = text.replaceRange(start, end, insert);
    tab.text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + insert.length),
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
    final lineCount = '\n'.allMatches(tab.text.text).length + 1;
    final gutterWidth = (28.0 + (lineCount.toString().length * 7)).clamp(
      36.0,
      64.0,
    );
    const style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.35,
    );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: wb.panel,
          border: Border.all(color: wb.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final editorWidth = (constraints.maxWidth - gutterWidth - 8)
                .clamp(120.0, double.infinity);
            var contentWidth = editorWidth;
            if (!_wrapLines) {
              var longest = 0;
              for (final line in tab.text.text.split('\n')) {
                if (line.length > longest) longest = line.length;
              }
              contentWidth = (longest * 7.8 + 24).clamp(editorWidth, 20000.0);
            }
            final field = TextField(
              controller: tab.text,
              focusNode: tab.focus,
              scrollController: tab.scroll,
              undoController: tab.undo,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              readOnly: tab.readOnly,
              style: style.copyWith(color: wb.primaryText),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isCollapsed: true,
                contentPadding: EdgeInsets.fromLTRB(0, 12, 12, 12),
              ),
            );
            final gutter = ListenableBuilder(
              listenable: tab.gutterScroll,
              builder: (context, _) {
                return SingleChildScrollView(
                  controller: tab.gutterScroll,
                  primary: false,
                  physics: const NeverScrollableScrollPhysics(),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
                    child: Text(
                      [
                        for (var i = 1; i <= lineCount; i++) '$i',
                      ].join('\n'),
                      textAlign: TextAlign.right,
                      style: style.copyWith(color: wb.textMuted),
                    ),
                  ),
                );
              },
            );
            final row = Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: gutterWidth,
                  child: gutter,
                ),
                const SizedBox(width: 8),
                // Expanded fits within scroll padding; fixed width ignored it and overflowed.
                if (_wrapLines)
                  Expanded(child: field)
                else
                  SizedBox(width: contentWidth, child: field),
              ],
            );
            Widget body = row;
            if (!_wrapLines) {
              body = SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: body,
              );
            }
            return body;
          },
        ),
      ),
    );
  }
}

/// Owns [TextEditingController] so it survives the dialog route exit animation.
class _EditorPathPromptDialog extends StatefulWidget {
  const _EditorPathPromptDialog({
    required this.title,
    required this.confirmLabel,
    this.initialValue,
  });

  final String title;
  final String confirmLabel;
  final String? initialValue;

  @override
  State<_EditorPathPromptDialog> createState() =>
      _EditorPathPromptDialogState();
}

class _EditorPathPromptDialogState extends State<_EditorPathPromptDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _ctrl.text.trim());

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return AlertDialog(
      backgroundColor: wb.panelElevated,
      title: Text(widget.title, style: TextStyle(color: wb.primaryText)),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        style: TextStyle(
          fontFamily: 'monospace',
          color: wb.primaryText,
        ),
        decoration: InputDecoration(
          hintText: '远端绝对路径',
          hintStyle: TextStyle(color: wb.textMuted),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
