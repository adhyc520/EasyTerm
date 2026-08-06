import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../l10n/app_localizations.dart';
import '../screens/remote_editor_screen.dart';
import '../services/desktop_sftp_controller.dart';
import '../services/sftp_browser_host.dart';
import '../services/sftp_fs_transfer.dart' as sftp_transfer;
import '../services/sftp_planned_upload.dart';
import '../services/sftp_upload_task_list.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_desktop_shortcuts.dart';
import '../theme/workbench_theme.dart';
import '../util/remote_paths.dart';
import 'sftp_folder_delayed_draggable.dart';

String _formatRemoteBytes(int? bytes) {
  if (bytes == null) return '—';
  return _formatByteCount(bytes);
}

String _formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const u = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v < 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(0)} ${u[i]}';
}

String _z2(int n) => n.toString().padLeft(2, '0');

bool _sftpDesktopDragOutSupported() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}

const SimpleFileFormat _kSftpGenericFileDragFormat = SimpleFileFormat(
  uniformTypeIdentifiers: ['public.data'],
  mimeTypes: ['application/octet-stream'],
);

FileFormat _sftpDragFileFormatForName(String filename) {
  switch (p.extension(filename).toLowerCase()) {
    case '.txt':
    case '.log':
    case '.md':
    case '.csv':
    case '.tsv':
      return Formats.plainTextFile;
    case '.json':
      return Formats.json;
    case '.html':
    case '.htm':
      return Formats.htmlFile;
    case '.png':
      return Formats.png;
    case '.jpg':
    case '.jpeg':
      return Formats.jpeg;
    case '.gif':
      return Formats.gif;
    case '.webp':
      return Formats.webp;
    case '.svg':
      return Formats.svg;
    case '.pdf':
      return Formats.pdf;
    case '.zip':
      return Formats.zip;
    case '.gz':
      return Formats.gzip;
    case '.tar':
      return Formats.tar;
    default:
      return _kSftpGenericFileDragFormat;
  }
}

String _formatUnixMtime(int? sec, bool useBeijingWallClock) {
  if (sec == null) return '—';
  final utc = DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true);
  final d = useBeijingWallClock
      ? utc.add(const Duration(hours: 8))
      : utc.toLocal();
  return '${d.year}-${_z2(d.month)}-${_z2(d.day)} ${_z2(d.hour)}:${_z2(d.minute)}';
}

/// (显示名, 绝对路径)
List<({String label, String path})> _breadcrumbSegments(
  String cwd,
  String rootLabel,
) {
  final normalized = cwd.replaceAll('\\', '/');
  if (normalized.isEmpty || normalized == '/') {
    return [(label: rootLabel, path: '/')];
  }
  final parts = normalized.split('/').where((e) => e.isNotEmpty).toList();
  final out = <({String label, String path})>[];
  out.add((label: rootLabel, path: '/'));
  var acc = '';
  for (final part in parts) {
    acc = '$acc/$part';
    out.add((label: part, path: acc));
  }
  return out;
}

void _showEntryContextMenu(
  BuildContext context,
  Offset globalPosition, {
  required Future<void> Function() onDownload,
  required Future<void> Function() onDelete,
  Future<void> Function()? onOpenInEditor,
}) {
  final l = AppLocalizations.of(context)!;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final topLeft = overlay.localToGlobal(Offset.zero);
  final rel = RelativeRect.fromLTRB(
    globalPosition.dx - topLeft.dx,
    globalPosition.dy - topLeft.dy,
    globalPosition.dx - topLeft.dx + 1,
    globalPosition.dy - topLeft.dy + 1,
  );
  showMenu<String>(
    context: context,
    position: rel,
    items: [
      if (onOpenInEditor != null)
        PopupMenuItem(value: 'open', child: Text(l.sftpOpenInEditorMenu)),
      PopupMenuItem(value: 'dl', child: Text(l.sftpDownloadMenu)),
      PopupMenuItem(
        value: 'del',
        child: Text(
          l.sftpDeleteMenu,
          style: TextStyle(color: Colors.red.shade300),
        ),
      ),
    ],
  ).then((v) async {
    if (v == 'open' && onOpenInEditor != null) await onOpenInEditor();
    if (v == 'dl') await onDownload();
    if (v == 'del') await onDelete();
  });
}

class _SelectAllIntent extends Intent {
  const _SelectAllIntent();
}

class _ClearSelectionIntent extends Intent {
  const _ClearSelectionIntent();
}

class _DeleteSelectionIntent extends Intent {
  const _DeleteSelectionIntent();
}

bool _sftpMetaOrControlPressed() {
  final kb = HardwareKeyboard.instance;
  return kb.isControlPressed || kb.isMetaPressed;
}

bool _sftpShiftPressed() => HardwareKeyboard.instance.isShiftPressed;

/// 在原生拖放会话真正开始（[DataWriterItem.onRegistered]）后再标记内部拖放，
/// 避免准备数据失败或用户中途松手时 [SftpBrowser.isDraggingInternalItem] 一直为 true。
///
/// [tempPath] 给定时，会在 [item.onRegistered] 时登记到 [SshWorkspaceController]
/// 的活跃拖出集合里，并在 [item.onDisposed] 时移除。这样即便用户把刚拖出的文件 / 目录
/// 拖回到 SFTP 面板，也能被 [SshWorkspaceController.isPathFromRecentDragOut] 识别
/// 并跳过自上传。
void _trackSftpInternalDragItem(
  DragItem item, {
  String? tempPath,
  VoidCallback? onDisposed,
}) {
  item.onRegistered.addListener(() {
    SftpBrowser.isDraggingInternalItem = true;
    if (tempPath != null && tempPath.isNotEmpty) {
      SshWorkspaceController.registerDragTempPath(tempPath);
    }
  });
  item.onDisposed.addListener(() {
    SftpBrowser.isDraggingInternalItem = false;
    if (tempPath != null && tempPath.isNotEmpty) {
      SshWorkspaceController.unregisterDragTempPath(tempPath);
    }
    onDisposed?.call();
  });
}

/// 将远程文件或目录以系统原生拖放导出到 Finder / 资源管理器等。
/// 文件优先虚拟文件流式拉取；文件夹拖出使用延迟拖动 + 先快照再下载整棵树。
/// 右键菜单「下载」目录仍会弹出本机文件夹选择对话框。
class _SftpRemoteEntryDragWrap extends StatelessWidget {
  const _SftpRemoteEntryDragWrap({
    required this.controller,
    required this.relativeName,
    required this.isDirectory,
    required this.pickerContext,
    required this.child,
  });

  final SftpBrowserHost controller;
  final String relativeName;
  final bool isDirectory;

  /// 用于目录拖出时的文件夹选择对话框与 SnackBar（须为 [Navigator] 子树）。
  final BuildContext pickerContext;
  final Widget child;

  Future<DragItem?> _dragItemProvider(DragItemRequest request) async {
    final workspace = _workspaceForDrag(controller);
    if (workspace == null) return null;
    final client = workspace.sftp;
    if (client == null) return null;
    if (!pickerContext.mounted) return null;
    // 桌面独立 cwd：传绝对路径，工作区侧用 resolveRemotePath 识别。
    final dragName = remoteJoin(controller.remoteCwd, relativeName);
    final SftpFileAttrs st;
    try {
      st = await client.stat(dragName);
    } catch (_) {
      return null;
    }
    if (!pickerContext.mounted) return null;
    if (isDirectory) {
      return _buildDirectoryDragItem(request, st, workspace, dragName);
    }
    return _buildFileDragItem(st, workspace, dragName);
  }

  static SshWorkspaceController? _workspaceForDrag(SftpBrowserHost host) {
    if (host is SshWorkspaceController) return host;
    if (host is DesktopSftpController) return host.workspace;
    return null;
  }

  Future<DragItem?> _buildDirectoryDragItem(
    DragItemRequest request,
    SftpFileAttrs st,
    SshWorkspaceController workspace,
    String dragName,
  ) async {
    if (!st.isDirectory) return null;
    final nameOnly = remoteBasename(relativeName);
    try {
      final tempPath = await workspace.startBackgroundDirectoryDragOut(
        dragName,
        shouldAbortBeforeStart: () =>
            sftpFolderDragShouldAbort(request.session),
      );
      if (!pickerContext.mounted) return null;
      if (sftpFolderDragShouldAbort(request.session)) return null;

      final item = DragItem(suggestedName: nameOnly);
      _trackSftpInternalDragItem(item, tempPath: tempPath);

      item.add(
        Formats.fileUri(
          Uri.file(
            tempPath,
            windows: defaultTargetPlatform == TargetPlatform.windows,
          ),
        ),
      );
      return item;
    } catch (_) {
      return null;
    }
  }

  Future<DragItem?> _buildFileDragItem(
    SftpFileAttrs st,
    SshWorkspaceController workspace,
    String dragName,
  ) async {
    if (st.isDirectory) return null;
    final nameOnly = remoteBasename(relativeName);
    final sizeBytes = st.size ?? 0;
    final probe = DragItem(suggestedName: nameOnly);
    if (!probe.virtualFileSupported) {
      try {
        final path = await workspace.materializeRemoteFileToTempForDrag(
          dragName,
        );
        final item = DragItem(suggestedName: nameOnly);
        _trackSftpInternalDragItem(
          item,
          tempPath: path,
          onDisposed: () => sftp_transfer.deleteLocalFileQuiet(path),
        );
        item.add(Formats.fileUri(Uri.file(path)));
        return item;
      } catch (_) {
        return null;
      }
    }
    final item = DragItem(suggestedName: nameOnly);
    _trackSftpInternalDragItem(item);

    final format = _sftpDragFileFormatForName(relativeName);
    item.addVirtualFile(
      format: format,
      provider: (sinkProvider, progress) {
        final sink = sinkProvider(fileSize: sizeBytes);
        unawaited(
          workspace.streamRemoteFileIntoDragSink(
            relativeName: dragName,
            fileSizeBytes: sizeBytes,
            sink: sink,
            progress: progress,
          ),
        );
      },
    );
    return item;
  }

  @override
  Widget build(BuildContext context) {
    if (isDirectory) {
      return PreSnapshotDragItemWidget(
        allowedOperations: () => [DropOperation.copy],
        dragItemProvider: _dragItemProvider,
        child: child,
      );
    }
    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy],
      dragItemProvider: _dragItemProvider,
      child: DraggableWidget(child: child),
    );
  }
}

class SftpBrowser extends StatefulWidget {
  const SftpBrowser({
    super.key,
    required this.controller,
    this.onOpenInEditor,
  });

  final SftpBrowserHost controller;

  /// 桌面模式：双击 / 菜单「打开」时回调；为 null 时走 [RemoteEditorScreen] 路由。
  final void Function(String fileName)? onOpenInEditor;

  /// 用于标记当前拖出的项目是否来源于 EasyTerm 内部。
  /// 当应用内发生拖出并在同一窗口释放时，避免被当成外部文件上传。
  static bool isDraggingInternalItem = false;

  @override
  State<SftpBrowser> createState() => _SftpBrowserState();
}

class _SftpBrowserState extends State<SftpBrowser> {
  bool _dropHighlight = false;
  bool _uploadQueueExpanded = false;
  final Set<String> _selectedNames = {};
  String? _anchorName;
  String? _selectionCwd;
  final FocusNode _focusNode = FocusNode(debugLabel: 'sftpBrowser');

  SftpBrowserHost get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _selectionCwd = _c.remoteCwd;
    _c.addListener(_onHostChanged);
  }

  @override
  void didUpdateWidget(covariant SftpBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onHostChanged);
      _selectionCwd = _c.remoteCwd;
      _selectedNames.clear();
      _anchorName = null;
      _c.addListener(_onHostChanged);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onHostChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onHostChanged() {
    if (!mounted) return;
    var dirty = false;
    if (_selectionCwd != _c.remoteCwd) {
      _selectionCwd = _c.remoteCwd;
      if (_selectedNames.isNotEmpty || _anchorName != null) {
        _selectedNames.clear();
        _anchorName = null;
        dirty = true;
      }
    } else if (_selectedNames.isNotEmpty) {
      final names = _c.entries.map((e) => e.filename).toSet();
      final before = _selectedNames.length;
      _selectedNames.removeWhere((n) => !names.contains(n));
      if (_anchorName != null && !names.contains(_anchorName)) {
        _anchorName = null;
        dirty = true;
      }
      if (_selectedNames.length != before) dirty = true;
    }
    if (dirty) setState(() {});
  }

  void _requestFocus() {
    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
  }

  void _clearSelection() {
    if (_selectedNames.isEmpty && _anchorName == null) return;
    setState(() {
      _selectedNames.clear();
      _anchorName = null;
    });
  }

  void _selectAll() {
    final names = _c.entries.map((e) => e.filename).toList();
    if (names.isEmpty) return;
    setState(() {
      _selectedNames
        ..clear()
        ..addAll(names);
      _anchorName = names.first;
    });
  }

  List<String> _selectedInListOrder() {
    return [
      for (final e in _c.entries)
        if (_selectedNames.contains(e.filename)) e.filename,
    ];
  }

  void _applySelectionTap(String name, {required bool additive, required bool range}) {
    final entries = _c.entries;
    final index = entries.indexWhere((e) => e.filename == name);
    if (index < 0) return;

    setState(() {
      if (range && _anchorName != null) {
        final anchor = entries.indexWhere((e) => e.filename == _anchorName);
        if (anchor >= 0) {
          final lo = index < anchor ? index : anchor;
          final hi = index < anchor ? anchor : index;
          final rangeNames = {
            for (var i = lo; i <= hi; i++) entries[i].filename,
          };
          if (additive) {
            _selectedNames.addAll(rangeNames);
          } else {
            _selectedNames
              ..clear()
              ..addAll(rangeNames);
          }
          return;
        }
      }

      if (additive) {
        if (_selectedNames.contains(name)) {
          _selectedNames.remove(name);
        } else {
          _selectedNames.add(name);
        }
        _anchorName = name;
        return;
      }

      _selectedNames
        ..clear()
        ..add(name);
      _anchorName = name;
    });
  }

  void _prepareSelectionForContextMenu(String name) {
    if (_selectedNames.contains(name)) return;
    setState(() {
      _selectedNames
        ..clear()
        ..add(name);
      _anchorName = name;
    });
  }

  SftpName? _entryByName(String name) {
    for (final e in _c.entries) {
      if (e.filename == name) return e;
    }
    return null;
  }

  Future<void> _downloadSelected(BuildContext context) async {
    final names = _selectedInListOrder();
    if (names.isEmpty) return;
    final l = AppLocalizations.of(context)!;
    try {
      if (names.length == 1) {
        final name = names.first;
        final e = _entryByName(name);
        if (e == null) return;
        await _downloadEntry(
          context,
          name,
          isDirectory: e.attr.isDirectory,
        );
        return;
      }

      final parent = await FilePicker.getDirectoryPath(
        dialogTitle: l.sftpPickDownloadDirTitle,
      );
      if (parent == null || !context.mounted) return;

      var okCount = 0;
      for (final name in names) {
        if (!context.mounted) return;
        final e = _entryByName(name);
        if (e == null) continue;
        if (e.attr.isDirectory) {
          await _c.downloadRemoteDirectoryToLocal(name, parent);
        } else {
          await _c.downloadRemoteFileToLocalPath(
            name,
            p.join(parent, remoteBasename(name)),
          );
        }
        okCount++;
      }
      if (context.mounted && okCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.sftpDownloadedMultiple(okCount))),
        );
      }
    } catch (err) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    }
  }

  Future<void> _downloadEntry(
    BuildContext context,
    String name, {
    required bool isDirectory,
  }) async {
    final l = AppLocalizations.of(context)!;
    try {
      if (isDirectory) {
        final parent = await FilePicker.getDirectoryPath(
          dialogTitle: l.sftpPickDirTitle,
        );
        if (parent == null || !context.mounted) return;
        await _c.downloadRemoteDirectoryToLocal(name, parent);
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.sftpDownloadedDir(name))));
        }
      } else {
        final out = await FilePicker.saveFile(
          dialogTitle: l.sftpSaveFileTitle,
          fileName: remoteBasename(name),
        );
        if (out == null || !context.mounted) return;
        await _c.downloadRemoteFileToLocalPath(name, out);
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.sftpDownloadedFile(name))));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _onLocalPathsDropped(
    BuildContext context,
    List<String> paths,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l = AppLocalizations.of(context)!;
    // 1) 先逐个检查覆盖冲突，收集可上传的路径。
    final validPaths = <String>[];
    for (final path in paths) {
      if (path.isEmpty) continue;
      try {
        final ok = await _checkOverwriteConflict(context, path);
        if (ok) validPaths.add(path);
      } catch (e) {
        messenger?.showSnackBar(
          SnackBar(content: Text(l.sftpUploadFailed('$e'))),
        );
      }
    }
    if (validPaths.isEmpty) return;
    // 2) 一次性批量上传。
    try {
      await _c.uploadMultipleLocalPaths(validPaths);
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text(l.sftpUploadFailed('$e'))),
      );
    }
  }

  /// 检查覆盖冲突并弹出确认对话框。
  /// 返回 true 表示可以上传，false 表示用户取消。
  Future<bool> _checkOverwriteConflict(
    BuildContext context,
    String localPath,
  ) async {
    if (kIsWeb) return false;
    final l = AppLocalizations.of(context)!;
    final conflict = await _c.inspectLocalUploadConflict(localPath);
    if (!context.mounted) return false;
    switch (conflict) {
      case SftpRemoteUploadConflict.typeMismatch:
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l.sftpUploadConflictTypeMismatchTitle),
            content: Text(
              l.sftpUploadConflictTypeMismatchBody(p.basename(localPath)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l.sftpCancel),
              ),
            ],
          ),
        );
        return false;
      case SftpRemoteUploadConflict.existsReplaceable:
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l.sftpUploadOverwriteTitle),
            content: Text(l.sftpUploadOverwriteBody(p.basename(localPath))),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l.sftpCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l.sftpUploadOverwriteConfirm),
              ),
            ],
          ),
        );
        if (ok != true || !context.mounted) return false;
        await _c.removeRemoteSubtreeForOverwrite(p.basename(localPath));
        return context.mounted;
      case SftpRemoteUploadConflict.none:
        return true;
    }
  }

  Future<void> _openOrEdit(
    BuildContext context,
    String name,
    SftpFileAttrs attr,
  ) async {
    final l = AppLocalizations.of(context)!;
    if (!attr.isFile) return;
    final external = widget.onOpenInEditor;
    if (external != null) {
      external(name);
      return;
    }
    final workspace = _c;
    if (workspace is! SshWorkspaceController) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.sftpBinaryNotOpened)),
      );
      return;
    }
    try {
      final bytes = await workspace.readRemoteFile(name);
      if (bytes == null || !context.mounted) return;
      if (!looksLikeTextBytes(bytes)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.sftpBinaryNotOpened)));
        return;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final mtime = await workspace.remoteMtime(name);
      if (!context.mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RemoteEditorScreen(
            controller: workspace,
            fileName: name,
            initialText: text,
            initialRemoteMtime: mtime,
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _confirmDeleteSelected(BuildContext context) async {
    final names = _selectedInListOrder();
    if (names.isEmpty) return;
    final l = AppLocalizations.of(context)!;
    final body = names.length == 1
        ? l.sftpDeleteConfirmBody(names.first)
        : l.sftpDeleteConfirmBodyMultiple(names.length);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.sftpDeleteConfirmTitle),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.sftpCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.sftpDeleteConfirm),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    for (final name in names) {
      if (!context.mounted) return;
      await _c.deleteRemote(name);
    }
    if (!mounted) return;
    setState(() {
      _selectedNames.clear();
      _anchorName = null;
    });
  }

  Future<void> _activateEntry(BuildContext context, SftpName e) async {
    if (e.attr.isDirectory) {
      if (_c.loadingDir) return;
      await _c.navigateInto(e.filename);
      return;
    }
    await _openOrEdit(context, e.filename, e.attr);
  }

  Map<ShortcutActivator, Intent> _shortcutMap() {
    return <ShortcutActivator, Intent>{
      for (final a in workbenchMetaOrControl(LogicalKeyboardKey.keyA))
        a: const _SelectAllIntent(),
      const SingleActivator(LogicalKeyboardKey.escape):
          const _ClearSelectionIntent(),
      const SingleActivator(LogicalKeyboardKey.delete):
          const _DeleteSelectionIntent(),
      const SingleActivator(LogicalKeyboardKey.backspace):
          const _DeleteSelectionIntent(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final l = AppLocalizations.of(context)!;
        final useBeijingMtime =
            Localizations.localeOf(context).languageCode == 'zh';
        final segs = _breadcrumbSegments(_c.remoteCwd, l.sftpBreadcrumbRoot);
        return Shortcuts(
          shortcuts: _shortcutMap(),
          child: Actions(
            actions: {
              _SelectAllIntent: CallbackAction<_SelectAllIntent>(
                onInvoke: (_) {
                  _selectAll();
                  return null;
                },
              ),
              _ClearSelectionIntent: CallbackAction<_ClearSelectionIntent>(
                onInvoke: (_) {
                  _clearSelection();
                  return null;
                },
              ),
              _DeleteSelectionIntent: CallbackAction<_DeleteSelectionIntent>(
                onInvoke: (_) {
                  if (_selectedNames.isNotEmpty) {
                    unawaited(_confirmDeleteSelected(context));
                  }
                  return null;
                },
              ),
            },
            child: Focus(
              focusNode: _focusNode,
              child: SizedBox.expand(
                child: Material(
                  color: context.wb.panel,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 10, 4, 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (var i = 0; i < segs.length; i++) ...[
                                      if (i > 0)
                                        Text(
                                          ' / ',
                                          style: TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11,
                                            color: context.wb.textMuted,
                                          ),
                                        ),
                                      InkWell(
                                        onTap: _c.loadingDir
                                            ? null
                                            : () {
                                                _c.navigateToAbsolutePath(
                                                  segs[i].path,
                                                );
                                              },
                                        borderRadius: BorderRadius.circular(4),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                            vertical: 2,
                                          ),
                                          child: Text(
                                            segs[i].label,
                                            style: TextStyle(
                                              fontFamily: 'monospace',
                                              fontSize: 11,
                                              color: context.wb.accentBlue,
                                              decoration:
                                                  TextDecoration.underline,
                                              decorationColor:
                                                  context.wb.accentBlue,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            if (_selectedNames.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Text(
                                  l.sftpSelectionCount(_selectedNames.length),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: context.wb.textMuted,
                                  ),
                                ),
                              ),
                            IconButton(
                              tooltip: l.sftpRefreshTooltip,
                              iconSize: 18,
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 30,
                                minHeight: 30,
                              ),
                              padding: EdgeInsets.zero,
                              onPressed: _c.loadingDir
                                  ? null
                                  : () => _c.refreshDirectory(),
                              icon: Icon(
                                Icons.refresh_rounded,
                                size: 18,
                                color: context.wb.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: context.wb.border),
                      Expanded(
                        child: DropTarget(
                          onDragEntered: (_) => setState(
                            () => _dropHighlight =
                                !SftpBrowser.isDraggingInternalItem,
                          ),
                          onDragExited: (_) =>
                              setState(() => _dropHighlight = false),
                          onDragDone: (detail) async {
                            setState(() => _dropHighlight = false);
                            final wasInternalDrag =
                                SftpBrowser.isDraggingInternalItem;
                            SftpBrowser.isDraggingInternalItem = false;
                            if (kIsWeb) return;
                            // 内部组件拖出又松手回到面板：直接取消，避免把临时副本再次上传回去。
                            if (wasInternalDrag) return;

                            final paths = <String>[];
                            for (final f in detail.files) {
                              final path = f.path;
                              if (path.isEmpty) continue;
                              // 来自任何会话的拖出临时副本一律忽略，不区分当前控制器。
                              if (SshWorkspaceController.isPathFromRecentDragOut(
                                path,
                              )) {
                                continue;
                              }
                              paths.add(path);
                            }
                            if (paths.isEmpty) return;
                            await _onLocalPathsDropped(context, paths);
                          },
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: _dropHighlight
                                  ? context.wb.accentBlue.withValues(
                                      alpha: 0.08,
                                    )
                                  : Colors.transparent,
                            ),
                            child: _c.loadingDir
                                ? Center(
                                    child: CircularProgressIndicator(
                                      color: context.wb.accentBlue,
                                    ),
                                  )
                                : Column(
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          10,
                                          4,
                                          10,
                                          2,
                                        ),
                                        child: Row(
                                          children: [
                                            const SizedBox(width: 22),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              flex: 5,
                                              child: Text(
                                                l.sftpColumnName,
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: context.wb.textMuted,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            SizedBox(
                                              width: 64,
                                              child: Text(
                                                l.sftpColumnSize,
                                                textAlign: TextAlign.end,
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: context.wb.textMuted,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            SizedBox(
                                              width: 108,
                                              child: Text(
                                                l.sftpColumnModified,
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: context.wb.textMuted,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Divider(
                                        height: 1,
                                        color: context.wb.border,
                                      ),
                                      Expanded(
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () {
                                            _requestFocus();
                                            _clearSelection();
                                          },
                                          child: ListView.separated(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 2,
                                            ),
                                            itemCount: _c.entries.length,
                                            separatorBuilder: (context, _) =>
                                                Divider(
                                                  height: 1,
                                                  color: context.wb.border,
                                                ),
                                            itemBuilder: (context, i) {
                                              final e = _c.entries[i];
                                              final isDir = e.attr.isDirectory;
                                              final selected = _selectedNames
                                                  .contains(e.filename);
                                              final rowCore = Builder(
                                                builder: (ctx2) {
                                                  void openMenuAt(Offset g) {
                                                    _requestFocus();
                                                    _prepareSelectionForContextMenu(
                                                      e.filename,
                                                    );
                                                    final selectedNow =
                                                        _selectedInListOrder();
                                                    final onlyFile =
                                                        selectedNow.length ==
                                                            1 &&
                                                        !isDir &&
                                                        selectedNow.first ==
                                                            e.filename;
                                                    _showEntryContextMenu(
                                                      ctx2,
                                                      g,
                                                      onDownload: () =>
                                                          _downloadSelected(
                                                            ctx2,
                                                          ),
                                                      onDelete: () =>
                                                          _confirmDeleteSelected(
                                                            ctx2,
                                                          ),
                                                      onOpenInEditor: onlyFile
                                                          ? () => _openOrEdit(
                                                              ctx2,
                                                              e.filename,
                                                              e.attr,
                                                            )
                                                          : null,
                                                    );
                                                  }

                                                  final rowInner = Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 4,
                                                        ),
                                                    child: Row(
                                                      children: [
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.all(
                                                                2,
                                                              ),
                                                          child: Icon(
                                                            isDir
                                                                ? Icons
                                                                      .folder_rounded
                                                                : Icons
                                                                      .insert_drive_file_outlined,
                                                            color: isDir
                                                                ? context
                                                                      .wb
                                                                      .folder
                                                                : context
                                                                      .wb
                                                                      .textMuted,
                                                            size: 16,
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 4,
                                                        ),
                                                        Expanded(
                                                          flex: 5,
                                                          child: Text(
                                                            e.filename,
                                                            style: TextStyle(
                                                              fontFamily:
                                                                  'monospace',
                                                              fontSize: 11,
                                                              color: context
                                                                  .wb
                                                                  .secondaryText,
                                                            ),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        ),
                                                        SizedBox(
                                                          width: 64,
                                                          child: Text(
                                                            isDir
                                                                ? '—'
                                                                : _formatRemoteBytes(
                                                                    e
                                                                        .attr
                                                                        .size,
                                                                  ),
                                                            textAlign:
                                                                TextAlign.end,
                                                            style: TextStyle(
                                                              fontFamily:
                                                                  'monospace',
                                                              fontSize: 10,
                                                              color: context
                                                                  .wb
                                                                  .textMuted,
                                                            ),
                                                          ),
                                                        ),
                                                        const SizedBox(
                                                          width: 6,
                                                        ),
                                                        SizedBox(
                                                          width: 108,
                                                          child: Text(
                                                            _formatUnixMtime(
                                                              e
                                                                  .attr
                                                                  .modifyTime,
                                                              useBeijingMtime,
                                                            ),
                                                            style: TextStyle(
                                                              fontFamily:
                                                                  'monospace',
                                                              fontSize: 10,
                                                              color: context
                                                                  .wb
                                                                  .textMuted,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );

                                                  return GestureDetector(
                                                    onSecondaryTapUp: (d) =>
                                                        openMenuAt(
                                                          d.globalPosition,
                                                        ),
                                                    child: Material(
                                                      color: selected
                                                          ? context
                                                                .wb
                                                                .accentBlue
                                                                .withValues(
                                                                  alpha: 0.18,
                                                                )
                                                          : Colors.transparent,
                                                      child: InkWell(
                                                        onTap: () {
                                                          _requestFocus();
                                                          _applySelectionTap(
                                                            e.filename,
                                                            additive:
                                                                _sftpMetaOrControlPressed(),
                                                            range:
                                                                _sftpShiftPressed(),
                                                          );
                                                        },
                                                        onDoubleTap: () {
                                                          _requestFocus();
                                                          unawaited(
                                                            _activateEntry(
                                                              ctx2,
                                                              e,
                                                            ),
                                                          );
                                                        },
                                                        child: rowInner,
                                                      ),
                                                    ),
                                                  );
                                                },
                                              );

                                              if (_sftpDesktopDragOutSupported()) {
                                                return _SftpRemoteEntryDragWrap(
                                                  controller: _c,
                                                  relativeName: e.filename,
                                                  isDirectory: isDir,
                                                  pickerContext: context,
                                                  child: rowCore,
                                                );
                                              }
                                              return rowCore;
                                            },
                                          ),
                                        ),
                                      ),
                                      ListenableBuilder(
                                        listenable: _c.uploadTasks,
                                        builder: (context, _) {
                                          final tasks = _c.uploadTasks.items;
                                          if (tasks.isEmpty) {
                                            if (_uploadQueueExpanded) {
                                              WidgetsBinding.instance
                                                  .addPostFrameCallback((_) {
                                                    if (!mounted) return;
                                                    setState(
                                                      () =>
                                                          _uploadQueueExpanded =
                                                              false,
                                                    );
                                                  });
                                            }
                                            return const SizedBox.shrink();
                                          }
                                          return _SftpUploadQueueFooter(
                                            tasks: tasks,
                                            batchSucceeded: _c
                                                .uploadTasks
                                                .batchSucceeded,
                                            batchTotal:
                                                _c.uploadTasks.batchTotal,
                                            expanded: _uploadQueueExpanded,
                                            onToggleExpand: () => setState(
                                              () => _uploadQueueExpanded =
                                                  !_uploadQueueExpanded,
                                            ),
                                            formatBytes: _formatByteCount,
                                            onCancelFile:
                                                _c.uploadTasks.userCancelFile,
                                            onCancelAll:
                                                _c.uploadTasks.userCancelAll,
                                          );
                                        },
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
            ),
          ),
        );
      },
    );
  }
}

class _SftpUploadQueueFooter extends StatelessWidget {
  /// 单行任务区大致高度（用于展开区域约 3 行可滚）。
  static const double rowSlotHeight = 54;
  static const double expandedListMaxHeight = rowSlotHeight * 3;

  const _SftpUploadQueueFooter({
    required this.tasks,
    required this.batchSucceeded,
    required this.batchTotal,
    required this.expanded,
    required this.onToggleExpand,
    required this.formatBytes,
    required this.onCancelFile,
    required this.onCancelAll,
  });

  final List<SftpUploadTaskView> tasks;
  final int batchSucceeded;
  final int batchTotal;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final String Function(int bytes) formatBytes;
  final void Function(String fileId) onCancelFile;
  final bool Function() onCancelAll;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final l = AppLocalizations.of(context)!;
    final n = tasks.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1, color: wb.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l.sftpTransferQueueProgress(batchSucceeded, batchTotal),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: wb.secondaryText,
                  ),
                ),
              ),
              if (n > 1)
                IconButton(
                  tooltip: expanded
                      ? l.sftpUploadQueueCollapse
                      : l.sftpUploadQueueExpand,
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: onToggleExpand,
                  icon: Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: wb.textMuted,
                  ),
                ),
              IconButton(
                tooltip: l.sftpUploadCancelAllTooltip,
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                visualDensity: VisualDensity.compact,
                onPressed: () => onCancelAll(),
                icon: Icon(Icons.cancel_outlined, color: wb.textMuted),
              ),
            ],
          ),
        ),
        if (!expanded)
          _SftpUploadTaskRow(
            task: tasks.first,
            formatBytes: formatBytes,
            onCancelFile: onCancelFile,
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: expandedListMaxHeight),
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 6),
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              itemCount: tasks.length,
              separatorBuilder: (context, _) => const SizedBox(height: 4),
              itemBuilder: (context, i) => _SftpUploadTaskRow(
                task: tasks[i],
                formatBytes: formatBytes,
                onCancelFile: onCancelFile,
              ),
            ),
          ),
      ],
    );
  }
}

class _SftpUploadTaskRow extends StatelessWidget {
  const _SftpUploadTaskRow({
    required this.task,
    required this.formatBytes,
    required this.onCancelFile,
  });

  final SftpUploadTaskView task;
  final String Function(int bytes) formatBytes;
  final void Function(String fileId) onCancelFile;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final l = AppLocalizations.of(context)!;
    final err = task.error;
    final total = task.totalBytes;
    final uploaded = task.uploadedBytes;
    final canCancel =
        task.state == SftpUploadRowState.pending ||
        task.state == SftpUploadRowState.uploading;

    final double? progressValue;
    if (err != null) {
      progressValue = 1.0;
    } else if (task.state == SftpUploadRowState.pending) {
      progressValue = null;
    } else if (total > 0) {
      progressValue = (uploaded / total).clamp(0.0, 1.0);
    } else {
      progressValue = null;
    }

    final String subtitle;
    if (err != null) {
      subtitle = l.sftpUploadFailed('$err');
    } else if (task.state == SftpUploadRowState.pending) {
      subtitle = l.sftpUploadRowPending;
    } else {
      subtitle = '${formatBytes(uploaded)} / ${formatBytes(total)}';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 2, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: task.direction == SftpTransferDirection.upload
                ? l.sftpTransferKindUploadTooltip
                : l.sftpTransferKindDownloadTooltip,
            child: Padding(
              padding: const EdgeInsets.only(top: 1, right: 4),
              child: Icon(
                task.direction == SftpTransferDirection.upload
                    ? Icons.upload_rounded
                    : Icons.download_rounded,
                size: 15,
                color: wb.accentBlue,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  task.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: wb.secondaryText,
                  ),
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progressValue,
                    minHeight: 3,
                    backgroundColor: wb.border,
                    color: err != null
                        ? const Color(0xFFEF4444)
                        : wb.accentBlue,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: err != null ? const Color(0xFFF87171) : wb.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (canCancel)
            IconButton(
              tooltip: l.sftpUploadCancelFileTooltip,
              iconSize: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              visualDensity: VisualDensity.compact,
              onPressed: () => onCancelFile(task.id),
              icon: Icon(Icons.close_rounded, size: 16, color: wb.textMuted),
            )
          else
            const SizedBox(width: 30),
        ],
      ),
    );
  }
}
