import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'assistant_chat_text.dart';

/// 气泡内 Markdown 正文（样式全部显式指定，不依赖主题 merge）。
class AssistantChatMarkdownBody extends StatelessWidget {
  const AssistantChatMarkdownBody({
    super.key,
    required this.data,
    required this.textColor,
    required this.linkColor,
    required this.codeBackground,
    required this.codeTextColor,
    required this.borderColor,
    this.fontSize = 13,
  });

  final String data;
  final Color textColor;
  final Color linkColor;
  final Color codeBackground;
  final Color codeTextColor;
  final Color borderColor;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final plain = normalizeChatText(data);
    if (plain.isEmpty) return const SizedBox.shrink();

    final base = TextStyle(
      color: textColor,
      fontSize: fontSize,
      height: 1.45,
      fontWeight: FontWeight.w400,
      decoration: TextDecoration.none,
    );

    if (!looksLikeMarkdown(data)) {
      return Text(plain, style: base);
    }

    return MarkdownBody(
      data: data,
      selectable: true,
      shrinkWrap: true,
      fitContent: true,
      styleSheet: MarkdownStyleSheet(
        p: base,
        pPadding: EdgeInsets.zero,
        h1: base.copyWith(fontSize: fontSize + 5, fontWeight: FontWeight.w700),
        h2: base.copyWith(fontSize: fontSize + 3, fontWeight: FontWeight.w700),
        h3: base.copyWith(fontSize: fontSize + 1, fontWeight: FontWeight.w600),
        h4: base,
        h5: base,
        h6: base,
        h1Padding: const EdgeInsets.only(top: 4, bottom: 6),
        h2Padding: const EdgeInsets.only(top: 4, bottom: 6),
        h3Padding: const EdgeInsets.only(top: 2, bottom: 4),
        strong: base.copyWith(fontWeight: FontWeight.w700),
        em: base.copyWith(fontStyle: FontStyle.italic),
        del: base.copyWith(decoration: TextDecoration.lineThrough),
        blockquote: base.copyWith(color: textColor.withValues(alpha: 0.88)),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: linkColor, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: fontSize - 1,
          color: codeTextColor,
          backgroundColor: codeBackground.withValues(alpha: 0.65),
          decoration: TextDecoration.none,
        ),
        codeblockDecoration: BoxDecoration(
          color: codeBackground,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        codeblockPadding: const EdgeInsets.all(10),
        listBullet: base,
        listIndent: 20,
        a: base.copyWith(
          color: linkColor,
          decoration: TextDecoration.underline,
          decorationColor: linkColor,
        ),
        tableHead: base.copyWith(fontWeight: FontWeight.w700),
        tableBody: base,
        tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        tableBorder: TableBorder.all(color: borderColor),
        tableColumnWidth: const IntrinsicColumnWidth(),
        tablePadding: EdgeInsets.zero,
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: borderColor)),
        ),
      ),
    );
  }
}
