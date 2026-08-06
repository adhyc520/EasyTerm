import 'package:flutter/material.dart';

import '../../services/sftp_upload_task_list.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';

/// 桌面级传输面板：展示会话统一上传/下载队列。
class TransfersApp extends StatefulWidget {
  const TransfersApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<TransfersApp> createState() => _TransfersAppState();
}

class _TransfersAppState extends State<TransfersApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.uploadTasks.addListener(_onTasks);
  }

  @override
  void dispose() {
    widget.controller.uploadTasks.removeListener(_onTasks);
    super.dispose();
  }

  void _onTasks() {
    if (mounted) setState(() {});
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final list = widget.controller.uploadTasks;
    final tasks = list.items;
    final active = tasks
        .where(
          (t) =>
              t.state == SftpUploadRowState.pending ||
              t.state == SftpUploadRowState.uploading,
        )
        .length;

    return ColoredBox(
      color: wb.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
            child: Row(
              children: [
                Icon(Icons.swap_vert_rounded, size: 18, color: wb.accentBlue),
                const SizedBox(width: 8),
                Text(
                  '传输',
                  style: TextStyle(
                    color: wb.primaryText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  active > 0
                      ? '进行中 $active · 本批 ${list.batchSucceeded}/${list.batchTotal}'
                      : tasks.isEmpty
                          ? '空闲'
                          : '本批 ${list.batchSucceeded}/${list.batchTotal}',
                  style: TextStyle(fontSize: 12, color: wb.textMuted),
                ),
                const Spacer(),
                TextButton(
                  onPressed: tasks.isEmpty
                      ? null
                      : () => list.userCancelAll(),
                  child: const Text('全部取消'),
                ),
                TextButton(
                  onPressed: tasks.isEmpty ? null : () => list.clear(),
                  child: const Text('清空'),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: wb.border),
          Expanded(
            child: tasks.isEmpty
                ? Center(
                    child: Text(
                      '暂无传输任务\n从文件管理器拖入上传或下载即可在此查看',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: wb.textMuted, fontSize: 13),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: tasks.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: wb.border.withValues(alpha: 0.5)),
                    itemBuilder: (context, i) {
                      final t = tasks[i];
                      final pct = t.totalBytes > 0
                          ? (t.uploadedBytes / t.totalBytes).clamp(0.0, 1.0)
                          : null;
                      final isUp = t.direction == SftpTransferDirection.upload;
                      final failed = t.state == SftpUploadRowState.failed;
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                        child: Row(
                          children: [
                            Icon(
                              isUp
                                  ? Icons.upload_rounded
                                  : Icons.download_rounded,
                              size: 18,
                              color: failed
                                  ? const Color(0xFFEF4444)
                                  : wb.accentBlue,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    t.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: wb.primaryText,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  if (failed)
                                    Text(
                                      '${t.error ?? '失败'}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFFEF4444),
                                        fontSize: 11,
                                      ),
                                    )
                                  else ...[
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(3),
                                      child: LinearProgressIndicator(
                                        value: t.state ==
                                                SftpUploadRowState.pending
                                            ? 0
                                            : pct,
                                        minHeight: 4,
                                        backgroundColor: wb.border,
                                        color: wb.accentBlue,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      t.state == SftpUploadRowState.pending
                                          ? '排队中 · ${_fmt(t.totalBytes)}'
                                          : '${_fmt(t.uploadedBytes)} / ${_fmt(t.totalBytes)}'
                                              '${pct == null ? '' : ' · ${(pct * 100).toStringAsFixed(0)}%'}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: wb.textMuted,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '取消',
                              iconSize: 18,
                              onPressed: () => list.userCancelFile(t.id),
                              icon: Icon(
                                Icons.close_rounded,
                                color: wb.textMuted,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
