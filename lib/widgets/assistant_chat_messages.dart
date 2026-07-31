import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'assistant_chat_bubble.dart';
import 'assistant_chat_text.dart';

/// 将 API 消息列表转为可滚动气泡组件。
List<Widget> buildAssistantChatMessageTiles({
  required BuildContext context,
  required AppLocalizations l,
  required List<Map<String, Object?>> messages,
  required bool busy,
  required String streamReasoning,
  required String streamContent,
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
        tiles.add(
          _ToolStatusRow(
            text: l.assistantToolRunning(_toolNames(toolCalls)),
            color: palette.metaText,
          ),
        );
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
      final tile = _toolResultTile(
        context: context,
        l: l,
        raw: (m['content'] as String?) ?? '',
        palette: palette,
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

String _toolNames(List<dynamic> toolCalls) {
  final names = <String>[];
  for (final t in toolCalls) {
    if (t is! Map) continue;
    final fn = t['function'];
    if (fn is Map) {
      final name = fn['name'];
      if (name is String && name.isNotEmpty) names.add(name);
    }
  }
  return names.isEmpty ? 'terminal_run' : names.join(', ');
}

class _ToolStatusRow extends StatelessWidget {
  const _ToolStatusRow({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 4),
      child: Row(
        children: [
          Icon(Icons.bolt_rounded, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 11.5, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

Widget? _toolResultTile({
  required BuildContext context,
  required AppLocalizations l,
  required String raw,
  required AssistantChatPalette palette,
}) {
  final parsed = tryParseToolJson(raw);
  if (parsed != null) {
    final ok = parsed['ok'] == true;
    final tail = parsed['terminal_tail'];
    final error = parsed['error'];
    final detail = parsed['detail'];
    final output = tail is String ? normalizeChatText(tail) : '';

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

    if (output.isEmpty) {
      return _ToolResultCard(
        palette: palette,
        header: l.assistantToolResultHeader,
        ok: true,
        body: l.assistantToolResultEmpty,
        bodyColor: palette.metaText,
      );
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
                Text(
                  header,
                  style: TextStyle(
                    color: palette.metaText,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
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
