import 'dart:convert';

import 'ssh_workspace_controller.dart';

/// 一条 crontab 行（含注释与空行，便于原样回写）。
class CronLine {
  const CronLine({
    required this.raw,
    this.minute,
    this.hour,
    this.dom,
    this.month,
    this.dow,
    this.command,
    this.isComment = false,
    this.isEmpty = false,
    this.isSpecial = false,
  });

  final String raw;
  final String? minute;
  final String? hour;
  final String? dom;
  final String? month;
  final String? dow;
  final String? command;
  final bool isComment;
  final bool isEmpty;
  final bool isSpecial;

  bool get isJob => !isComment && !isEmpty && command != null;

  String get scheduleLabel {
    if (isSpecial && command != null) {
      final parts = raw.trim().split(RegExp(r'\s+'));
      return parts.isEmpty ? '@' : parts.first;
    }
    if (minute == null) return '—';
    return '$minute $hour $dom $month $dow';
  }
}

List<CronLine> parseCrontab(String raw) {
  final out = <CronLine>[];
  for (final line in raw.split(RegExp(r'\r?\n'))) {
    final t = line.trimRight();
    if (t.trim().isEmpty) {
      out.add(CronLine(raw: line, isEmpty: true));
      continue;
    }
    if (t.trimLeft().startsWith('#')) {
      out.add(CronLine(raw: line, isComment: true));
      continue;
    }
    final trimmed = t.trimLeft();
    if (trimmed.startsWith('@')) {
      final sp = trimmed.indexOf(RegExp(r'\s'));
      if (sp < 0) {
        out.add(CronLine(raw: line, isSpecial: true, command: trimmed));
      } else {
        out.add(
          CronLine(
            raw: line,
            isSpecial: true,
            command: trimmed.substring(sp + 1).trimLeft(),
          ),
        );
      }
      continue;
    }
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 6) {
      out.add(CronLine(raw: line, isComment: true));
      continue;
    }
    out.add(
      CronLine(
        raw: line,
        minute: parts[0],
        hour: parts[1],
        dom: parts[2],
        month: parts[3],
        dow: parts[4],
        command: parts.sublist(5).join(' '),
      ),
    );
  }
  return out;
}

Future<String?> fetchCrontabText(SshWorkspaceController c) async {
  final out = await c.runQueued('crontab -l 2>/dev/null');
  if (out == null) return null;
  // 空 crontab 时部分系统把错误打到 stdout；规范化。
  final t = out.trim();
  if (t.toLowerCase().contains('no crontab')) return '';
  return out;
}

Future<String?> installCrontab(SshWorkspaceController c, String text) async {
  final normalized = text.replaceAll('\r\n', '\n');
  final b64 = base64Encode(utf8.encode(normalized.endsWith('\n') || normalized.isEmpty
      ? normalized
      : '$normalized\n'));
  // base64 字母表对单引号安全。
  final code = await c.runQueued(
    "echo '$b64' | base64 -d | crontab - 2>&1; echo __EC:\$?",
  );
  if (code == null) return '安装失败（连接或命令错误）';
  final m = RegExp(r'__EC:(\d+)').firstMatch(code);
  final ec = int.tryParse(m?.group(1) ?? '') ?? 1;
  if (ec != 0) {
    final msg = code.replaceAll(RegExp(r'__EC:\d+\s*$'), '').trim();
    return msg.isEmpty ? 'crontab 安装失败 (exit $ec)' : msg;
  }
  return null;
}
