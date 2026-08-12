import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'assistant_chat_bubble.dart';
import 'assistant_chat_text.dart';
import 'assistant_tool_call_card.dart';

/// 将 API 消息列表转为可滚动气泡组件。
List<Widget> buildAssistantChatMessageTiles({
  required BuildContext context,
  required AppLocalizations l,
  required List<Map<String, Object?>> messages,
  required bool busy,
  required String streamReasoning,
  required String streamContent,
  bool zh = true,
}) {
  final palette = AssistantChatPalette.of(context);
  final tiles = <Widget>[];

  for (final m in messages) {
    final role = m['role'] as String?;
    if (role == null || role == 'system') continue;

    if (role == 'user') {
      final text = normalizeChatText(messageContentString(m['content']) ?? '');
      if (text.isEmpty) continue;
      tiles.add(
        AssistantChatBubble(
          label: l.assistantUserHeader,
          body: text,
          icon: Icons.person_outline_rounded,
          background: palette.userBg,
          textColor: palette.userText,
          labelColor: palette.userLabel,
          linkColor: palette.userLabel,
          codeBackground: palette.codeBg,
          codeTextColor: palette.codeText,
          borderColor: palette.toolBorder,
          alignEnd: true,
          markdown: looksLikeMarkdown(text),
        ),
      );
      continue;
    }

    if (role == 'assistant') {
      final reasoning = normalizeChatText(
        m['reasoning_content'] as String? ?? '',
      );
      if (reasoning.isNotEmpty) {
        tiles.add(
          AssistantChatBubble(
            label: l.assistantReasoningHeader,
            body: reasoning,
            icon: Icons.psychology_outlined,
            background: palette.reasoningBg,
            textColor: palette.reasoningText,
            labelColor: palette.reasoningLabel,
            bodyFontSize: 12,
          ),
        );
      }

      final toolCalls = m['tool_calls'];
      if (toolCalls is List && toolCalls.isNotEmpty) {
        for (final t in toolCalls) {
          if (t is! Map) continue;
          final fn = t['function'];
          final name = fn is Map && fn['name'] is String
              ? fn['name'] as String
              : 'tool';
          final tid = t['id'] as String?;
          final matched = tid == null
              ? null
              : _findToolResult(messages, tid);
          if (matched != null) {
            // 结果卡片在 tool role 处渲染，此处跳过避免重复。
            continue;
          }
          tiles.add(
            AssistantToolCallCard(
              toolName: name,
              status: busy
                  ? AssistantToolCallStatus.running
                  : AssistantToolCallStatus.failure,
              detail: busy ? null : (zh ? '无结果' : 'no result'),
              zh: zh,
            ),
          );
        }
      }

      final answer = normalizeChatText(
        messageContentString(m['content']) ?? '',
      );
      if (answer.isNotEmpty) {
        tiles.add(
          AssistantChatBubble(
            label: l.assistantAnswerHeader,
            body: answer,
            icon: Icons.smart_toy_outlined,
            background: palette.assistantBg,
            textColor: palette.assistantText,
            labelColor: palette.assistantLabel,
            linkColor: palette.assistantLabel,
            codeBackground: palette.codeBg,
            codeTextColor: palette.codeText,
            borderColor: palette.toolBorder,
            markdown: true,
          ),
        );
      }
      continue;
    }

    if (role == 'tool') {
      final ui = m['_ui_tool'];
      final toolName = ui is Map && ui['name'] is String
          ? ui['name'] as String
          : 'tool';
      final statusRaw = ui is Map ? ui['status'] as String? : null;
      final detail = ui is Map ? ui['detail'] as String? : null;
      final status = switch (statusRaw) {
        'success' => AssistantToolCallStatus.success,
        'failure' => AssistantToolCallStatus.failure,
        'running' => AssistantToolCallStatus.running,
        _ => _inferStatusFromContent((m['content'] as String?) ?? ''),
      };
      tiles.add(
        AssistantToolCallCard(
          toolName: toolName,
          status: status,
          detail: detail,
          zh: zh,
        ),
      );

      final tile = _toolResultTile(
        context: context,
        l: l,
        raw: (m['content'] as String?) ?? '',
        palette: palette,
        toolName: toolName,
      );
      if (tile != null) tiles.add(tile);
    }
  }

  if (busy) {
    final liveReasoning = normalizeChatText(streamReasoning);
    final liveAnswer = normalizeChatText(streamContent);
    if (liveReasoning.isNotEmpty) {
      tiles.add(
        AssistantChatBubble(
          label: l.assistantReasoningHeader,
          body: liveReasoning,
          icon: Icons.psychology_outlined,
          background: palette.reasoningBg,
          textColor: palette.reasoningText,
          labelColor: palette.reasoningLabel,
          bodyFontSize: 12,
          streaming: true,
        ),
      );
    }
    if (liveAnswer.isNotEmpty) {
      tiles.add(
        AssistantChatBubble(
          label: l.assistantAnswerHeader,
          body: liveAnswer,
          icon: Icons.smart_toy_outlined,
          background: palette.assistantBg,
          textColor: palette.assistantText,
          labelColor: palette.assistantLabel,
          linkColor: palette.assistantLabel,
          codeBackground: palette.codeBg,
          codeTextColor: palette.codeText,
          borderColor: palette.toolBorder,
          markdown: true,
          streaming: true,
        ),
      );
    }
  }

  return tiles;
}

Map<String, Object?>? _findToolResult(
  List<Map<String, Object?>> messages,
  String toolCallId,
) {
  for (final m in messages) {
    if (m['role'] == 'tool' && m['tool_call_id'] == toolCallId) return m;
  }
  return null;
}

AssistantToolCallStatus _inferStatusFromContent(String raw) {
  final parsed = tryParseToolJson(raw);
  if (parsed == null) return AssistantToolCallStatus.success;
  return parsed['ok'] == true
      ? AssistantToolCallStatus.success
      : AssistantToolCallStatus.failure;
}

Widget? _toolResultTile({
  required BuildContext context,
  required AppLocalizations l,
  required String raw,
  required AssistantChatPalette palette,
  required String toolName,
}) {
  final parsed = tryParseToolJson(raw);
  if (parsed != null) {
    final ok = parsed['ok'] == true;
    final tail = parsed['terminal_tail'];
    final content = parsed['content'];
    final listing = parsed['listing'];
    final matches = parsed['matches'];
    final info = parsed['info'];
    final processes = parsed['processes'];
    final usage = parsed['usage'];
    final network = parsed['network'];
    final packages = parsed['packages'];
    final error = parsed['error'];
    final detail = parsed['detail'];

    if (!ok) {
      final err = normalizeChatText(
        [error, detail].whereType<String>().join(': '),
      );
      if (err.isEmpty) return null;
      return _ToolResultCard(
        palette: palette,
        header: l.assistantToolResultHeader,
        ok: false,
        body: err,
        bodyColor: palette.errorText,
      );
    }

    String output = '';
    if (tail is String && tail.isNotEmpty) {
      output = normalizeChatText(tail);
    } else if (content is String && content.isNotEmpty) {
      output = normalizeChatText(content);
    } else if (listing is String) {
      output = normalizeChatText(listing);
    } else if (matches is String) {
      output = normalizeChatText(matches);
    } else if (info is String) {
      output = normalizeChatText(info);
    } else if (processes is String) {
      output = normalizeChatText(processes);
    } else if (usage is String) {
      output = normalizeChatText(usage);
    } else if (network is String) {
      output = normalizeChatText(network);
    } else if (packages is String) {
      output = normalizeChatText(packages);
    } else if (toolName == 'file_list' && parsed['entries'] is List) {
      final entries = parsed['entries'] as List;
      output = entries
          .take(80)
          .map((e) {
            if (e is! Map) return '$e';
            final name = e['name'];
            final isDir = e['is_dir'] == true;
            return '${isDir ? 'd' : '-'} $name';
          })
          .join('\n');
    } else if (parsed['paths'] is List) {
      output = (parsed['paths'] as List).map((e) => '$e').join('\n');
    }

    if (output.isEmpty) {
      // 成功但无可展示正文时，卡片标题已足够。
      return null;
    }

    return _ToolResultCard(
      palette: palette,
      header: l.assistantToolResultHeader,
      ok: true,
      body: output.length > 4000
          ? '…${output.substring(output.length - 4000)}'
          : output,
      bodyColor: palette.codeText,
      monospace: true,
    );
  }

  final preview = normalizeChatText(raw);
  if (preview.isEmpty) return null;
  return _ToolResultCard(
    palette: palette,
    header: l.assistantToolResultHeader,
    ok: true,
    body: preview.length > 400 ? '${preview.substring(0, 400)}…' : preview,
    bodyColor: palette.metaText,
    monospace: true,
  );
}

class _ToolResultCard extends StatelessWidget {
  const _ToolResultCard({
    required this.palette,
    required this.header,
    required this.ok,
    required this.body,
    required this.bodyColor,
    this.monospace = false,
  });

  final AssistantChatPalette palette;
  final String header;
  final bool ok;
  final String body;
  final Color bodyColor;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10, left: 4),
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        decoration: BoxDecoration(
          color: palette.toolBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: palette.toolBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ok ? Icons.check_circle_outline : Icons.error_outline,
                  size: 14,
                  color: ok ? palette.assistantLabel : palette.errorText,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    header,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.metaText,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: monospace ? palette.codeBg : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: monospace
                    ? Border.all(color: palette.toolBorder)
                    : null,
              ),
              child: Text(
                body,
                style: TextStyle(
                  color: bodyColor,
                  fontSize: monospace ? 11 : 12,
                  height: 1.35,
                  fontFamily: monospace ? 'monospace' : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
