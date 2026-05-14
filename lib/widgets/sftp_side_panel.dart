import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../screens/remote_editor_screen.dart';
import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';
import '../util/remote_paths.dart';

String _formatRemoteBytes(int? bytes) {
  if (bytes == null) return '—';
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
      PopupMenuItem(value: 'dl', child: Text(l.sftpDownloadMenu)),
      PopupMenuItem(
        value: 'del',
        child: Text(l.sftpDeleteMenu, style: TextStyle(color: Colors.red.shade300)),
      ),
    ],
  ).then((v) async {
    if (v == 'dl') await onDownload();
    if (v == 'del') await onDelete();
  });
}

class SftpSidePanel extends StatefulWidget {
  const SftpSidePanel({super.key, required this.controller});

  final SshWorkspaceController controller;

  @override
  State<SftpSidePanel> createState() => _SftpSidePanelState();
}

class _SftpSidePanelState extends State<SftpSidePanel> {
  bool _dropHighlight = false;

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
        await _c.uploadLocalFsPath(path);
        messenger?.showSnackBar(SnackBar(content: Text(l.sftpUploaded(p.basename(path)))));
      } catch (e) {
        messenger?.showSnackBar(SnackBar(content: Text(l.sftpUploadFailed('$e'))));
      }
    }
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
                                              onTap: isDir
                                                  ? () => _c.navigateInto(e.filename)
                                                  : () => _openOrEdit(context, e.filename, e.attr),
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

                                      return rowCore;
                                    },
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
        );
      },
    );
  }
}
