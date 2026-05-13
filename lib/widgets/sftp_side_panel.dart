import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

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

String _formatUnixMtime(int? sec) {
  if (sec == null) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true).toLocal();
  return '${d.year}-${_z2(d.month)}-${_z2(d.day)} ${_z2(d.hour)}:${_z2(d.minute)}';
}

/// (显示名, 绝对路径)
List<({String label, String path})> _breadcrumbSegments(String cwd) {
  final normalized = cwd.replaceAll('\\', '/');
  if (normalized.isEmpty || normalized == '/') {
    return [(label: '根', path: '/')];
  }
  final parts = normalized.split('/').where((e) => e.isNotEmpty).toList();
  final out = <({String label, String path})>[];
  out.add((label: '根', path: '/'));
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
      const PopupMenuItem(value: 'dl', child: Text('下载到本地…')),
      PopupMenuItem(
        value: 'del',
        child: Text('删除', style: TextStyle(color: Colors.red.shade300)),
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
    try {
      if (isDirectory) {
        final parent = await FilePicker.getDirectoryPath(dialogTitle: '选择保存位置（将创建同名子文件夹）');
        if (parent == null || !context.mounted) return;
        await _c.downloadRemoteDirectoryToLocal(name, parent);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已下载目录 $name')));
        }
      } else {
        final out = await FilePicker.saveFile(
          dialogTitle: '保存远程文件',
          fileName: remoteBasename(name),
        );
        if (out == null || !context.mounted) return;
        await _c.downloadRemoteFileToLocalPath(name, out);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已下载 $name')));
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
    for (final path in paths) {
      if (path.isEmpty) continue;
      try {
        await _c.uploadLocalFsPath(path);
        messenger?.showSnackBar(SnackBar(content: Text('已上传 ${p.basename(path)}')));
      } catch (e) {
        messenger?.showSnackBar(SnackBar(content: Text('上传失败: $e')));
      }
    }
  }

  Future<void> _openOrEdit(BuildContext context, String name, SftpFileAttrs attr) async {
    if (!attr.isFile) return;
    try {
      final bytes = await _c.readRemoteFile(name);
      if (bytes == null || !context.mounted) return;
      if (!looksLikeTextBytes(bytes)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该文件为二进制，已取消在编辑器中打开')),
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除确认'),
        content: Text('确定删除「$name」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
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
        final segs = _breadcrumbSegments(_c.remoteCwd);
        return SizedBox.expand(
          child: Material(
            color: WorkbenchPalette.panel,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: WorkbenchPalette.border)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.folder_open_outlined, size: 18, color: WorkbenchPalette.textMuted),
                      const SizedBox(width: 8),
                      Text(
                        '文件浏览器',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
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
                                  const Text(
                                    ' / ',
                                    style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: WorkbenchPalette.textMuted),
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
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                        color: WorkbenchPalette.accentBlue,
                                        decoration: TextDecoration.underline,
                                        decorationColor: WorkbenchPalette.accentBlue,
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
                        tooltip: '刷新',
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                        padding: EdgeInsets.zero,
                        onPressed: _c.loadingDir ? null : () => _c.refreshDirectory(),
                        icon: const Icon(Icons.refresh_rounded, size: 18, color: WorkbenchPalette.textMuted),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: WorkbenchPalette.border),
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
                            ? WorkbenchPalette.accentBlue.withValues(alpha: 0.08)
                            : Colors.transparent,
                      ),
                      child: _c.loadingDir
                          ? const Center(child: CircularProgressIndicator(color: WorkbenchPalette.accentBlue))
                          : Column(
                              children: [
                                const Padding(
                                  padding: EdgeInsets.fromLTRB(10, 4, 10, 2),
                                  child: Row(
                                    children: [
                                      SizedBox(width: 22),
                                      SizedBox(width: 4),
                                      Expanded(
                                        flex: 5,
                                        child: Text(
                                          '名称',
                                          style: TextStyle(fontSize: 10, color: WorkbenchPalette.textMuted, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 64,
                                        child: Text(
                                          '大小',
                                          textAlign: TextAlign.end,
                                          style: TextStyle(fontSize: 10, color: WorkbenchPalette.textMuted, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                      SizedBox(width: 6),
                                      SizedBox(
                                        width: 108,
                                        child: Text(
                                          '修改时间',
                                          style: TextStyle(fontSize: 10, color: WorkbenchPalette.textMuted, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1, color: WorkbenchPalette.border),
                                Expanded(
                                  child: ListView.separated(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    itemCount: _c.entries.length,
                                    separatorBuilder: (context, _) => const Divider(height: 1, color: WorkbenchPalette.border),
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
                                                      color: isDir ? WorkbenchPalette.folder : WorkbenchPalette.textMuted,
                                                      size: 16,
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Expanded(
                                                      flex: 5,
                                                      child: Text(
                                                        e.filename,
                                                        style: const TextStyle(
                                                          fontFamily: 'monospace',
                                                          fontSize: 11,
                                                          color: Colors.white70,
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
                                                        style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: WorkbenchPalette.textMuted),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    SizedBox(
                                                      width: 108,
                                                      child: Text(
                                                        _formatUnixMtime(e.attr.modifyTime),
                                                        style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: WorkbenchPalette.textMuted),
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
