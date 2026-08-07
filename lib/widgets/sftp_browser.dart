import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:math' as math;

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../l10n/app_localizations.dart';
import '../screens/remote_editor_screen.dart';
import '../services/desktop_sftp_controller.dart';
import '../services/sftp_bookmarks_store.dart';
import '../services/sftp_browser_host.dart';
import '../services/sftp_fs_transfer.dart' as sftp_transfer;
import '../services/sftp_planned_upload.dart';
import '../services/sftp_remote_clipboard.dart';
import '../services/sftp_remote_copy.dart' as sftp_copy;
import '../services/sftp_upload_task_list.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_desktop_shortcuts.dart';
import '../theme/workbench_theme.dart';
import '../util/desktop_drop_paths.dart';
import '../util/remote_paths.dart';
import 'remote_state_view.dart';
import 'sftp_folder_delayed_draggable.dart';

String _formatRemoteBytes(int? bytes) {
  if (bytes == null) return '—';
  return _formatByteCount(bytes);
}

String _formatSftpMode(SftpFileMode? mode) {
  if (mode == null) return '—';
  String tri(bool r, bool w, bool x) =>
      '${r ? 'r' : '-'}${w ? 'w' : '-'}${x ? 'x' : '-'}';
  final type = switch (mode.type) {
    SftpFileType.directory => 'd',
    SftpFileType.symbolicLink => 'l',
    SftpFileType.pipe => 'p',
    SftpFileType.socket => 's',
    SftpFileType.blockDevice => 'b',
    SftpFileType.characterDevice => 'c',
    _ => '-',
  };
  return '$type'
      '${tri(mode.userRead, mode.userWrite, mode.userExecute)}'
      '${tri(mode.groupRead, mode.groupWrite, mode.groupExecute)}'
      '${tri(mode.otherRead, mode.otherWrite, mode.otherExecute)}';
}

String _formatSftpOwner(SftpFileAttrs attr) {
  final uid = attr.userID;
  final gid = attr.groupID;
  if (uid == null && gid == null) return '—';
  if (uid != null && gid != null) return '$uid:$gid';
  return '${uid ?? '—'}';
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
  Future<void> Function()? onRename,
  VoidCallback? onCopy,
  VoidCallback? onCut,
  Future<void> Function()? onPaste,
  Future<void> Function()? onCopyPath,
  VoidCallback? onAnalyzeDiskUsage,
  VoidCallback? onOpenTerminal,
  Future<void> Function()? onProperties,
  Future<void> Function()? onCompress,
  Future<void> Function()? onExtract,
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
      if (onOpenTerminal != null)
        PopupMenuItem(value: 'term', child: Text(l.sftpOpenTerminalMenu)),
      PopupMenuItem(value: 'dl', child: Text(l.sftpDownloadMenu)),
      if (onCopy != null)
        PopupMenuItem(value: 'copy', child: Text(l.sftpCopyMenu)),
      if (onCut != null)
        PopupMenuItem(value: 'cut', child: Text(l.sftpCutMenu)),
      if (onPaste != null)
        PopupMenuItem(value: 'paste', child: Text(l.sftpPasteMenu)),
      if (onCopyPath != null)
        const PopupMenuItem(value: 'copypath', child: Text('复制路径')),
      if (onRename != null)
        PopupMenuItem(value: 'rename', child: Text(l.sftpRenameMenu)),
      if (onAnalyzeDiskUsage != null)
        PopupMenuItem(value: 'du', child: Text(l.sftpAnalyzeDiskUsageMenu)),
      if (onProperties != null)
        const PopupMenuItem(value: 'props', child: Text('属性')),
      if (onCompress != null)
        const PopupMenuItem(value: 'compress', child: Text('压缩为 .tar.gz')),
      if (onExtract != null)
        const PopupMenuItem(value: 'extract', child: Text('解压到当前目录')),
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
    if (v == 'term' && onOpenTerminal != null) onOpenTerminal();
    if (v == 'dl') await onDownload();
    if (v == 'copy' && onCopy != null) onCopy();
    if (v == 'cut' && onCut != null) onCut();
    if (v == 'paste' && onPaste != null) await onPaste();
    if (v == 'copypath' && onCopyPath != null) await onCopyPath();
    if (v == 'rename' && onRename != null) await onRename();
    if (v == 'du' && onAnalyzeDiskUsage != null) onAnalyzeDiskUsage();
    if (v == 'props' && onProperties != null) await onProperties();
    if (v == 'compress' && onCompress != null) await onCompress();
    if (v == 'extract' && onExtract != null) await onExtract();
    if (v == 'del') await onDelete();
  });
}

void _showBlankContextMenu(
  BuildContext context,
  Offset globalPosition, {
  required Future<void> Function() onNewFile,
  required Future<void> Function() onNewFolder,
  required VoidCallback onSelectAll,
  required Future<void> Function() onRefresh,
  Future<void> Function()? onPaste,
  Future<void> Function()? onUploadFiles,
  Future<void> Function()? onUploadFolder,
  VoidCallback? onAnalyzeDiskUsage,
  VoidCallback? onOpenTerminal,
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
      PopupMenuItem(value: 'newfile', child: Text(l.sftpNewFileMenu)),
      PopupMenuItem(value: 'new', child: Text(l.sftpNewFolderMenu)),
      if (onUploadFiles != null)
        PopupMenuItem(value: 'upfiles', child: Text(l.sftpUploadFilesMenu)),
      if (onUploadFolder != null)
        PopupMenuItem(value: 'upfolder', child: Text(l.sftpUploadFolderMenu)),
      if (onPaste != null)
        PopupMenuItem(value: 'paste', child: Text(l.sftpPasteMenu)),
      PopupMenuItem(value: 'all', child: Text(l.terminalMenuSelectAll)),
      if (onOpenTerminal != null)
        PopupMenuItem(value: 'term', child: Text(l.sftpOpenTerminalMenu)),
      if (onAnalyzeDiskUsage != null)
        PopupMenuItem(value: 'du', child: Text(l.sftpAnalyzeDiskUsageMenu)),
      PopupMenuItem(value: 'refresh', child: Text(l.sftpRefreshTooltip)),
    ],
  ).then((v) async {
    if (v == 'newfile') await onNewFile();
    if (v == 'new') await onNewFolder();
    if (v == 'upfiles' && onUploadFiles != null) await onUploadFiles();
    if (v == 'upfolder' && onUploadFolder != null) await onUploadFolder();
    if (v == 'paste' && onPaste != null) await onPaste();
    if (v == 'all') onSelectAll();
    if (v == 'term' && onOpenTerminal != null) onOpenTerminal();
    if (v == 'du' && onAnalyzeDiskUsage != null) onAnalyzeDiskUsage();
    if (v == 'refresh') await onRefresh();
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

class _RenameSelectionIntent extends Intent {
  const _RenameSelectionIntent();
}

class _NewFolderIntent extends Intent {
  const _NewFolderIntent();
}

class _CopySelectionIntent extends Intent {
  const _CopySelectionIntent();
}

class _CutSelectionIntent extends Intent {
  const _CutSelectionIntent();
}

class _PasteClipboardIntent extends Intent {
  const _PasteClipboardIntent();
}

class _GoToPathIntent extends Intent {
  const _GoToPathIntent();
}

/// 将系统剪贴板中的 `file://` URI 转成本地路径；非 file scheme 返回 null。
String? sftpLocalPathFromClipboardFileUri(Uri uri) {
  if (!uri.isScheme('file')) return null;
  try {
    final path = uri.toFilePath(
      windows: defaultTargetPlatform == TargetPlatform.windows,
    );
    if (path.isEmpty) return null;
    return path;
  } catch (_) {
    return null;
  }
}

/// 从本机系统剪贴板读取已复制的本地文件 / 文件夹路径（Finder、资源管理器等）。
Future<List<String>> sftpReadLocalPathsFromSystemClipboard({
  bool Function(String path)? ignorePath,
}) async {
  if (kIsWeb) return const [];
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return const [];
  final reader = await clipboard.read();
  final paths = <String>[];
  final seen = <String>{};
  for (final item in reader.items) {
    if (!item.canProvide(Formats.fileUri)) continue;
    final uri = await item.readValue(Formats.fileUri);
    if (uri == null) continue;
    final path = sftpLocalPathFromClipboardFileUri(uri);
    if (path == null) continue;
    if (ignorePath != null && ignorePath(path)) continue;
    if (seen.add(path)) paths.add(path);
  }
  return paths;
}

enum _SftpLayoutMode { list, grid }

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
  String? remotePath,
  List<String>? remotePaths,
  VoidCallback? onDisposed,
}) {
  final paths = <String>[
    if (remotePaths != null)
      for (final p in remotePaths)
        if (p.isNotEmpty) p
    else if (remotePath != null && remotePath.isNotEmpty)
      remotePath,
  ];
  if (paths.isNotEmpty) {
    SshWorkspaceController.lastDragRemotePath = paths.first;
    item.add(Formats.plainText(paths.join('\n')));
  }
  item.onRegistered.addListener(() {
    SftpBrowser.isDraggingInternalItem = true;
    if (paths.isNotEmpty) {
      SshWorkspaceController.activeDragRemotePaths = List<String>.from(paths);
    }
    if (tempPath != null && tempPath.isNotEmpty) {
      SshWorkspaceController.registerDragTempPath(
        tempPath,
        remotePath: paths.isEmpty ? remotePath : paths.first,
      );
    }
  });
  item.onDisposed.addListener(() {
    SftpBrowser.isDraggingInternalItem = false;
    SshWorkspaceController.activeDragRemotePaths = const [];
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
    required this.dragRelativeNames,
    required this.isDirectory,
    required this.pickerContext,
    required this.child,
  });

  final SftpBrowserHost controller;
  final String relativeName;

  /// 本次拖出的相对名列表（多选时含全部选中项）。
  final List<String> dragRelativeNames;
  final bool isDirectory;

  /// 用于目录拖出时的文件夹选择对话框与 SnackBar（须为 [Navigator] 子树）。
  final BuildContext pickerContext;
  final Widget child;

  List<String> get _remoteAbsPaths => [
    for (final n in dragRelativeNames)
      remoteJoin(controller.remoteCwd, n),
  ];

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
      _trackSftpInternalDragItem(
        item,
        tempPath: tempPath,
        remotePath: dragName,
        remotePaths: _remoteAbsPaths,
      );

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
          remotePath: dragName,
          remotePaths: _remoteAbsPaths,
          onDisposed: () => sftp_transfer.deleteLocalFileQuiet(path),
        );
        item.add(Formats.fileUri(Uri.file(path)));
        return item;
      } catch (_) {
        return null;
      }
    }
    final item = DragItem(suggestedName: nameOnly);
    _trackSftpInternalDragItem(
      item,
      remotePath: dragName,
      remotePaths: _remoteAbsPaths,
    );

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
        allowedOperations: () => [DropOperation.copy, DropOperation.move],
        dragItemProvider: _dragItemProvider,
        child: child,
      );
    }
    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy, DropOperation.move],
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
    this.onAnalyzeDiskUsage,
    this.onOpenTerminal,
    this.onActivate,
    this.autofocus = false,
    this.tapRegionGroupId,
  });

  final SftpBrowserHost controller;

  /// 桌面模式：双击 / 菜单「打开」时回调；为 null 时走 [RemoteEditorScreen] 路由。
  final void Function(String fileName)? onOpenInEditor;

  /// 桌面模式：分析指定相对名（文件夹）或当前目录（`null`）的磁盘占用。
  final void Function(String? relativeName)? onAnalyzeDiskUsage;

  /// 桌面模式：在文件管理器当前目录打开终端（`relativeName` 预留，现恒为 `null`）。
  final void Function(String? relativeName)? onOpenTerminal;

  /// 桌面模式：外部拖入等交互时回调，用于把所属窗口抬到最前。
  final VoidCallback? onActivate;

  /// 挂载或变为 true 时请求键盘焦点（桌面窗口激活）。
  final bool autofocus;

  /// 与桌面窗口外框共用，避免点标题栏时丢掉快捷键焦点。
  final Object? tapRegionGroupId;

  /// 用于标记当前拖出的项目是否来源于 EasyTerm 内部。
  /// 当应用内发生拖出并在同一窗口释放时，避免被当成外部文件上传。
  static bool isDraggingInternalItem = false;

  @override
  State<SftpBrowser> createState() => SftpBrowserState();
}

class SftpBrowserState extends State<SftpBrowser> {
  bool _dropHighlight = false;
  bool _uploadQueueExpanded = false;
  final Set<String> _selectedNames = {};
  String? _anchorName;
  String? _selectionCwd;
  final FocusNode _focusNode = FocusNode(debugLabel: 'sftpBrowser');
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _listStackKey = GlobalKey();
  final Map<String, GlobalKey> _rowKeys = {};
  _SftpLayoutMode _layoutMode = _SftpLayoutMode.list;
  bool _detailColumns = false;

  /// 框选：空白处按下并拖动后激活。
  int? _marqueePointer;
  Offset? _marqueeOriginLocal;
  Offset? _marqueeCurrentLocal;
  bool _marqueeActive = false;
  bool _marqueeAdditive = false;
  Set<String> _marqueeBaseSelection = {};
  bool _suppressClearFromTap = false;

  /// 拖放到某个文件夹条目上时高亮该目录名。
  String? _dropTargetDirName;

  /// 递增以取消过期的「物化到本机剪贴板」任务（连续 Ctrl+C）。
  int _clipboardWriteGeneration = 0;

  final _searchCtrl = TextEditingController();
  bool _searching = false;
  List<String> _searchHits = const [];
  String? _searchError;
  bool _searchTruncated = false;
  int _searchGen = 0;
  int _searchMaxDepth = 4;
  bool _searchContent = false;

  bool _pathBarEditing = false;
  final _pathCtrl = TextEditingController();
  final FocusNode _pathFocus = FocusNode(debugLabel: 'sftpPathBar');

  SftpBookmarksStore? _bookmarks;
  SftpRecentStore? _recent;
  List<String> _bookmarkList = const [];
  List<String> _recentList = const [];
  String? _lastTouchedCwd;

  SftpBrowserHost get _c => widget.controller;

  String? get _hostKey {
    final ws = _workspace;
    if (ws == null) return null;
    return '${ws.username}@${ws.host}:${ws.port}';
  }

  @override
  void initState() {
    super.initState();
    _selectionCwd = _c.remoteCwd;
    _c.addListener(_onHostChanged);
    _initBookmarksStores();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) requestKeyboardFocus();
      });
    }
  }

  void _initBookmarksStores() {
    final key = _hostKey;
    if (key == null) {
      _bookmarks = null;
      _recent = null;
      _bookmarkList = const [];
      _recentList = const [];
      _lastTouchedCwd = null;
      return;
    }
    if (_bookmarks?.hostKey == key && _recent?.hostKey == key) return;
    _bookmarks = SftpBookmarksStore(key);
    _recent = SftpRecentStore(key);
    _lastTouchedCwd = null;
    unawaited(_loadBookmarkLists());
  }

  Future<void> _loadBookmarkLists() async {
    final bookmarks = _bookmarks;
    final recent = _recent;
    if (bookmarks == null || recent == null) return;
    final marks = await bookmarks.load();
    final recents = await recent.load();
    if (!mounted) return;
    if (_bookmarks != bookmarks || _recent != recent) return;
    setState(() {
      _bookmarkList = marks;
      _recentList = recents;
    });
  }

  /// 请求快捷键焦点（桌面窗口激活时调用）。
  void requestKeyboardFocus() {
    if (!mounted) return;
    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
  }

  /// 窗口失焦时释放，避免抢走其它窗口 TextField 的键盘。
  void releaseKeyboardFocus() {
    if (!mounted) return;
    if (_focusNode.hasFocus) {
      _focusNode.unfocus();
    }
  }

  @override
  void didUpdateWidget(covariant SftpBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autofocus && !oldWidget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) requestKeyboardFocus();
      });
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onHostChanged);
      _selectionCwd = _c.remoteCwd;
      _selectedNames.clear();
      _anchorName = null;
      _resetMarquee(notify: false);
      _rowKeys.clear();
      _c.addListener(_onHostChanged);
      _initBookmarksStores();
    }
  }

  @override
  void dispose() {
    _clipboardWriteGeneration++;
    _searchGen++;
    _c.removeListener(_onHostChanged);
    _focusNode.dispose();
    _scrollController.dispose();
    _searchCtrl.dispose();
    _pathCtrl.dispose();
    _pathFocus.dispose();
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
      _resetMarquee(notify: false);
      _rowKeys.clear();
    } else if (_selectedNames.isNotEmpty) {
      final names = _c.entries.map((e) => e.filename).toSet();
      final before = _selectedNames.length;
      _selectedNames.removeWhere((n) => !names.contains(n));
      if (_anchorName != null && !names.contains(_anchorName)) {
        _anchorName = null;
        dirty = true;
      }
      if (_selectedNames.length != before) dirty = true;
      _rowKeys.removeWhere((k, _) => !names.contains(k));
    }
    if (!_c.loadingDir && _c.loadError == null) {
      final cwd = _c.remoteCwd.trim();
      if (cwd.isNotEmpty && cwd != _lastTouchedCwd) {
        _lastTouchedCwd = cwd;
        unawaited(_touchRecent(cwd));
      }
    }
    if (dirty) setState(() {});
  }

  Future<void> _touchRecent(String path) async {
    final recent = _recent;
    if (recent == null) return;
    final list = await recent.touch(path);
    if (!mounted || _recent != recent) return;
    setState(() => _recentList = list);
  }

  Future<void> _toggleBookmarkCurrent() async {
    final bookmarks = _bookmarks;
    final cwd = _c.remoteCwd.trim();
    if (bookmarks == null || cwd.isEmpty) return;
    final list = await bookmarks.toggle(cwd);
    if (!mounted || _bookmarks != bookmarks) return;
    setState(() => _bookmarkList = list);
  }

  Future<void> _navigateQuickAccess(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return;
    await _c.navigateToAbsolutePath(trimmed);
  }

  GlobalKey _rowKeyFor(String name) =>
      _rowKeys.putIfAbsent(name, GlobalKey.new);

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

  void _applySelectionTap(
    String name, {
    required bool additive,
    required bool range,
  }) {
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

  RenderBox? _listStackBox() {
    return _listStackKey.currentContext?.findRenderObject() as RenderBox?;
  }

  String? _hitTestRowName(Offset globalPosition) {
    for (final e in _c.entries) {
      final box =
          _rowKeys[e.filename]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final topLeft = box.localToGlobal(Offset.zero);
      final rect = topLeft & box.size;
      if (rect.contains(globalPosition)) return e.filename;
    }
    return null;
  }

  Set<String> _rowsIntersectingLocalRect(Rect localRect) {
    final stackBox = _listStackBox();
    if (stackBox == null || !stackBox.hasSize) return {};
    final globalRect = Rect.fromPoints(
      stackBox.localToGlobal(localRect.topLeft),
      stackBox.localToGlobal(localRect.bottomRight),
    );
    final hit = <String>{};
    for (final e in _c.entries) {
      final box =
          _rowKeys[e.filename]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rowRect = box.localToGlobal(Offset.zero) & box.size;
      if (rowRect.overlaps(globalRect)) {
        hit.add(e.filename);
      }
    }
    return hit;
  }

  void _applyMarqueeHitToSelection(Set<String> hit) {
    if (_marqueeAdditive) {
      _selectedNames
        ..clear()
        ..addAll(_marqueeBaseSelection)
        ..addAll(hit);
    } else {
      _selectedNames
        ..clear()
        ..addAll(hit);
    }
    if (hit.isNotEmpty) {
      _anchorName = hit.last;
    } else if (!_marqueeAdditive) {
      _anchorName = null;
    }
  }

  void _resetMarquee({bool notify = true}) {
    final had = _marqueePointer != null || _marqueeActive;
    _marqueePointer = null;
    _marqueeOriginLocal = null;
    _marqueeCurrentLocal = null;
    _marqueeActive = false;
    _marqueeAdditive = false;
    _marqueeBaseSelection = {};
    if (notify && had && mounted) {
      setState(() {});
    }
  }

  void _maybeAutoScrollDuringMarquee(Offset local) {
    if (!_scrollController.hasClients) return;
    final box = _listStackBox();
    if (box == null || !box.hasSize) return;
    const edge = 32.0;
    const step = 14.0;
    double delta = 0;
    if (local.dy < edge) {
      delta = -step;
    } else if (local.dy > box.size.height - edge) {
      delta = step;
    }
    if (delta == 0) return;
    final next = (_scrollController.offset + delta).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    if (next == _scrollController.offset) return;
    _scrollController.jumpTo(next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_marqueeActive || _marqueeOriginLocal == null) return;
      final current = _marqueeCurrentLocal;
      if (current == null) return;
      final rect = Rect.fromPoints(_marqueeOriginLocal!, current);
      setState(() {
        _applyMarqueeHitToSelection(_rowsIntersectingLocalRect(rect));
      });
    });
  }

  void _onMarqueePointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryMouseButton) return;
    _requestFocus();
    // 点在文件行上：交给单击 / 拖出，不启动框选。
    if (_hitTestRowName(event.position) != null) {
      _marqueePointer = null;
      _suppressClearFromTap = false;
      return;
    }
    final box = _listStackBox();
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(event.position);
    setState(() {
      _marqueePointer = event.pointer;
      _marqueeOriginLocal = local;
      _marqueeCurrentLocal = local;
      _marqueeActive = false;
      _marqueeAdditive = _sftpMetaOrControlPressed();
      _marqueeBaseSelection = Set<String>.of(_selectedNames);
    });
  }

  void _onMarqueePointerMove(PointerMoveEvent event) {
    if (_marqueePointer != event.pointer || _marqueeOriginLocal == null) {
      return;
    }
    final box = _listStackBox();
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(event.position);
    final distance = (local - _marqueeOriginLocal!).distance;
    if (!_marqueeActive && distance < 5) return;

    setState(() {
      if (!_marqueeActive) {
        _marqueeActive = true;
        _suppressClearFromTap = true;
      }
      _marqueeCurrentLocal = local;
      final rect = Rect.fromPoints(_marqueeOriginLocal!, local);
      _applyMarqueeHitToSelection(_rowsIntersectingLocalRect(rect));
    });
    _maybeAutoScrollDuringMarquee(local);
  }

  void _onMarqueePointerUp(PointerUpEvent event) {
    if (_marqueePointer != event.pointer) return;
    final wasActive = _marqueeActive;
    _resetMarquee();
    if (!wasActive) {
      _suppressClearFromTap = false;
      // 空白处单击：清空选中。
      _clearSelection();
      return;
    }
    // 框选结束后 GestureDetector 可能再收到 onTap，避免把刚框选的结果清掉。
    _suppressClearFromTap = true;
  }

  void _onMarqueePointerCancel(PointerCancelEvent event) {
    if (_marqueePointer != event.pointer) return;
    _resetMarquee();
    _suppressClearFromTap = false;
  }

  Rect? get _marqueePaintRect {
    final a = _marqueeOriginLocal;
    final b = _marqueeCurrentLocal;
    if (!_marqueeActive || a == null || b == null) return null;
    return Rect.fromPoints(a, b);
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
        await _downloadEntry(context, name, isDirectory: e.attr.isDirectory);
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

  /// 远端路径拖放到当前目录（或 [destCwd] 指定目录）：默认移动，Alt/Ctrl 为复制。
  Future<void> _onRemotePathsDropped(
    BuildContext context,
    List<String> remoteAbsPaths, {
    required String destCwd,
  }) async {
    if (remoteAbsPaths.isEmpty) return;
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.maybeOf(context);

    // 按源目录分组：{ fromCwd -> [basename, ...] }
    final bySource = <String, List<String>>{};
    for (final abs in remoteAbsPaths) {
      if (abs.isEmpty) continue;
      final fromCwd = remoteDirname(abs);
      final name = remoteBasename(abs);
      if (name.isEmpty || name == '.' || name == '..') continue;
      // 拖到自身目录且无换名需求：跳过。
      if (normalizeRemotePathForCompare(fromCwd) ==
          normalizeRemotePathForCompare(destCwd)) {
        continue;
      }
      bySource.putIfAbsent(fromCwd, () => []).add(name);
    }
    if (bySource.isEmpty) return;

    final asCopy =
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isControlPressed;

    var pastedTotal = 0;
    try {
      for (final entry in bySource.entries) {
        final pasted = asCopy
            ? await _c.copyRemoteNamesFrom(
                fromCwd: entry.key,
                names: entry.value,
                toCwd: destCwd,
              )
            : await _c.moveRemoteNamesFrom(
                fromCwd: entry.key,
                names: entry.value,
                toCwd: destCwd,
              );
        pastedTotal += pasted.length;
        if (pasted.isNotEmpty &&
            normalizeRemotePathForCompare(destCwd) ==
                normalizeRemotePathForCompare(_c.remoteCwd)) {
          setState(() {
            _selectedNames
              ..clear()
              ..addAll(pasted);
            _anchorName = pasted.first;
          });
        }
      }
      if (!context.mounted) return;
      if (pastedTotal > 0) {
        messenger?.showSnackBar(
          SnackBar(content: Text(l.sftpPasted(pastedTotal))),
        );
      }
    } on sftp_copy.SftpRemotePastePartialFailure catch (e) {
      if (!context.mounted) return;
      messenger?.showSnackBar(SnackBar(content: Text('$e')));
    } catch (e) {
      if (context.mounted) {
        messenger?.showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  String? _dropDestDirNameAt(Offset globalPosition) {
    final name = _hitTestRowName(globalPosition);
    if (name == null) return null;
    final entry = _entryByName(name);
    if (entry == null || !entry.attr.isDirectory) return null;
    // 不能把文件拖进正在拖的目录自身。
    final abs = remoteJoin(_c.remoteCwd, name);
    final dragging = SshWorkspaceController.activeDragRemotePaths;
    for (final d in dragging) {
      if (normalizeRemotePathForCompare(d) ==
          normalizeRemotePathForCompare(abs)) {
        return null;
      }
      if (isRemotePathUnderOrEqual(d, abs)) return null;
    }
    return name;
  }

  void _updateDropTargetHighlight(Offset globalPosition, {required bool show}) {
    if (!show) {
      if (_dropHighlight || _dropTargetDirName != null) {
        setState(() {
          _dropHighlight = false;
          _dropTargetDirName = null;
        });
      }
      return;
    }
    final dir = _dropDestDirNameAt(globalPosition);
    if (_dropHighlight && _dropTargetDirName == dir) return;
    setState(() {
      _dropHighlight = true;
      _dropTargetDirName = dir;
    });
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

  SshWorkspaceController? get _workspace {
    final h = _c;
    if (h is SshWorkspaceController) return h;
    if (h is DesktopSftpController) return h.workspace;
    return null;
  }

  SftpRemoteClipboard? get _clipboard => _workspace?.remoteFileClipboard;

  void _setClipboard(SftpRemoteClipboard? value) {
    final ws = _workspace;
    if (ws != null) {
      ws.setRemoteFileClipboard(value);
      return;
    }
    // 无会话时（理论上不会）本地无法跨窗共享；忽略。
  }

  Future<void> _runSearch() async {
    final q = _searchCtrl.text.trim();
    final ws = _workspace;
    if (q.isEmpty || ws == null || !ws.connected) {
      setState(() {
        _searchHits = const [];
        _searchError = null;
        _searchTruncated = false;
      });
      return;
    }
    // 禁止 shell 元字符
    if (!RegExp(r'^[A-Za-z0-9_./@+\- *?]+$').hasMatch(q) || q.contains('..')) {
      setState(() => _searchError = '非法搜索模式');
      return;
    }
    final gen = ++_searchGen;
    setState(() {
      _searching = true;
      _searchError = null;
      _searchTruncated = false;
    });
    try {
      final cwd = _c.remoteCwd;
      final quoted = q.replaceAll("'", "'\\''");
      final depth = _searchMaxDepth;
      final cwdQ = cwd.replaceAll("'", "'\\''");
      final String cmd;
      if (_searchContent) {
        cmd =
            "cd '$cwdQ' && "
            "find . -maxdepth $depth -type f "
            "-exec grep -l -- '$quoted' {} + 2>/dev/null | head -n 80";
      } else {
        cmd =
            "cd '$cwdQ' && "
            "find . -maxdepth $depth -iname '*$quoted*' 2>/dev/null | head -n 80";
      }
      final raw = await ws.runQueued(cmd);
      if (!mounted || gen != _searchGen) return;
      if (raw == null) {
        setState(() {
          _searching = false;
          _searchError = '搜索失败';
          _searchHits = const [];
          _searchTruncated = false;
        });
        return;
      }
      final hits = raw
          .split(RegExp(r'[\r\n]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && e != '.')
          .map((e) => e.startsWith('./') ? e.substring(2) : e)
          .toList();
      setState(() {
        _searching = false;
        _searchHits = hits;
        _searchTruncated = hits.length >= 80;
      });
    } catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _searching = false;
        _searchError = '$e';
        _searchTruncated = false;
      });
    }
  }

  void _cancelSearch() {
    _searchGen++;
    if (!_searching) return;
    setState(() => _searching = false);
  }

  Future<void> _openSearchHit(String relative) async {
    final parts = relative.replaceAll('\\', '/').split('/');
    if (parts.isEmpty) return;
    final fileName = parts.last;
    final dirParts = parts.length > 1 ? parts.sublist(0, parts.length - 1) : [];
    var targetDir = _c.remoteCwd;
    for (final p in dirParts) {
      if (p.isEmpty || p == '.') continue;
      targetDir = remoteJoin(targetDir, p);
    }
    await _c.navigateToAbsolutePath(targetDir);
    if (!mounted) return;
    setState(() {
      _searchHits = const [];
      _searchTruncated = false;
      _searchCtrl.clear();
    });
    final entry = _entryByName(fileName);
    if (entry != null && entry.attr.isFile && widget.onOpenInEditor != null) {
      widget.onOpenInEditor!(fileName);
    }
  }

  Future<void> _showProperties(BuildContext context, String name) async {
    final ws = _workspace;
    final path = remoteJoin(_c.remoteCwd, name);
    if (ws == null || !ws.connected) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未连接')),
        );
      }
      return;
    }
    final q = path.replaceAll("'", "'\\''");
    final raw = await ws.runQueued(
      "stat -c '%s|%U|%G|%a|%Y|%F' '$q' 2>/dev/null || "
      "stat -f '%z|%Su|%Sg|%Mp%Lp|%m|%HT%SY' '$q' 2>/dev/null",
    );
    if (!context.mounted) return;
    if (raw == null || raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法读取属性')),
      );
      return;
    }
    final parts = raw.split('|');
    String at(int i) => i < parts.length ? parts[i].trim() : '';
    final size = int.tryParse(at(0));
    final owner = at(1).isEmpty ? '—' : at(1);
    final group = at(2).isEmpty ? '—' : at(2);
    final mode = at(3);
    final mtimeSec = int.tryParse(at(4));
    final kind = at(5);
    var modeBits = int.tryParse(mode, radix: 8) ?? int.tryParse(mode) ?? 0;
    if (mode.length == 3 || mode.length == 4) {
      modeBits = int.tryParse(mode, radix: 8) ?? modeBits;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return _SftpPropertiesDialog(
          path: path,
          size: size,
          owner: owner,
          group: group,
          kind: kind,
          mtimeSec: mtimeSec,
          initialMode: modeBits & 0x1FF,
          onChmod: (octal) async {
            final out = await ws.runQueued("chmod $octal '$q'");
            return out != null;
          },
        );
      },
    );
    if (mounted) unawaited(_c.refreshDirectory());
  }

  bool _isArchiveName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.tar.gz') ||
        lower.endsWith('.tgz') ||
        lower.endsWith('.tar') ||
        lower.endsWith('.zip') ||
        lower.endsWith('.gz');
  }

  String _shellSingleQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  Future<void> _compressSelected(BuildContext context) async {
    final ws = _workspace;
    if (ws == null || !ws.connected) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未连接')),
        );
      }
      return;
    }
    final names = _selectedInListOrder();
    if (names.isEmpty) return;
    final cwdQ = _shellSingleQuote(_c.remoteCwd);
    final quotedNames = names.map(_shellSingleQuote).join(' ');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final outName = names.length == 1
        ? '${names.first}.tar.gz'
        : 'archive_$stamp.tar.gz';
    final outQ = _shellSingleQuote(outName);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('正在压缩 → $outName')),
      );
    }
    final raw = await ws.runQueued(
      'cd $cwdQ && tar czf $outQ $quotedNames 2>&1; echo __EC:\$?',
    );
    if (!mounted) return;
    final ok = raw != null && RegExp(r'__EC:0\s*$').hasMatch(raw.trim());
    if (context.mounted) {
      final detail = raw == null
          ? ''
          : '：${raw.replaceAll(RegExp(r'__EC:\d+\s*$'), '').trim()}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '已创建 $outName' : '压缩失败$detail'),
        ),
      );
    }
    await _c.refreshDirectory();
  }

  Future<void> _extractArchive(BuildContext context, String name) async {
    final ws = _workspace;
    if (ws == null || !ws.connected) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未连接')),
        );
      }
      return;
    }
    final cwdQ = _shellSingleQuote(_c.remoteCwd);
    final nameQ = _shellSingleQuote(name);
    final lower = name.toLowerCase();
    final String cmd;
    if (lower.endsWith('.zip')) {
      cmd = 'cd $cwdQ && unzip -o $nameQ 2>&1; echo __EC:\$?';
    } else if (lower.endsWith('.tar.gz') ||
        lower.endsWith('.tgz') ||
        lower.endsWith('.tar')) {
      cmd = 'cd $cwdQ && tar xf $nameQ 2>&1; echo __EC:\$?';
    } else if (lower.endsWith('.gz') && !lower.endsWith('.tar.gz')) {
      cmd = 'cd $cwdQ && gunzip -k $nameQ 2>&1; echo __EC:\$?';
    } else {
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('正在解压 $name')),
      );
    }
    final raw = await ws.runQueued(cmd);
    if (!mounted) return;
    final ok = raw != null && RegExp(r'__EC:0\s*$').hasMatch(raw.trim());
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '解压完成' : '解压失败（可能缺少 unzip/tar 或权限不足）'),
        ),
      );
    }
    await _c.refreshDirectory();
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.sftpBinaryNotOpened)));
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

  bool _isValidRemoteEntryName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.contains('/') || trimmed.contains('\\')) return false;
    if (trimmed == '.' || trimmed == '..') return false;
    return true;
  }

  Future<String?> _promptRemoteName(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    String? initialValue,
    String? hintText,
  }) async {
    final l = AppLocalizations.of(context)!;
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return _RemoteNamePromptDialog(
          title: title,
          confirmLabel: confirmLabel,
          cancelLabel: l.sftpCancel,
          fieldLabel: l.sftpNameFieldLabel,
          invalidNameMessage: l.sftpInvalidName,
          initialValue: initialValue,
          hintText: hintText,
          isValidName: _isValidRemoteEntryName,
        );
      },
    );
  }

  Future<void> _createNewFolder(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    final name = await _promptRemoteName(
      context,
      title: l.sftpNewFolderTitle,
      confirmLabel: l.sftpCreate,
      hintText: l.sftpNewFolderHint,
    );
    if (name == null || !context.mounted) return;
    try {
      await _c.createRemoteDirectory(name);
      if (!context.mounted) return;
      setState(() {
        _selectedNames
          ..clear()
          ..add(name);
        _anchorName = name;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.sftpCreatedFolder(name))));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _createNewFile(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    final name = await _promptRemoteName(
      context,
      title: l.sftpNewFileTitle,
      confirmLabel: l.sftpCreate,
      hintText: l.sftpNewFileHint,
    );
    if (name == null || !context.mounted) return;
    try {
      await _c.createRemoteFile(name);
      if (!context.mounted) return;
      setState(() {
        _selectedNames
          ..clear()
          ..add(name);
        _anchorName = name;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.sftpCreatedFile(name))));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _renameSelected(BuildContext context) async {
    final names = _selectedInListOrder();
    if (names.length != 1) return;
    final oldName = names.first;
    final l = AppLocalizations.of(context)!;
    final next = await _promptRemoteName(
      context,
      title: l.sftpRenameTitle,
      confirmLabel: l.sftpRenameConfirm,
      initialValue: oldName,
    );
    if (next == null || !context.mounted) return;
    if (next == oldName) return;
    try {
      await _c.renameRemote(oldName, next);
      if (!context.mounted) return;
      setState(() {
        _selectedNames
          ..clear()
          ..add(next);
        _anchorName = next;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.sftpRenamed(next))));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// 立刻用纯文本占位，清掉系统剪贴板里旧的 file URI，避免抢应用内粘贴。
  Future<void> _writeRemoteNamesAsPlainTextClipboard(List<String> names) async {
    if (kIsWeb || names.isEmpty) return;
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return;
    final item = DataWriterItem();
    item.add(Formats.plainText(names.join('\n')));
    try {
      await clipboard.write([item]);
    } catch (_) {
      // 系统剪贴板写入失败不影响应用内远程复制/剪切。
    }
  }

  void _attachClipboardTempCleanup(DataWriterItem item, String tempParent) {
    item.onRegistered.addListener(() {
      SshWorkspaceController.registerDragTempPath(tempParent);
    });
    item.onDisposed.addListener(() {
      SshWorkspaceController.unregisterDragTempPath(tempParent);
      sftp_transfer.deleteLocalDirectoryQuiet(tempParent);
    });
  }

  /// 将选中远程项下载到临时目录，并以 `file://` 写入系统剪贴板，
  /// 以便在 Finder / 资源管理器中粘贴。剪贴板虚拟文件在 macOS 上不可用，
  /// 故各桌面平台统一先物化再写 URI。
  Future<void> _writeRemoteSelectionToSystemClipboard(
    List<String> names,
  ) async {
    if (kIsWeb || names.isEmpty) return;
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return;

    final gen = ++_clipboardWriteGeneration;
    await _writeRemoteNamesAsPlainTextClipboard(names);
    if (gen != _clipboardWriteGeneration) return;

    final stamp = DateTime.now().microsecondsSinceEpoch;
    late final String tempParent;
    try {
      final dir = await getTemporaryDirectory();
      tempParent = p.join(dir.path, 'easyterm_clip_$stamp');
      await sftp_transfer.ensureLocalDirectoryExists(tempParent);
    } catch (_) {
      return;
    }
    if (gen != _clipboardWriteGeneration) {
      sftp_transfer.deleteLocalDirectoryQuiet(tempParent);
      return;
    }

    SshWorkspaceController.registerDragTempPath(tempParent);
    final localPaths = <String>[];
    try {
      for (final name in names) {
        if (gen != _clipboardWriteGeneration) break;
        final entry = _entryByName(name);
        if (entry == null) continue;
        final base = remoteBasename(name);
        if (entry.attr.isDirectory) {
          await _c.downloadRemoteDirectoryToLocal(name, tempParent);
          final localDir = p.join(tempParent, base);
          if (sftp_transfer.localPathExistsSync(localDir)) {
            localPaths.add(localDir);
          }
        } else {
          final localFile = p.join(tempParent, base);
          await _c.downloadRemoteFileToLocalPath(name, localFile);
          if (sftp_transfer.localPathExistsSync(localFile)) {
            localPaths.add(localFile);
          }
        }
      }
      if (gen != _clipboardWriteGeneration) {
        throw StateError('clipboard write superseded');
      }
    } catch (_) {
      SshWorkspaceController.unregisterDragTempPath(tempParent);
      sftp_transfer.deleteLocalDirectoryQuiet(tempParent);
      return;
    }

    if (localPaths.isEmpty) {
      SshWorkspaceController.unregisterDragTempPath(tempParent);
      sftp_transfer.deleteLocalDirectoryQuiet(tempParent);
      return;
    }

    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final items = <DataWriterItem>[];
    for (var i = 0; i < localPaths.length; i++) {
      final path = localPaths[i];
      final item = DataWriterItem(suggestedName: p.basename(path));
      if (i == 0) {
        item.add(Formats.plainText(names.join('\n')));
        _attachClipboardTempCleanup(item, tempParent);
      }
      item.add(Formats.fileUri(Uri.file(path, windows: windows)));
      items.add(item);
    }
    try {
      await clipboard.write(items);
    } catch (_) {
      SshWorkspaceController.unregisterDragTempPath(tempParent);
      sftp_transfer.deleteLocalDirectoryQuiet(tempParent);
    }
  }

  Future<void> _copySelected(BuildContext context) async {
    final names = _selectedInListOrder();
    if (names.isEmpty) return;
    _setClipboard(
      SftpRemoteClipboard(
        sourceCwd: _c.remoteCwd,
        names: List<String>.from(names),
        isCut: false,
      ),
    );
    setState(() {});
    final l = AppLocalizations.of(context)!;
    // 应用内远程粘贴立即可用；物化完成后再提示，方便立刻粘贴到本机。
    await _writeRemoteSelectionToSystemClipboard(names);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.sftpCopied(names.length))));
  }

  Future<void> _cutSelected(BuildContext context) async {
    final names = _selectedInListOrder();
    if (names.isEmpty) return;
    _setClipboard(
      SftpRemoteClipboard(
        sourceCwd: _c.remoteCwd,
        names: List<String>.from(names),
        isCut: true,
      ),
    );
    setState(() {});
    final l = AppLocalizations.of(context)!;
    await _writeRemoteSelectionToSystemClipboard(names);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l.sftpCutToast(names.length))));
  }

  bool get _canPaste =>
      (_clipboard != null && _clipboard!.names.isNotEmpty) || !kIsWeb;

  Future<void> _pasteClipboard(BuildContext context) async {
    final l = AppLocalizations.of(context)!;

    // 本机系统剪贴板中的文件优先（Finder / 资源管理器复制）；
    // 远程复制/剪切会写入纯文本以清掉旧的 file URI，避免抢粘贴。
    if (!kIsWeb) {
      List<String> localPaths;
      try {
        localPaths = await sftpReadLocalPathsFromSystemClipboard(
          ignorePath: SshWorkspaceController.isPathFromRecentDragOut,
        );
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$e')));
        }
        return;
      }
      if (!context.mounted) return;
      if (localPaths.isNotEmpty) {
        await _onLocalPathsDropped(context, localPaths);
        return;
      }
    }

    final clip = _clipboard;
    if (clip == null || clip.names.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.sftpClipboardEmpty)));
      return;
    }
    try {
      final pasted = clip.isCut
          ? await _c.moveRemoteNamesFrom(
              fromCwd: clip.sourceCwd,
              names: clip.names,
            )
          : await _c.copyRemoteNamesFrom(
              fromCwd: clip.sourceCwd,
              names: clip.names,
            );
      if (!context.mounted) return;
      _applyRemotePasteResult(clip: clip, pasted: pasted);
      if (pasted.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.sftpPasted(pasted.length))));
      }
    } on sftp_copy.SftpRemotePastePartialFailure catch (e) {
      if (!context.mounted) return;
      _applyRemotePasteResult(clip: clip, pasted: e.pasted);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$e')));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  void _applyRemotePasteResult({
    required SftpRemoteClipboard clip,
    required List<String> pasted,
  }) {
    setState(() {
      if (clip.isCut) _setClipboard(null);
      if (pasted.isNotEmpty) {
        _selectedNames
          ..clear()
          ..addAll(pasted);
        _anchorName = pasted.first;
      }
    });
  }

  Future<void> _pickAndUploadFiles(BuildContext context) async {
    if (kIsWeb) return;
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      dialogTitle: AppLocalizations.of(context)!.sftpUploadFilesMenu,
    );
    if (result == null || !context.mounted) return;
    final paths = [
      for (final f in result.files)
        if (f.path != null && f.path!.isNotEmpty) f.path!,
    ];
    if (paths.isEmpty) return;
    await _onLocalPathsDropped(context, paths);
  }

  Future<void> _pickAndUploadFolder(BuildContext context) async {
    if (kIsWeb) return;
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: AppLocalizations.of(context)!.sftpUploadFolderMenu,
    );
    if (dir == null || dir.isEmpty || !context.mounted) return;
    await _onLocalPathsDropped(context, [dir]);
  }

  void _setLayoutMode(_SftpLayoutMode mode) {
    if (_layoutMode == mode) return;
    setState(() {
      _layoutMode = mode;
      _resetMarquee(notify: false);
    });
  }

  Future<void> _copySelectedPaths(BuildContext context) async {
    final names = _selectedInListOrder();
    if (names.isEmpty) return;
    final text = names.map((n) => remoteJoin(_c.remoteCwd, n)).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(names.length == 1 ? '已复制路径' : '已复制 ${names.length} 条路径')),
    );
  }

  void _beginPathBarEdit() {
    setState(() {
      _pathBarEditing = true;
      _pathCtrl.text = _c.remoteCwd;
      _pathCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _pathCtrl.text.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pathFocus.requestFocus();
    });
  }

  void _cancelPathBarEdit() {
    if (!_pathBarEditing) return;
    setState(() => _pathBarEditing = false);
    _requestFocus();
  }

  Future<void> _submitPathBar() async {
    final path = _pathCtrl.text.trim();
    setState(() => _pathBarEditing = false);
    if (path.isNotEmpty) {
      await _c.navigateToAbsolutePath(path);
    }
    if (mounted) _requestFocus();
  }

  Widget _sortHeaderCell({
    required String label,
    required SftpSortColumn column,
    TextAlign textAlign = TextAlign.start,
    required int? flex,
    double? width,
  }) {
    final active = _c.sortColumn == column;
    final arrow = !active
        ? ''
        : (_c.sortAscending ? ' ↑' : ' ↓');
    final style = TextStyle(
      fontSize: 10,
      color: active ? context.wb.accentBlue : context.wb.textMuted,
      fontWeight: FontWeight.w600,
    );
    final child = InkWell(
      onTap: () => _c.setSort(column),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          '$label$arrow',
          textAlign: textAlign,
          style: style,
        ),
      ),
    );
    if (flex != null) return Expanded(flex: flex, child: child);
    return SizedBox(width: width, child: child);
  }

  Widget _toolbarIconButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool selected = false,
  }) {
    final wb = context.wb;
    return IconButton(
      tooltip: tooltip,
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        minimumSize: const Size(30, 30),
        maximumSize: const Size(30, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      icon: Icon(
        icon,
        size: 18,
        color: selected ? wb.accentBlue : wb.textMuted,
      ),
    );
  }

  List<Widget> _toolbarTrailingActions(AppLocalizations l) {
    return [
      if (_selectedNames.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(
            l.sftpSelectionCount(_selectedNames.length),
            style: TextStyle(fontSize: 11, color: context.wb.textMuted),
          ),
        ),
      if (_selectedNames.isNotEmpty) ...[
        _toolbarIconButton(
          tooltip: l.sftpDownloadMenu,
          icon: Icons.download_rounded,
          onPressed: () => unawaited(_downloadSelected(context)),
        ),
        _toolbarIconButton(
          tooltip: l.sftpCopyMenu,
          icon: Icons.copy_rounded,
          onPressed: () => unawaited(_copySelected(context)),
        ),
        _toolbarIconButton(
          tooltip: l.sftpCutMenu,
          icon: Icons.content_cut_rounded,
          onPressed: () => unawaited(_cutSelected(context)),
        ),
        if (_selectedNames.length == 1)
          _toolbarIconButton(
            tooltip: l.sftpRenameMenu,
            icon: Icons.drive_file_rename_outline_rounded,
            onPressed: () => unawaited(_renameSelected(context)),
          ),
        if (widget.onAnalyzeDiskUsage != null &&
            _selectedNames.length == 1 &&
            (_entryByName(_selectedNames.first)?.attr.isDirectory ?? false))
          _toolbarIconButton(
            tooltip: l.sftpAnalyzeDiskUsageMenu,
            icon: Icons.pie_chart_outline_rounded,
            onPressed: () =>
                widget.onAnalyzeDiskUsage!(_selectedNames.first),
          ),
        _toolbarIconButton(
          tooltip: l.sftpDeleteMenu,
          icon: Icons.delete_outline_rounded,
          onPressed: () => unawaited(_confirmDeleteSelected(context)),
        ),
      ],
      if (_canPaste)
        _toolbarIconButton(
          tooltip: l.sftpPasteMenu,
          icon: Icons.content_paste_rounded,
          onPressed: () => unawaited(_pasteClipboard(context)),
        ),
      if (!kIsWeb) ...[
        _toolbarIconButton(
          tooltip: l.sftpUploadFilesMenu,
          icon: Icons.upload_file_outlined,
          onPressed: _c.loadingDir
              ? null
              : () => unawaited(_pickAndUploadFiles(context)),
        ),
        _toolbarIconButton(
          tooltip: l.sftpUploadFolderMenu,
          icon: Icons.drive_folder_upload_outlined,
          onPressed: _c.loadingDir
              ? null
              : () => unawaited(_pickAndUploadFolder(context)),
        ),
      ],
      _toolbarIconButton(
        tooltip: l.sftpNewFolderTooltip,
        icon: Icons.create_new_folder_outlined,
        onPressed: _c.loadingDir
            ? null
            : () => unawaited(_createNewFolder(context)),
      ),
      _toolbarIconButton(
        tooltip: l.sftpViewListTooltip,
        icon: Icons.view_list_rounded,
        selected: _layoutMode == _SftpLayoutMode.list,
        onPressed: () => _setLayoutMode(_SftpLayoutMode.list),
      ),
      _toolbarIconButton(
        tooltip: l.sftpViewGridTooltip,
        icon: Icons.grid_view_rounded,
        selected: _layoutMode == _SftpLayoutMode.grid,
        onPressed: () => _setLayoutMode(_SftpLayoutMode.grid),
      ),
      _toolbarIconButton(
        tooltip: '详情',
        icon: Icons.view_column_outlined,
        selected: _detailColumns,
        onPressed: () => setState(() => _detailColumns = !_detailColumns),
      ),
      _toolbarIconButton(
        tooltip: _c.showHidden ? '隐藏点文件' : '显示隐藏文件',
        icon: _c.showHidden
            ? Icons.visibility_rounded
            : Icons.visibility_off_outlined,
        selected: _c.showHidden,
        onPressed: () => _c.showHidden = !_c.showHidden,
      ),
      _toolbarIconButton(
        tooltip: l.sftpRefreshTooltip,
        icon: Icons.refresh_rounded,
        onPressed: _c.loadingDir ? null : () => _c.refreshDirectory(),
      ),
    ];
  }

  Widget _bookmarkStarButton() {
    final cwd = _c.remoteCwd.trim();
    final bookmarked = cwd.isNotEmpty && _bookmarkList.contains(cwd);
    return _toolbarIconButton(
      tooltip: bookmarked ? '取消书签' : '添加书签',
      icon: bookmarked ? Icons.star_rounded : Icons.star_outline_rounded,
      selected: bookmarked,
      onPressed: _bookmarks == null || cwd.isEmpty
          ? null
          : () => unawaited(_toggleBookmarkCurrent()),
    );
  }

  Widget _quickAccessButton() {
    final wb = context.wb;
    final bookmarks = _bookmarkList;
    final recent = _recentList
        .where((p) => !bookmarks.contains(p))
        .toList(growable: false);
    return PopupMenuButton<String>(
      tooltip: '快速访问',
      enabled: !_c.loadingDir,
      padding: EdgeInsets.zero,
      offset: const Offset(0, 32),
      style: IconButton.styleFrom(
        minimumSize: const Size(30, 30),
        maximumSize: const Size(30, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
      icon: Icon(Icons.bookmarks_outlined, size: 18, color: wb.textMuted),
      onSelected: (path) => unawaited(_navigateQuickAccess(path)),
      itemBuilder: (context) {
        if (bookmarks.isEmpty && recent.isEmpty) {
          return [
            PopupMenuItem<String>(
              enabled: false,
              child: Text(
                '暂无书签或最近路径',
                style: TextStyle(fontSize: 12, color: wb.textMuted),
              ),
            ),
          ];
        }
        return [
          if (bookmarks.isNotEmpty) ...[
            PopupMenuItem<String>(
              enabled: false,
              height: 28,
              child: Text(
                '书签',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: wb.textMuted,
                ),
              ),
            ),
            for (final path in bookmarks)
              PopupMenuItem<String>(
                value: path,
                child: Text(
                  path,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: wb.primaryText,
                  ),
                ),
              ),
          ],
          if (bookmarks.isNotEmpty && recent.isNotEmpty)
            const PopupMenuDivider(height: 8),
          if (recent.isNotEmpty) ...[
            PopupMenuItem<String>(
              enabled: false,
              height: 28,
              child: Text(
                '最近',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: wb.textMuted,
                ),
              ),
            ),
            for (final path in recent)
              PopupMenuItem<String>(
                value: path,
                child: Text(
                  path,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: wb.primaryText,
                  ),
                ),
              ),
          ],
        ];
      },
    );
  }

  Widget _toolbarPathBar(List<({String label, String path})> segs) {
    if (_pathBarEditing) {
      return SizedBox(
        height: 28,
        child: TextField(
          controller: _pathCtrl,
          focusNode: _pathFocus,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: context.wb.primaryText,
          ),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
            hintText: '绝对路径',
            hintStyle: TextStyle(
              color: context.wb.textMuted,
              fontSize: 12,
            ),
            filled: true,
            fillColor: context.wb.panelElevated,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: context.wb.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: context.wb.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: context.wb.accentBlue),
            ),
          ),
          onSubmitted: (_) => unawaited(_submitPathBar()),
        ),
      );
    }
    return GestureDetector(
      onDoubleTap: _beginPathBarEdit,
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
                    : () => _c.navigateToAbsolutePath(segs[i].path),
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
                      decoration: TextDecoration.underline,
                      decorationColor: context.wb.accentBlue,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _wrapEntryChrome({
    required BuildContext context,
    required SftpName entry,
    required Widget content,
  }) {
    final isDir = entry.attr.isDirectory;
    final selected = _selectedNames.contains(entry.filename);
    final clip = _clipboard;
    final cutDimmed =
        clip != null &&
        clip.isCut &&
        normalizeRemotePathForCompare(clip.sourceCwd) ==
            normalizeRemotePathForCompare(_c.remoteCwd) &&
        clip.names.contains(entry.filename);
    final dropOnto =
        isDir &&
        _dropTargetDirName != null &&
        _dropTargetDirName == entry.filename;
    final core = Builder(
      builder: (ctx2) {
        void openMenuAt(Offset g) {
          _requestFocus();
          _prepareSelectionForContextMenu(entry.filename);
          final selectedNow = _selectedInListOrder();
          final onlyOne = selectedNow.length == 1;
          final onlyFile =
              onlyOne && !isDir && selectedNow.first == entry.filename;
          _showEntryContextMenu(
            ctx2,
            g,
            onDownload: () => _downloadSelected(ctx2),
            onDelete: () => _confirmDeleteSelected(ctx2),
            onOpenInEditor: onlyFile
                ? () => _openOrEdit(ctx2, entry.filename, entry.attr)
                : null,
            onRename: onlyOne ? () => _renameSelected(ctx2) : null,
            onCopy: () => unawaited(_copySelected(ctx2)),
            onCut: () => unawaited(_cutSelected(ctx2)),
            onPaste: _canPaste ? () => _pasteClipboard(ctx2) : null,
            onCopyPath: () => _copySelectedPaths(ctx2),
            onAnalyzeDiskUsage: widget.onAnalyzeDiskUsage != null && isDir
                ? () => widget.onAnalyzeDiskUsage!(entry.filename)
                : null,
            onOpenTerminal: widget.onOpenTerminal == null
                ? null
                : () => widget.onOpenTerminal!(isDir ? entry.filename : null),
            onProperties: onlyOne
                ? () => _showProperties(ctx2, entry.filename)
                : null,
            onCompress: selectedNow.isNotEmpty
                ? () => _compressSelected(ctx2)
                : null,
            onExtract: onlyOne && _isArchiveName(entry.filename)
                ? () => _extractArchive(ctx2, entry.filename)
                : null,
          );
        }

        return GestureDetector(
          onSecondaryTapUp: (d) => openMenuAt(d.globalPosition),
          child: Material(
            color: dropOnto
                ? context.wb.accentBlue.withValues(alpha: 0.28)
                : selected
                ? context.wb.accentBlue.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: _layoutMode == _SftpLayoutMode.grid
                ? BorderRadius.circular(8)
                : BorderRadius.zero,
            child: InkWell(
              borderRadius: _layoutMode == _SftpLayoutMode.grid
                  ? BorderRadius.circular(8)
                  : BorderRadius.zero,
              onTap: () {
                _requestFocus();
                _applySelectionTap(
                  entry.filename,
                  additive: _sftpMetaOrControlPressed(),
                  range: _sftpShiftPressed(),
                );
              },
              onDoubleTap: () {
                _requestFocus();
                unawaited(_activateEntry(ctx2, entry));
              },
              child: Opacity(opacity: cutDimmed ? 0.45 : 1, child: content),
            ),
          ),
        );
      },
    );

    // GlobalKey 必须在 DragItemWidget / WidgetSnapshotter 之外。
    // 快照会临时重建子树；若 Key 在快照子树内会出现重复 GlobalKey，
    // 进而触发 InheritedElement `_dependents.isEmpty` 断言。
    final Widget body;
    if (_sftpDesktopDragOutSupported()) {
      final dragNames = selected && _selectedNames.length > 1
          ? _selectedInListOrder()
          : [entry.filename];
      body = _SftpRemoteEntryDragWrap(
        controller: _c,
        relativeName: entry.filename,
        dragRelativeNames: dragNames,
        isDirectory: isDir,
        pickerContext: context,
        child: core,
      );
    } else {
      body = core;
    }
    return KeyedSubtree(key: _rowKeyFor(entry.filename), child: body);
  }

  Widget _buildListEntry(
    BuildContext context,
    SftpName entry, {
    required bool useBeijingMtime,
  }) {
    final isDir = entry.attr.isDirectory;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
              color: isDir ? context.wb.folder : context.wb.textMuted,
              size: 16,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            flex: 5,
            child: Text(
              entry.filename,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: context.wb.secondaryText,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_detailColumns) ...[
            SizedBox(
              width: 82,
              child: Text(
                _formatSftpMode(entry.attr.mode),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: context.wb.textMuted,
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 72,
              child: Text(
                _formatSftpOwner(entry.attr),
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: context.wb.textMuted,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          SizedBox(
            width: 64,
            child: Text(
              isDir ? '—' : _formatRemoteBytes(entry.attr.size),
              textAlign: TextAlign.end,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: context.wb.textMuted,
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 108,
            child: Text(
              _formatUnixMtime(entry.attr.modifyTime, useBeijingMtime),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: context.wb.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
    return _wrapEntryChrome(context: context, entry: entry, content: content);
  }

  Widget _buildGridEntry(BuildContext context, SftpName entry) {
    final isDir = entry.attr.isDirectory;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
            color: isDir ? context.wb.folder : context.wb.textMuted,
            size: 40,
          ),
          const SizedBox(height: 6),
          Text(
            entry.filename,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              height: 1.2,
              color: context.wb.secondaryText,
            ),
          ),
        ],
      ),
    );
    return _wrapEntryChrome(context: context, entry: entry, content: content);
  }

  /// 列表行固定高度（含底部分隔线视觉），不随窗口拉高。
  static const double _listRowExtent = 30;

  /// 宫格固定高度；勿用 childAspectRatio，否则单列变宽时格子会被拉高占满，
  /// 空白处消失，无法右键新建/粘贴。
  static const double _gridCellExtent = 96;

  Widget _buildEntriesScrollView({
    required BuildContext context,
    required bool useBeijingMtime,
  }) {
    // CustomScrollView + FillRemaining：内容不足一屏时底部留白可点，
    // 用于空白右键 / 框选；条目本身高度固定，不随视口拉伸。
    if (_layoutMode == _SftpLayoutMode.grid) {
      return CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 108,
                mainAxisExtent: _gridCellExtent,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _buildGridEntry(context, _c.entries[i]),
                childCount: _c.entries.length,
              ),
            ),
          ),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: SizedBox.expand(),
          ),
        ],
      );
    }

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          sliver: SliverFixedExtentList(
            itemExtent: _listRowExtent,
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final entry = _c.entries[i];
                return DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: context.wb.border, width: 1),
                    ),
                  ),
                  child: _buildListEntry(
                    context,
                    entry,
                    useBeijingMtime: useBeijingMtime,
                  ),
                );
              },
              childCount: _c.entries.length,
            ),
          ),
        ),
        const SliverFillRemaining(
          hasScrollBody: false,
          child: SizedBox.expand(),
        ),
      ],
    );
  }

  Widget _buildEntriesPane({
    required BuildContext context,
    required bool useBeijingMtime,
  }) {
    final wb = context.wb;
    final marquee = _marqueePaintRect;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onMarqueePointerDown,
      onPointerMove: _onMarqueePointerMove,
      onPointerUp: _onMarqueePointerUp,
      onPointerCancel: _onMarqueePointerCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _requestFocus();
          if (_suppressClearFromTap) {
            _suppressClearFromTap = false;
            return;
          }
          _clearSelection();
        },
        onSecondaryTapUp: (d) {
          _requestFocus();
          // 点在条目上时由条目自己的右键菜单处理。
          if (_hitTestRowName(d.globalPosition) != null) return;
          _showBlankContextMenu(
            context,
            d.globalPosition,
            onNewFile: () => _createNewFile(context),
            onNewFolder: () => _createNewFolder(context),
            onSelectAll: _selectAll,
            onRefresh: () => _c.refreshDirectory(),
            onPaste: _canPaste ? () => _pasteClipboard(context) : null,
            onUploadFiles: kIsWeb ? null : () => _pickAndUploadFiles(context),
            onUploadFolder: kIsWeb ? null : () => _pickAndUploadFolder(context),
            onAnalyzeDiskUsage: widget.onAnalyzeDiskUsage == null
                ? null
                : () => widget.onAnalyzeDiskUsage!(null),
            onOpenTerminal: widget.onOpenTerminal == null
                ? null
                : () => widget.onOpenTerminal!(null),
          );
        },
        child: Stack(
          key: _listStackKey,
          children: [
            Positioned.fill(
              child: _buildEntriesScrollView(
                context: context,
                useBeijingMtime: useBeijingMtime,
              ),
            ),
            if (marquee != null)
              Positioned.fromRect(
                rect: marquee,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: wb.accentBlue.withValues(alpha: 0.12),
                      border: Border.all(color: wb.accentBlue, width: 1),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Map<ShortcutActivator, Intent> _shortcutMap() {
    return <ShortcutActivator, Intent>{
      for (final a in workbenchMetaOrControl(LogicalKeyboardKey.keyA))
        a: const _SelectAllIntent(),
      for (final a in workbenchMetaOrControl(
        LogicalKeyboardKey.keyN,
        shift: true,
      ))
        a: const _NewFolderIntent(),
      for (final a in workbenchMetaOrControl(LogicalKeyboardKey.keyC))
        a: const _CopySelectionIntent(),
      for (final a in workbenchMetaOrControl(LogicalKeyboardKey.keyX))
        a: const _CutSelectionIntent(),
      for (final a in workbenchMetaOrControl(LogicalKeyboardKey.keyV))
        a: const _PasteClipboardIntent(),
      for (final a in workbenchMetaOrControl(LogicalKeyboardKey.keyL))
        a: const _GoToPathIntent(),
      const SingleActivator(LogicalKeyboardKey.escape):
          const _ClearSelectionIntent(),
      const SingleActivator(LogicalKeyboardKey.delete):
          const _DeleteSelectionIntent(),
      const SingleActivator(LogicalKeyboardKey.backspace):
          const _DeleteSelectionIntent(),
      const SingleActivator(LogicalKeyboardKey.f2):
          const _RenameSelectionIntent(),
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
                  if (_pathBarEditing) {
                    _cancelPathBarEdit();
                    return null;
                  }
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
              _RenameSelectionIntent: CallbackAction<_RenameSelectionIntent>(
                onInvoke: (_) {
                  if (_selectedNames.length == 1) {
                    unawaited(_renameSelected(context));
                  }
                  return null;
                },
              ),
              _NewFolderIntent: CallbackAction<_NewFolderIntent>(
                onInvoke: (_) {
                  unawaited(_createNewFolder(context));
                  return null;
                },
              ),
              _CopySelectionIntent: CallbackAction<_CopySelectionIntent>(
                onInvoke: (_) {
                  if (_selectedNames.isNotEmpty) {
                    unawaited(_copySelected(context));
                  }
                  return null;
                },
              ),
              _CutSelectionIntent: CallbackAction<_CutSelectionIntent>(
                onInvoke: (_) {
                  if (_selectedNames.isNotEmpty) {
                    unawaited(_cutSelected(context));
                  }
                  return null;
                },
              ),
              _PasteClipboardIntent: CallbackAction<_PasteClipboardIntent>(
                onInvoke: (_) {
                  unawaited(_pasteClipboard(context));
                  return null;
                },
              ),
              _GoToPathIntent: CallbackAction<_GoToPathIntent>(
                onInvoke: (_) {
                  if (_pathBarEditing) {
                    _pathFocus.requestFocus();
                    _pathCtrl.selection = TextSelection(
                      baseOffset: 0,
                      extentOffset: _pathCtrl.text.length,
                    );
                  } else {
                    _beginPathBarEdit();
                  }
                  return null;
                },
              ),
            },
            child: Focus(
              focusNode: _focusNode,
              child: TapRegion(
                groupId: widget.tapRegionGroupId,
                child: SizedBox.expand(
                  child: Material(
                    color: context.wb.panel,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 10, 4, 4),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              // Path expands; bookmark / quick-access / trailing
                              // actions share one capped horizontal strip so the
                              // outer Row never overflows (plan 2.7 — narrow
                              // file-manager windows, e.g. ~288px content width).
                              const navWidth = 30.0 * 3;
                              const pathMinWidth = 72.0;
                              final actionsMax = math.max(
                                0.0,
                                constraints.maxWidth - navWidth - pathMinWidth,
                              );
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  _toolbarIconButton(
                                    tooltip: '返回',
                                    icon: Icons.arrow_back_rounded,
                                    onPressed:
                                        !_c.canGoBack || _c.loadingDir
                                        ? null
                                        : () => unawaited(_c.goBack()),
                                  ),
                                  _toolbarIconButton(
                                    tooltip: '前进',
                                    icon: Icons.arrow_forward_rounded,
                                    onPressed:
                                        !_c.canGoForward || _c.loadingDir
                                        ? null
                                        : () => unawaited(_c.goForward()),
                                  ),
                                  _toolbarIconButton(
                                    tooltip: '上级',
                                    icon: Icons.arrow_upward_rounded,
                                    onPressed: !_c.canGoUp || _c.loadingDir
                                        ? null
                                        : () => unawaited(_c.navigateUp()),
                                  ),
                                  Expanded(child: _toolbarPathBar(segs)),
                                  SizedBox(
                                    height: 34,
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: actionsMax,
                                      ),
                                      child: ListView(
                                        scrollDirection: Axis.horizontal,
                                        shrinkWrap: true,
                                        primary: false,
                                        padding: EdgeInsets.zero,
                                        children: [
                                          _bookmarkStarButton(),
                                          _quickAccessButton(),
                                          ..._toolbarTrailingActions(l),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        Divider(height: 1, color: context.wb.border),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _searchCtrl,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.wb.primaryText,
                                    fontFamily: 'monospace',
                                  ),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    hintText: _searchContent
                                        ? '搜索文件内容（grep）'
                                        : '搜索文件名（find）',
                                    hintStyle: TextStyle(
                                      color: context.wb.textMuted,
                                      fontSize: 12,
                                    ),
                                    prefixIcon: Icon(
                                      Icons.search_rounded,
                                      size: 16,
                                      color: context.wb.textMuted,
                                    ),
                                    prefixIconConstraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 0,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 8,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                  ),
                                  onSubmitted: (_) => unawaited(_runSearch()),
                                ),
                              ),
                              const SizedBox(width: 4),
                              SizedBox(
                                height: 30,
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<int>(
                                    value: _searchMaxDepth,
                                    isDense: true,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: context.wb.primaryText,
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                        value: 2,
                                        child: Text('深2'),
                                      ),
                                      DropdownMenuItem(
                                        value: 4,
                                        child: Text('深4'),
                                      ),
                                      DropdownMenuItem(
                                        value: 6,
                                        child: Text('深6'),
                                      ),
                                    ],
                                    onChanged: _searching
                                        ? null
                                        : (v) {
                                            if (v == null) return;
                                            setState(() => _searchMaxDepth = v);
                                          },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              FilterChip(
                                label: const Text(
                                  '搜内容',
                                  style: TextStyle(fontSize: 11),
                                ),
                                selected: _searchContent,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                onSelected: _searching
                                    ? null
                                    : (v) =>
                                        setState(() => _searchContent = v),
                              ),
                              const SizedBox(width: 4),
                              if (_searching) ...[
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                TextButton(
                                  onPressed: _cancelSearch,
                                  child: const Text('取消'),
                                ),
                              ] else
                                TextButton(
                                  onPressed: () => unawaited(_runSearch()),
                                  child: const Text('搜索'),
                                ),
                              if (_searchHits.isNotEmpty ||
                                  _searchError != null)
                                TextButton(
                                  onPressed: () => setState(() {
                                    _searchHits = const [];
                                    _searchError = null;
                                    _searchTruncated = false;
                                    _searchCtrl.clear();
                                  }),
                                  child: const Text('清除'),
                                ),
                            ],
                          ),
                        ),
                        if (_searchError != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                            child: Text(
                              _searchError!,
                              style: TextStyle(
                                color: context.wb.offline,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        if (_searchTruncated && _searchHits.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                            child: Text(
                              '已截断，仅前 80 项',
                              style: TextStyle(
                                color: context.wb.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        if (_searchHits.isNotEmpty)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 140),
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: _searchHits.length,
                              itemBuilder: (context, i) {
                                final hit = _searchHits[i];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    Icons.insert_drive_file_outlined,
                                    size: 16,
                                    color: context.wb.textMuted,
                                  ),
                                  title: Text(
                                    hit,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      color: context.wb.primaryText,
                                    ),
                                  ),
                                  onTap: () => unawaited(_openSearchHit(hit)),
                                );
                              },
                            ),
                          ),
                        Expanded(
                          child: DropTarget(
                            onDragEntered: (details) {
                              widget.onActivate?.call();
                              _updateDropTargetHighlight(
                                details.globalPosition,
                                show: true,
                              );
                            },
                            onDragUpdated: (details) {
                              _updateDropTargetHighlight(
                                details.globalPosition,
                                show: true,
                              );
                            },
                            onDragExited: (_) =>
                                _updateDropTargetHighlight(
                                  Offset.zero,
                                  show: false,
                                ),
                            onDragDone: (detail) async {
                              final destDirName = _dropTargetDirName;
                              setState(() {
                                _dropHighlight = false;
                                _dropTargetDirName = null;
                              });
                              final wasInternalDrag =
                                  SftpBrowser.isDraggingInternalItem;
                              if (kIsWeb) return;

                              final destCwd = destDirName != null
                                  ? remoteJoin(_c.remoteCwd, destDirName)
                                  : _c.remoteCwd;

                              final remotePaths = resolveDesktopDropRemotePaths(
                                detail,
                                isInternalDrag: wasInternalDrag,
                              );
                              if (remotePaths.isNotEmpty) {
                                await _onRemotePathsDropped(
                                  context,
                                  remotePaths,
                                  destCwd: destCwd,
                                );
                                return;
                              }

                              // 本机文件拖入上传；忽略未映射到远端的拖出临时副本。
                              final paths = <String>[];
                              for (final f in detail.files) {
                                final path = f.path;
                                if (path.isEmpty) continue;
                                if (SshWorkspaceController
                                    .isPathFromRecentDragOut(path)) {
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
                              // 仅在尚无列表时整页 loading / error；刷新时保留旧项。
                              child: RemoteStateView(
                                state: _c.loadingDir && _c.entries.isEmpty
                                    ? RemoteState.loading
                                    : (_c.loadError != null &&
                                            _c.entries.isEmpty)
                                        ? RemoteState.error
                                        : RemoteState.data,
                                message: _c.loadError,
                                onRetry: _c.loadError != null
                                    ? () => unawaited(_c.refreshDirectory())
                                    : null,
                                data: Column(
                                      children: [
                                        if (_layoutMode ==
                                            _SftpLayoutMode.list) ...[
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
                                                _sortHeaderCell(
                                                  label: l.sftpColumnName,
                                                  column: SftpSortColumn.name,
                                                  flex: 5,
                                                ),
                                                if (_detailColumns) ...[
                                                  SizedBox(
                                                    width: 82,
                                                    child: Text(
                                                      '权限',
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        color: context
                                                            .wb.textMuted,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  SizedBox(
                                                    width: 72,
                                                    child: Text(
                                                      '所有者',
                                                      textAlign:
                                                          TextAlign.end,
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        color: context
                                                            .wb.textMuted,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                ],
                                                _sortHeaderCell(
                                                  label: l.sftpColumnSize,
                                                  column: SftpSortColumn.size,
                                                  textAlign: TextAlign.end,
                                                  flex: null,
                                                  width: 64,
                                                ),
                                                const SizedBox(width: 6),
                                                _sortHeaderCell(
                                                  label: l.sftpColumnModified,
                                                  column: SftpSortColumn.mtime,
                                                  flex: null,
                                                  width: 108,
                                                ),
                                              ],
                                            ),
                                          ),
                                          Divider(
                                            height: 1,
                                            color: context.wb.border,
                                          ),
                                        ],
                                        Expanded(
                                          child: _buildEntriesPane(
                                            context: context,
                                            useBeijingMtime: useBeijingMtime,
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
                                              batchSucceeded:
                                                  _c.uploadTasks.batchSucceeded,
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
                        ),
                      ],
                    ),
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

/// 拥有 [TextEditingController] 生命周期，避免 dialog 关闭动画期间 dispose 后仍被监听。
class _RemoteNamePromptDialog extends StatefulWidget {
  const _RemoteNamePromptDialog({
    required this.title,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.fieldLabel,
    required this.invalidNameMessage,
    required this.isValidName,
    this.initialValue,
    this.hintText,
  });

  final String title;
  final String confirmLabel;
  final String cancelLabel;
  final String fieldLabel;
  final String invalidNameMessage;
  final bool Function(String name) isValidName;
  final String? initialValue;
  final String? hintText;

  @override
  State<_RemoteNamePromptDialog> createState() =>
      _RemoteNamePromptDialogState();
}

class _RemoteNamePromptDialogState extends State<_RemoteNamePromptDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (!widget.isValidName(name)) {
      setState(() => _error = widget.invalidNameMessage);
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.fieldLabel,
          hintText: widget.hintText,
          errorText: _error,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _SftpPropertiesDialog extends StatefulWidget {
  const _SftpPropertiesDialog({
    required this.path,
    required this.size,
    required this.owner,
    required this.group,
    required this.kind,
    required this.mtimeSec,
    required this.initialMode,
    required this.onChmod,
  });

  final String path;
  final int? size;
  final String owner;
  final String group;
  final String kind;
  final int? mtimeSec;
  final int initialMode;
  final Future<bool> Function(String octal) onChmod;

  @override
  State<_SftpPropertiesDialog> createState() => _SftpPropertiesDialogState();
}

class _SftpPropertiesDialogState extends State<_SftpPropertiesDialog> {
  late int _mode;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
  }

  bool _bit(int mask) => (_mode & mask) != 0;

  void _toggle(int mask, bool on) {
    setState(() {
      _mode = on ? (_mode | mask) : (_mode & ~mask);
    });
  }

  String get _octal => (_mode & 0x1FF).toRadixString(8).padLeft(3, '0');

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final mtime = widget.mtimeSec == null
        ? '—'
        : DateTime.fromMillisecondsSinceEpoch(widget.mtimeSec! * 1000)
            .toLocal()
            .toString();
    return AlertDialog(
      backgroundColor: wb.panelElevated,
      title: Text('属性', style: TextStyle(color: wb.primaryText)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.path,
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: wb.secondaryText)),
            const SizedBox(height: 10),
            Text('类型：${widget.kind.isEmpty ? "—" : widget.kind}',
                style: TextStyle(color: wb.primaryText, fontSize: 13)),
            Text('大小：${_formatRemoteBytes(widget.size)}',
                style: TextStyle(color: wb.primaryText, fontSize: 13)),
            Text('所有者：${widget.owner}  组：${widget.group}',
                style: TextStyle(color: wb.primaryText, fontSize: 13)),
            Text('修改时间：$mtime',
                style: TextStyle(color: wb.primaryText, fontSize: 13)),
            const SizedBox(height: 12),
            Text('权限 ($_octal)',
                style: TextStyle(color: wb.secondaryText, fontSize: 12)),
            const SizedBox(height: 4),
            _permRow('所有者', 0x100, 0x080, 0x040),
            _permRow('组', 0x020, 0x010, 0x008),
            _permRow('其他', 0x004, 0x002, 0x001),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(color: wb.offline, fontSize: 12)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: _saving
              ? null
              : () async {
                  setState(() {
                    _saving = true;
                    _error = null;
                  });
                  final ok = await widget.onChmod(_octal);
                  if (!context.mounted) return;
                  setState(() => _saving = false);
                  if (ok) {
                    Navigator.pop(context);
                  } else {
                    setState(() => _error = 'chmod 失败（可能需要权限）');
                  }
                },
          child: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('应用权限'),
        ),
      ],
    );
  }

  Widget _permRow(String label, int r, int w, int x) {
    final wb = context.wb;
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(label, style: TextStyle(color: wb.primaryText, fontSize: 12)),
        ),
        Checkbox(
          value: _bit(r),
          onChanged: (v) => _toggle(r, v ?? false),
          visualDensity: VisualDensity.compact,
        ),
        Text('读', style: TextStyle(color: wb.textMuted, fontSize: 11)),
        Checkbox(
          value: _bit(w),
          onChanged: (v) => _toggle(w, v ?? false),
          visualDensity: VisualDensity.compact,
        ),
        Text('写', style: TextStyle(color: wb.textMuted, fontSize: 11)),
        Checkbox(
          value: _bit(x),
          onChanged: (v) => _toggle(x, v ?? false),
          visualDensity: VisualDensity.compact,
        ),
        Text('执行', style: TextStyle(color: wb.textMuted, fontSize: 11)),
      ],
    );
  }
}
