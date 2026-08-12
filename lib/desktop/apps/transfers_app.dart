import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/sftp_upload_task_list.dart';
import '../../services/terminal_session_controller.dart';
import '../../services/remote_exec_capable.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';
import '../widgets/desktop_scrollable_actions.dart';
import '../widgets/desktop_ui.dart';

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
  final TerminalSessionController controller;

  @override
  State<TransfersApp> createState() => _TransfersAppState();
}

class _TransfersAppState extends State<TransfersApp> {
  SshWorkspaceController get _ssh => widget.controller as SshWorkspaceController;

  /// id → (lastBytes, lastAtMs, bytesPerSec)
  final Map<String, (int, int, double)> _speedSamples = {};

  @override
  void initState() {
    super.initState();
    _ssh.uploadTasks.addListener(_onTasks);
  }

  @override
  void dispose() {
    _ssh.uploadTasks.removeListener(_onTasks);
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

  String _fmtRate(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    final kb = bytesPerSec / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB/s';
    return '${(kb / 1024).toStringAsFixed(1)} MB/s';
  }

  String? _speedEtaLine(SftpUploadTaskView t) {
    if (t.state != SftpUploadRowState.uploading) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final prev = _speedSamples[t.id];
    var rate = prev?.$3 ?? 0;
    if (prev != null) {
      final dt = (now - prev.$2) / 1000.0;
      if (dt >= 0.4) {
        final delta = t.uploadedBytes - prev.$1;
        if (delta >= 0) {
          final instant = delta / dt;
          rate = rate <= 0 ? instant : (rate * 0.65 + instant * 0.35);
        }
        _speedSamples[t.id] = (t.uploadedBytes, now, rate);
      }
    } else {
      _speedSamples[t.id] = (t.uploadedBytes, now, 0);
    }
    if (rate < 1) return null;
    final remain = t.totalBytes - t.uploadedBytes;
    String? eta;
    if (remain > 0 && rate > 0) {
      final secs = (remain / rate).ceil();
      if (secs < 60) {
        eta = '~${secs}s';
      } else if (secs < 3600) {
        eta = '~${secs ~/ 60}m${secs % 60}s';
      } else {
        eta = '~${secs ~/ 3600}h${(secs % 3600) ~/ 60}m';
      }
    }
    return eta == null ? _fmtRate(rate) : '${_fmtRate(rate)} · $eta';
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final list = _ssh.uploadTasks;
    final tasks = list.items;
    final active = list.activeCount;
    final failed = list.failedCount;
    final succeeded = list.batchSucceeded;
    final activeIds = {
      for (final t in tasks)
        if (t.state == SftpUploadRowState.uploading ||
            t.state == SftpUploadRowState.pending)
          t.id,
    };
    _speedSamples.removeWhere((id, _) => !activeIds.contains(id));

    return ColoredBox(
      color: wb.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DesktopAppToolbar(
            child: Row(
              children: [
                Icon(Icons.swap_vert_rounded, size: 18, color: wb.accentBlue),
                const SizedBox(width: 8),
                const DesktopAppTitle('传输'),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    tasks.isEmpty && succeeded == 0
                        ? '空闲'
                        : '成功 $succeeded · 失败 $failed · 进行中 $active',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: wb.textMuted),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: DesktopScrollableActions(
                    children: [
                      TextButton(
                        onPressed: failed > 0
                            ? () => unawaited(
                                  _ssh.retryAllFailedTransfers(),
                                )
                            : null,
                        child: const Text('全部重试'),
                      ),
                      TextButton(
                        onPressed: list.hasActive && !list.allActivePaused
                            ? () => list.userPauseAll()
                            : null,
                        child: const Text('全部暂停'),
                      ),
                      TextButton(
                        onPressed:
                            list.hasPaused ? () => list.userResumeAll() : null,
                        child: const Text('全部恢复'),
                      ),
                      TextButton(
                        onPressed:
                            list.hasActive ? () => list.userCancelAll() : null,
                        child: const Text('全部取消'),
                      ),
                      TextButton(
                        onPressed: failed > 0 && !list.hasActive
                            ? () => list.clearFinished()
                            : null,
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: tasks.isEmpty
                ? Center(
                    child: Text(
                      '暂无传输任务\n从文件管理器拖入上传或下载即可在此查看',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: wb.textMuted, fontSize: 13),
                    ),
                  )
                : tasks.length == 1
                    ? ListView(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        children: [
                          _taskRow(wb, list, tasks[0], index: 0, reorderable: false),
                        ],
                      )
                    : ReorderableListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        buildDefaultDragHandles: false,
                        itemCount: tasks.length,
                        onReorder: list.reorder,
                        itemBuilder: (context, i) {
                          final t = tasks[i];
                          return _taskRow(
                            wb,
                            list,
                            t,
                            key: ValueKey(t.id),
                            index: i,
                            reorderable: true,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _taskRow(
    WorkbenchColors wb,
    SftpUploadTaskList list,
    SftpUploadTaskView t, {
    Key? key,
    required int index,
    required bool reorderable,
  }) {
    final pct = t.totalBytes > 0
        ? (t.uploadedBytes / t.totalBytes).clamp(0.0, 1.0)
        : null;
    final isUp = t.direction == SftpTransferDirection.upload;
    final failed = t.state == SftpUploadRowState.failed;
    final pending = t.state == SftpUploadRowState.pending;
    final active = pending || t.state == SftpUploadRowState.uploading;
    final paused = active && list.isPauseRequested(t.id);
    final speedEta = paused ? null : _speedEtaLine(t);
    final String statusLine;
    if (pending) {
      statusLine = paused
          ? '已暂停 · 排队中 · ${_fmt(t.totalBytes)}'
          : '排队中 · ${_fmt(t.totalBytes)}';
    } else {
      final prog =
          '${_fmt(t.uploadedBytes)} / ${_fmt(t.totalBytes)}'
          '${pct == null ? '' : ' · ${(pct * 100).toStringAsFixed(0)}%'}'
          '${speedEta == null ? '' : ' · $speedEta'}';
      statusLine = paused ? '已暂停 · $prog' : prog;
    }

    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(4, 10, 8, 10),
      child: Row(
        children: [
          if (reorderable)
            ReorderableDragStartListener(
              index: index,
              enabled: pending,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  Icons.drag_handle_rounded,
                  size: 18,
                  color: pending ? wb.textMuted : wb.border,
                ),
              ),
            )
          else
            const SizedBox(width: 8),
          Icon(
            isUp ? Icons.upload_rounded : Icons.download_rounded,
            size: 18,
            color: failed
                ? const Color(0xFFEF4444)
                : paused
                    ? wb.textMuted
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
                      value: pending ? 0 : pct,
                      minHeight: 4,
                      backgroundColor: wb.border,
                      color: paused ? wb.textMuted : wb.accentBlue,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    statusLine,
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
          if (pending || failed)
            TextButton(
              onPressed: () => list.prioritize(t.id),
              child: const Text('优先'),
            ),
          if (active)
            IconButton(
              tooltip: paused ? '恢复' : '暂停',
              iconSize: 18,
              onPressed: () {
                if (paused) {
                  list.userResumeFile(t.id);
                } else {
                  list.userPauseFile(t.id);
                }
              },
              icon: Icon(
                paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                color: wb.accentBlue,
              ),
            ),
          if (failed)
            IconButton(
              tooltip: t.canRetry ? '重试' : '无法重试（缺少路径）',
              iconSize: 18,
              onPressed: t.canRetry
                  ? () => unawaited(
                        _ssh.retryTransferTask(t),
                      )
                  : null,
              icon: Icon(
                Icons.refresh_rounded,
                color: t.canRetry ? wb.accentBlue : wb.textMuted,
              ),
            ),
          IconButton(
            tooltip: failed ? '已失败，无法取消' : '取消',
            iconSize: 18,
            onPressed: failed ? null : () => list.userCancelFile(t.id),
            icon: Icon(
              Icons.close_rounded,
              color: wb.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
