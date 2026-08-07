import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/workbench_theme.dart';

/// 影响运行中服务 / 网络可达性 / 持久状态 / 数据的变更前确认。
///
/// 返回 `true` 表示用户确认继续。
Future<bool> confirmDestructiveAction(
  BuildContext context, {
  required String title,
  required String body,
  String confirmLabel = '确认',
  bool danger = true,
  bool sshPortWarning = false,
  String? terminalFallback,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final wb = ctx.wb;
      return AlertDialog(
        backgroundColor: wb.panelElevated,
        title: Text(title, style: TextStyle(color: wb.primaryText)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (sshPortWarning) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Color(0xFFEF4444),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '这可能断开你的 SSH 连接。确认后若连接中断，需从本机重新连接。',
                          style: TextStyle(
                            color: wb.primaryText,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                body,
                style: TextStyle(color: wb.secondaryText, height: 1.4),
              ),
              if (terminalFallback != null && terminalFallback.isNotEmpty) ...[
                const SizedBox(height: 12),
                SelectableText(
                  terminalFallback,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: wb.textMuted,
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: terminalFallback),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 14),
                    label: const Text('复制命令'),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                  )
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result == true;
}

/// 结束进程：优雅(SIGTERM) / 强制(SIGKILL)。取消返回 `null`。
Future<bool?> confirmKillProcess(
  BuildContext context, {
  required String name,
  required int pid,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) {
      final wb = ctx.wb;
      return AlertDialog(
        backgroundColor: wb.panelElevated,
        title: Text('结束进程', style: TextStyle(color: wb.primaryText)),
        content: Text(
          '确定结束「$name」(PID $pid)？\n未保存的数据可能丢失。',
          style: TextStyle(color: wb.secondaryText, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('结束 (SIGTERM)'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('强制结束'),
          ),
        ],
      );
    },
  );
}
