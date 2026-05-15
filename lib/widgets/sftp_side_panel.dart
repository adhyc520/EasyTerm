import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../l10n/app_localizations.dart';
import '../screens/remote_editor_screen.dart';
import '../services/sftp_fs_transfer.dart' as sftp_transfer;
import '../services/ssh_workspace_controller.dart';
import '../services/sftp_planned_upload.dart';
import '../services/sftp_upload_task_list.dart';
import '../theme/workbench_theme.dart';
import '../util/remote_paths.dart';

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
  final d = useBeijingWallClock ? utc.add(const Duration(hours: 8)) : utc.toLocal();
  return '${d.year}-${_z2(d.month)}-${_z2(d.day)} ${_z2(d.hour)}:${_z2(d.minute)}';
}

/// (显示名, 绝对路径)
List<({String label, String path})> _breadcrumbSegments(String cwd, String rootLabel) {
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
  final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
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
        child: Text(l.sftpDeleteMenu, style: TextStyle(color: Colors.red.shade300)),
      ),
    ],
  ).then((v) async {
    if (v == 'open' && onOpenInEditor != null) await onOpenInEditor();
    if (v == 'dl') await onDownload();
    if (v == 'del') await onDelete();
  });
}

/// 将远程文件以系统原生拖放导出到 Finder / 资源管理器等（虚拟文件流式拉取）。
class _SftpRemoteFileDragWrap extends StatelessWidget {
  const _SftpRemoteFileDragWrap({
    required this.controller,
    required this.relativeName,
    required this.child,
  });

  final SshWorkspaceController controller;
  final String relativeName;
  final Widget child;

  Future<DragItem?> _dragItemProvider(DragItemRequest request) async {
    final client = controller.sftp;
    if (client == null) return null;
    final remotePath = remoteJoin(controller.remoteCwd, relativeName);
    final st = await client.stat(remotePath);
    if (st.isDirectory) return null;
    final nameOnly = remoteBasename(relativeName);
    final sizeBytes = st.size ?? 0;
    final probe = DragItem(suggestedName: nameOnly);
    if (!probe.virtualFileSupported) {
      try {
        final path = await controller.materializeRemoteFileToTempForDrag(relativeName);
        final item = DragItem(suggestedName: nameOnly);
        item.add(Formats.fileUri(Uri.file(path)));
        item.onDisposed.addListener(() => sftp_transfer.deleteLocalFileQuiet(path));
        return item;
      } catch (_) {
        return null;
      }
    }
    final item = DragItem(suggestedName: nameOnly);
    final format = _sftpDragFileFormatForName(relativeName);
    item.addVirtualFile(
      format: format,
      provider: (sinkProvider, progress) {
        final sink = sinkProvider(fileSize: sizeBytes);
        unawaited(
          controller.streamRemoteFileIntoDragSink(
            relativeName: relativeName,
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
    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy],
      dragItemProvider: _dragItemProvider,
      child: DraggableWidget(child: child),
    );
  }
}

class SftpSidePanel extends StatefulWidget {
  const SftpSidePanel({super.key, required this.controller});

  final SshWorkspaceController controller;

  @override
  State<SftpSidePanel> createState() => _SftpSidePanelState();
}

class _SftpSidePanelState extends State<SftpSidePanel> {
  bool _dropHighlight = false;
  bool _uploadQueueExpanded = false;

  SshWorkspaceController get _c => widget.controller;

  Future<void> _downloadEntry(BuildContext context, String name, {required bool isDirectory}) async {
    final l = AppLocalizations.of(context)!;
    try {
      if (isDirectory) {
        final parent = await FilePicker.getDirectoryPath(dialogTitle: l.sftpPickDirTitle);
        if (parent == null || !context.mounted) return;
        await _c.downloadRemoteDirectoryToLocal(name, parent);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.sftpDownloadedDir(name))));
        }
      } else {
        final out = await FilePicker.saveFile(
          dialogTitle: l.sftpSaveFileTitle,
          fileName: remoteBasename(name),
        );
        if (out == null || !context.mounted) return;
        await _c.downloadRemoteFileToLocalPath(name, out);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.sftpDownloadedFile(name))));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _onLocalPathsDropped(BuildContext context, List<String> paths) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l = AppLocalizations.of(context)!;
    for (final path in paths) {
      if (path.isEmpty) continue;
      try {
        await _uploadOnePathWithOverwriteCheck(context, path);
      } catch (e) {
        messenger?.showSnackBar(SnackBar(content: Text(l.sftpUploadFailed('$e'))));
      }
    }
  }

  Future<void> _uploadOnePathWithOverwriteCheck(BuildContext context, String localPath) async {
    if (kIsWeb) return;
    final l = AppLocalizations.of(context)!;
    final conflict = await _c.inspectLocalUploadConflict(localPath);
    if (!context.mounted) return;
    switch (conflict) {
      case SftpRemoteUploadConflict.typeMismatch:
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l.sftpUploadConflictTypeMismatchTitle),
            content: Text(l.sftpUploadConflictTypeMismatchBody(p.basename(localPath))),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.sftpCancel)),
            ],
          ),
        );
        return;
      case SftpRemoteUploadConflict.existsReplaceable:
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l.sftpUploadOverwriteTitle),
            content: Text(l.sftpUploadOverwriteBody(p.basename(localPath))),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.sftpCancel)),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.sftpUploadOverwriteConfirm)),
            ],
          ),
        );
        if (ok != true || !context.mounted) return;
        await _c.removeRemoteSubtreeForOverwrite(p.basename(localPath));
      case SftpRemoteUploadConflict.none:
        break;
    }
    if (!context.mounted) return;
    await _c.uploadLocalFsPath(localPath);
  }

  Future<void> _openOrEdit(BuildContext context, String name, SftpFileAttrs attr) async {
    final l = AppLocalizations.of(context)!;
    if (!attr.isFile) return;
    try {
      final bytes = await _c.readRemoteFile(name);
      if (bytes == null || !context.mounted) return;
      if (!looksLikeTextBytes(bytes)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.sftpBinaryNotOpened)),
        );
        return;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final mtime = await _c.remoteMtime(name);
      if (!context.mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RemoteEditorScreen(
            controller: _c,
            fileName: name,
            initialText: text,
            initialRemoteMtime: mtime,
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _confirmDelete(BuildContext context, String name) async {
    final l = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.sftpDeleteConfirmTitle),
        content: Text(l.sftpDeleteConfirmBody(name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.sftpCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.sftpDeleteConfirm)),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await _c.deleteRemote(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final l = AppLocalizations.of(context)!;
        final useBeijingMtime = Localizations.localeOf(context).languageCode == 'zh';
        final segs = _breadcrumbSegments(_c.remoteCwd, l.sftpBreadcrumbRoot);
        return SizedBox.expand(
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
                                    style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: context.wb.textMuted),
                                  ),
                                InkWell(
                                  onTap: _c.loadingDir
                                      ? null
                                      : () {
                                          _c.navigateToAbsolutePath(segs[i].path);
                                        },
                                  borderRadius: BorderRadius.circular(4),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
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
                      ),
                      IconButton(
                        tooltip: l.sftpRefreshTooltip,
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                        padding: EdgeInsets.zero,
                        onPressed: _c.loadingDir ? null : () => _c.refreshDirectory(),
                        icon: Icon(Icons.refresh_rounded, size: 18, color: context.wb.textMuted),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: context.wb.border),
                Expanded(
                  child: DropTarget(
                    onDragEntered: (_) => setState(() => _dropHighlight = true),
                    onDragExited: (_) => setState(() => _dropHighlight = false),
                    onDragDone: (detail) async {
                      setState(() => _dropHighlight = false);
                      if (kIsWeb) return;
                      final paths = <String>[];
                      for (final f in detail.files) {
                        final path = f.path;
                        if (path.isNotEmpty) paths.add(path);
                      }
                      if (paths.isEmpty) return;
                      await _onLocalPathsDropped(context, paths);
                    },
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _dropHighlight
                            ? context.wb.accentBlue.withValues(alpha: 0.08)
                            : Colors.transparent,
                      ),
                      child: _c.loadingDir
                          ? Center(child: CircularProgressIndicator(color: context.wb.accentBlue))
                          : Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
                                  child: Row(
                                    children: [
                                      const SizedBox(width: 22),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        flex: 5,
                                        child: Text(
                                          l.sftpColumnName,
                                          style: TextStyle(fontSize: 10, color: context.wb.textMuted, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 64,
                                        child: Text(
                                          l.sftpColumnSize,
                                          textAlign: TextAlign.end,
                                          style: TextStyle(fontSize: 10, color: context.wb.textMuted, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      SizedBox(
                                        width: 108,
                                        child: Text(
                                          l.sftpColumnModified,
                                          style: TextStyle(fontSize: 10, color: context.wb.textMuted, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Divider(height: 1, color: context.wb.border),
                                Expanded(
                                  child: ListView.separated(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    itemCount: _c.entries.length,
                                    separatorBuilder: (context, _) => Divider(height: 1, color: context.wb.border),
                                    itemBuilder: (context, i) {
                                      final e = _c.entries[i];
                                      final isDir = e.attr.isDirectory;
                                      final rowCore = Builder(
                                        builder: (ctx2) {
                                          void openMenuAt(Offset g) {
                                            _showEntryContextMenu(
                                              ctx2,
                                              g,
                                              onDownload: () => _downloadEntry(ctx2, e.filename, isDirectory: isDir),
                                              onDelete: () => _confirmDelete(ctx2, e.filename),
                                              onOpenInEditor: isDir
                                                  ? null
                                                  : () => _openOrEdit(ctx2, e.filename, e.attr),
                                            );
                                          }

                                          return GestureDetector(
                                            onSecondaryTapUp: (d) => openMenuAt(d.globalPosition),
                                            onLongPress: () {
                                              final box = ctx2.findRenderObject() as RenderBox?;
                                              if (box == null) return;
                                              openMenuAt(box.localToGlobal(Offset(box.size.width / 2, box.size.height / 2)));
                                            },
                                            child: InkWell(
                                              onTap: isDir ? () => _c.navigateInto(e.filename) : null,
                                              onDoubleTap: isDir
                                                  ? null
                                                  : () => _openOrEdit(ctx2, e.filename, e.attr),
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
                                                      color: isDir ? context.wb.folder : context.wb.textMuted,
                                                      size: 16,
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Expanded(
                                                      flex: 5,
                                                      child: Text(
                                                        e.filename,
                                                        style: TextStyle(
                                                          fontFamily: 'monospace',
                                                          fontSize: 11,
                                                          color: context.wb.secondaryText,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                    SizedBox(
                                                      width: 64,
                                                      child: Text(
                                                        isDir ? '—' : _formatRemoteBytes(e.attr.size),
                                                        textAlign: TextAlign.end,
                                                        style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: context.wb.textMuted),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    SizedBox(
                                                      width: 108,
                                                      child: Text(
                                                        _formatUnixMtime(e.attr.modifyTime, useBeijingMtime),
                                                        style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: context.wb.textMuted),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      );

                                      if (!isDir && _sftpDesktopDragOutSupported()) {
                                        return _SftpRemoteFileDragWrap(
                                          controller: _c,
                                          relativeName: e.filename,
                                          child: rowCore,
                                        );
                                      }
                                      return rowCore;
                                    },
                                  ),
                                ),
                                ListenableBuilder(
                                  listenable: _c.uploadTasks,
                                  builder: (context, _) {
                                    final tasks = _c.uploadTasks.items;
                                    if (tasks.isEmpty) {
                                      if (_uploadQueueExpanded) {
                                        WidgetsBinding.instance.addPostFrameCallback((_) {
                                          if (!mounted) return;
                                          setState(() => _uploadQueueExpanded = false);
                                        });
                                      }
                                      return const SizedBox.shrink();
                                    }
                                    return _SftpUploadQueueFooter(
                                      tasks: tasks,
                                      batchSucceeded: _c.uploadTasks.batchSucceeded,
                                      batchTotal: _c.uploadTasks.batchTotal,
                                      expanded: _uploadQueueExpanded,
                                      onToggleExpand: () => setState(() => _uploadQueueExpanded = !_uploadQueueExpanded),
                                      formatBytes: _formatByteCount,
                                      onCancelFile: _c.uploadTasks.userCancelFile,
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
  });

  final List<SftpUploadTaskView> tasks;
  final int batchSucceeded;
  final int batchTotal;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final String Function(int bytes) formatBytes;
  final void Function(String fileId) onCancelFile;

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
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: wb.secondaryText),
                ),
              ),
              if (n > 1)
                IconButton(
                  tooltip: expanded ? l.sftpUploadQueueCollapse : l.sftpUploadQueueExpand,
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  visualDensity: VisualDensity.compact,
                  onPressed: onToggleExpand,
                  icon: Icon(
                    expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    color: wb.textMuted,
                  ),
                ),
            ],
          ),
        ),
        if (!expanded)
          _SftpUploadTaskRow(task: tasks.first, formatBytes: formatBytes, onCancelFile: onCancelFile)
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
    final canCancel = task.state == SftpUploadRowState.pending || task.state == SftpUploadRowState.uploading;

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
                task.direction == SftpTransferDirection.upload ? Icons.upload_rounded : Icons.download_rounded,
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
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: wb.secondaryText),
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progressValue,
                    minHeight: 3,
                    backgroundColor: wb.border,
                    color: err != null ? const Color(0xFFEF4444) : wb.accentBlue,
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
