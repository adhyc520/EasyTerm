import 'package:flutter/material.dart';

import 'assistant_chat_bubble.dart';

/// 工具调用状态：执行中 / 成功 / 失败。
enum AssistantToolCallStatus { running, success, failure }

/// 紧凑工具调用卡片（匹配助手气泡主题）。
class AssistantToolCallCard extends StatelessWidget {
  const AssistantToolCallCard({
    super.key,
    required this.toolName,
    required this.status,
    this.detail,
    this.zh = true,
  });

  final String toolName;
  final AssistantToolCallStatus status;
  final String? detail;
  final bool zh;

  @override
  Widget build(BuildContext context) {
    final palette = AssistantChatPalette.of(context);
    final (IconData icon, Color color, String label) = switch (status) {
      AssistantToolCallStatus.running => (
        Icons.autorenew_rounded,
        palette.reasoningLabel,
        zh ? '正在执行' : 'Running',
      ),
      AssistantToolCallStatus.success => (
        Icons.check_circle_outline_rounded,
        palette.assistantLabel,
        zh ? '已完成' : 'Done',
      ),
      AssistantToolCallStatus.failure => (
        Icons.error_outline_rounded,
        palette.errorText,
        zh ? '失败' : 'Failed',
      ),
    };

    final detailText = (detail ?? '').trim();
    final title = detailText.isEmpty
        ? '$label · $toolName'
        : '$label · $toolName · $detailText';

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8, left: 4),
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: palette.toolBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.toolBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (status == AssistantToolCallStatus.running)
              SizedBox(
                width: 14,
                height: 14,
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                ),
              )
            else
              Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: palette.metaText,
                  fontSize: 11.5,
                  height: 1.35,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
