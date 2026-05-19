import 'package:flutter/material.dart';

import 'assistant_chat_markdown.dart';

/// 助手对话气泡配色（不透明背景 + 固定前景色，避免文字与背景融在一起）。
@immutable
final class AssistantChatPalette {
  const AssistantChatPalette({
    required this.userBg,
    required this.userText,
    required this.userLabel,
    required this.assistantBg,
    required this.assistantText,
    required this.assistantLabel,
    required this.reasoningBg,
    required this.reasoningText,
    required this.reasoningLabel,
    required this.metaText,
    required this.toolBg,
    required this.toolBorder,
    required this.errorText,
    required this.codeBg,
    required this.codeText,
  });

  final Color userBg;
  final Color userText;
  final Color userLabel;
  final Color assistantBg;
  final Color assistantText;
  final Color assistantLabel;
  final Color reasoningBg;
  final Color reasoningText;
  final Color reasoningLabel;
  final Color metaText;
  final Color toolBg;
  final Color toolBorder;
  final Color errorText;
  final Color codeBg;
  final Color codeText;

  factory AssistantChatPalette.of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark) {
      return const AssistantChatPalette(
        userBg: Color(0xFF1E40AF),
        userText: Color(0xFFFFFFFF),
        userLabel: Color(0xFF93C5FD),
        assistantBg: Color(0xFF232327),
        assistantText: Color(0xFFF9FAFB),
        assistantLabel: Color(0xFF86EFAC),
        reasoningBg: Color(0xFF352E1F),
        reasoningText: Color(0xFFE8D7BC),
        reasoningLabel: Color(0xFFFBBF24),
        metaText: Color(0xFF9CA3AF),
        toolBg: Color(0xFF18181B),
        toolBorder: Color(0xFF3F3F46),
        errorText: Color(0xFFFCA5A5),
        codeBg: Color(0xFF0D0D0F),
        codeText: Color(0xFFE5E7EB),
      );
    }
    return const AssistantChatPalette(
      userBg: Color(0xFFDBEAFE),
      userText: Color(0xFF111827),
      userLabel: Color(0xFF1D4ED8),
      assistantBg: Color(0xFFFFFFFF),
      assistantText: Color(0xFF111827),
      assistantLabel: Color(0xFF15803D),
      reasoningBg: Color(0xFFFFF7ED),
      reasoningText: Color(0xFF78350F),
      reasoningLabel: Color(0xFFD97706),
      metaText: Color(0xFF6B7280),
      toolBg: Color(0xFFF3F4F6),
      toolBorder: Color(0xFFD1D5DB),
      errorText: Color(0xFFB91C1C),
      codeBg: Color(0xFF111827),
      codeText: Color(0xFFE5E7EB),
    );
  }
}

/// 单条助手对话气泡（纯 [Text]，由外层 [SelectionArea] 负责选中复制）。
class AssistantChatBubble extends StatelessWidget {
  const AssistantChatBubble({
    super.key,
    required this.label,
    required this.body,
    required this.icon,
    required this.background,
    required this.textColor,
    required this.labelColor,
    this.linkColor,
    this.codeBackground,
    this.codeTextColor,
    this.borderColor,
    this.alignEnd = false,
    this.bodyFontSize = 13,
    this.markdown = false,
    this.streaming = false,
  });

  final String label;
  final String body;
  final IconData icon;
  final Color background;
  final Color textColor;
  final Color labelColor;
  final Color? linkColor;
  final Color? codeBackground;
  final Color? codeTextColor;
  final Color? borderColor;
  final bool alignEnd;
  final double bodyFontSize;
  final bool markdown;
  final bool streaming;

  Widget _buildBody() {
    final style = TextStyle(
      color: textColor,
      fontSize: bodyFontSize,
      height: 1.45,
      fontWeight: FontWeight.w400,
    );
    if (markdown) {
      return AssistantChatMarkdownBody(
        data: body,
        textColor: textColor,
        linkColor: linkColor ?? textColor,
        codeBackground: codeBackground ?? const Color(0xFF0D0D0F),
        codeTextColor: codeTextColor ?? textColor,
        borderColor: borderColor ?? labelColor.withValues(alpha: 0.45),
        fontSize: bodyFontSize,
      );
    }
    return Text(body, style: style);
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(alignEnd ? 12 : 4),
            bottomRight: Radius.circular(alignEnd ? 4 : 12),
          ),
          border: Border.all(
            color: streaming ? labelColor : labelColor.withValues(alpha: 0.45),
            width: streaming ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: labelColor),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: labelColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _buildBody(),
          ],
        ),
      ),
    );
  }
}
