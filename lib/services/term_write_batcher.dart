import 'dart:async';

import 'package:xterm/xterm.dart';

/// 大批量终端输出分片写入，避免单帧写入过多行导致卡顿。
class TermWriteBatcher {
  TermWriteBatcher({this.maxLinesPerFrame = 200});

  final int maxLinesPerFrame;
  bool _writing = false;

  /// 小输出（行数 ≤ [maxLinesPerFrame]）直接写入；大输出按帧分片。
  Future<void> writeBatched(Terminal terminal, String data) async {
    if (data.isEmpty) return;
    final lineBreaks = '\n'.allMatches(data).length;
    if (lineBreaks <= maxLinesPerFrame) {
      terminal.write(data);
      return;
    }
    // 串行化：避免并发分片交错
    while (_writing) {
      await Future<void>.delayed(const Duration(milliseconds: 4));
    }
    _writing = true;
    try {
      final lines = data.split('\n');
      for (var i = 0; i < lines.length; i += maxLinesPerFrame) {
        final end = (i + maxLinesPerFrame).clamp(0, lines.length);
        final chunk = lines.sublist(i, end).join('\n');
        final isLast = end >= lines.length;
        terminal.write(isLast ? chunk : '$chunk\n');
        if (!isLast) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      }
    } finally {
      _writing = false;
    }
  }
}
