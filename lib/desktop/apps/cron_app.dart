import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/remote_cron.dart';
import '../../services/terminal_session_controller.dart';
import '../../services/remote_exec_capable.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../widgets/destructive_action_dialog.dart';
import '../../widgets/remote_state_view.dart';
import '../desktop_window_manager.dart';
import '../widgets/desktop_scrollable_actions.dart';

/// 当前用户 crontab：列表预览 + 全文编辑安装。
class CronApp extends StatefulWidget {
  const CronApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final TerminalSessionController controller;

  @override
  State<CronApp> createState() => _CronAppState();
}

class _CronAppState extends State<CronApp> {
  RemoteExecCapable get _exec => widget.controller as RemoteExecCapable;
final _editCtrl = TextEditingController();
  List<CronLine> _lines = const [];
  bool _loading = false;
  bool _saving = false;
  bool _editing = false;
  String? _error;
  String? _hint;
  String _installedText = '';
  String? _lastCrontab;
  String _serviceStatus = 'unknown';

  bool get _connected =>
      widget.controller.connected && !widget.controller.dropped;

  bool get _serviceActive => _serviceStatus == 'active';

  /// 非注释/空行/特殊/@ENV 且字段不足 6 的疑似任务行（1-based 行号）。
  List<int> _malformedJobLineNumbers(String text) {
    final bad = <int>[];
    final lines = text.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      if (t.startsWith('@')) continue;
      if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(t)) continue;
      final parts = t.split(RegExp(r'\s+'));
      if (parts.length < 6) bad.add(i + 1);
    }
    return bad;
  }

  /// 畸形行原文（保存确认对话框用）。
  List<String> _malformedJobLines(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    return [
      for (final n in _malformedJobLineNumbers(text)) lines[n - 1].trim(),
    ];
  }

  bool _isDisabledJob(CronLine l) {
    if (!l.isComment) return false;
    final t = l.raw.trimLeft();
    if (!t.startsWith('#')) return false;
    var body = t.substring(1).trimLeft();
    if (body.startsWith('#')) return false;
    if (body.startsWith('@')) return true;
    return body.split(RegExp(r'\s+')).length >= 6;
  }

  List<CronLine> get _displayJobs => [
        for (final l in _lines)
          if (l.isJob || _isDisabledJob(l)) l,
      ];

  String _jobCommand(CronLine j) {
    if (j.command != null && j.command!.isNotEmpty) return j.command!;
    var body = j.raw.trimLeft();
    if (body.startsWith('#')) body = body.substring(1).trimLeft();
    if (body.startsWith('@')) {
      final sp = body.indexOf(RegExp(r'\s'));
      return sp < 0 ? body : body.substring(sp + 1).trimLeft();
    }
    final parts = body.split(RegExp(r'\s+'));
    return parts.length >= 6 ? parts.sublist(5).join(' ') : body;
  }

  String _jobSchedule(CronLine j) {
    if (j.isJob) return j.scheduleLabel;
    var body = j.raw.trimLeft();
    if (body.startsWith('#')) body = body.substring(1).trimLeft();
    if (body.startsWith('@')) {
      return body.split(RegExp(r'\s+')).first;
    }
    final parts = body.split(RegExp(r'\s+'));
    if (parts.length >= 5) {
      return parts.sublist(0, 5).join(' ');
    }
    return '—';
  }

  /// 从任务行取出 5 个 cron 字段；@special / 无法解析时返回 null。
  List<String>? _jobCronFields(CronLine j) {
    if (j.isJob &&
        j.minute != null &&
        j.hour != null &&
        j.dom != null &&
        j.month != null &&
        j.dow != null) {
      return [j.minute!, j.hour!, j.dom!, j.month!, j.dow!];
    }
    var body = j.raw.trimLeft();
    if (body.startsWith('#')) body = body.substring(1).trimLeft();
    if (body.startsWith('@')) return null;
    final parts = body.split(RegExp(r'\s+'));
    if (parts.length < 5) return null;
    return parts.sublist(0, 5);
  }

  String _nextRunLabel(CronLine j) {
    final fields = _jobCronFields(j);
    if (fields == null) return '—';
    final next = cronNextRunApprox(
      fields[0],
      fields[1],
      fields[2],
      fields[3],
      fields[4],
    );
    if (next == null) return '—';
    final now = DateTime.now();
    final tod =
        '${next.hour.toString().padLeft(2, '0')}:${next.minute.toString().padLeft(2, '0')}';
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(next.year, next.month, next.day);
    final diffDays = that.difference(today).inDays;
    if (diffDays == 0) return '下次 $tod';
    if (diffDays == 1) return '明天 $tod';
    if (diffDays < 7) {
      const names = ['一', '二', '三', '四', '五', '六', '日'];
      return '周${names[next.weekday - 1]} $tod';
    }
    return '${next.month}/${next.day} $tod';
  }

  void _openCronLogs() {
    widget.wm.open(
      DesktopAppType.logs,
      args: {'source': 'journal'},
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已打开日志（journal）')),
    );
  }

  @override
  void initState() {
    super.initState();
    widget.window.onConnectionRestored = _onRestored;
    unawaited(_reload());
  }

  @override
  void dispose() {
    widget.window.onConnectionRestored = null;
    _editCtrl.dispose();
    super.dispose();
  }

  void _onRestored() {
    if (!mounted) return;
    setState(() => _error = null);
    unawaited(_reload());
  }

  Future<void> _reload() async {
    if (!_connected) {
      setState(() {
        _error = '连接已断开';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _hint = null;
    });
    final results = await Future.wait([
      fetchCrontabText(_exec),
      _exec.runQueued(
        'systemctl is-active cron 2>/dev/null || '
        'systemctl is-active crond 2>/dev/null || echo unknown',
      ),
    ]);
    if (!mounted) return;
    final text = results[0];
    final statusRaw = results[1];
    final statusLine =
        (statusRaw ?? 'unknown').trim().split(RegExp(r'\r?\n')).last.trim();
    final status = statusLine.isEmpty ? 'unknown' : statusLine;
    if (text == null) {
      setState(() {
        _loading = false;
        _serviceStatus = status;
        _error = _exec.lastRemoteCommandError == null
            ? '无法读取 crontab'
            : '刷新失败：${_exec.lastRemoteCommandError}';
      });
      return;
    }
    setState(() {
      _lines = parseCrontab(text);
      _installedText = text;
      _editCtrl.text = text;
      _loading = false;
      _serviceStatus = status;
      _hint = text.trim().isEmpty ? '当前用户无 crontab' : null;
    });
  }

  Future<void> _save() async {
    if (_saving || !_connected) return;
    final text = _editCtrl.text;
    final bad = _malformedJobLines(text);
    if (bad.isNotEmpty) {
      final preview = bad.take(3).join('\n');
      final ok = await confirmDestructiveAction(
        context,
        title: 'crontab 可能有误',
        body: '以下行字段不足 6（分 时 日 月 周 命令），仍要强制安装吗？\n\n$preview'
            '${bad.length > 3 ? '\n…共 ${bad.length} 行' : ''}',
        confirmLabel: '强制安装',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final backup = _installedText;
    final err = await installCrontab(_exec, text);
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _editing = false;
      _lastCrontab = backup;
    });
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('crontab 已安装')),
      );
    }
  }

  Future<void> _undoLast() async {
    final prev = _lastCrontab;
    if (prev == null || _saving || !_connected) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await installCrontab(_exec, prev);
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _lastCrontab = null;
      _editing = false;
    });
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已恢复上一份 crontab')),
      );
    }
  }

  Future<void> _toggleJobComment(CronLine job) async {
    if (_saving || !_connected) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final text = await fetchCrontabText(_exec);
    if (!mounted) return;
    if (text == null) {
      setState(() {
        _saving = false;
        _error = '无法读取 crontab';
      });
      return;
    }
    final lines = text.split(RegExp(r'\r?\n'));
    final target = job.raw.trimRight();
    final idx = lines.indexWhere((l) => l.trimRight() == target);
    if (idx < 0) {
      setState(() {
        _saving = false;
        _error = '找不到对应任务行';
      });
      return;
    }
    final line = lines[idx];
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('#')) {
      var body = trimmed.substring(1);
      if (body.startsWith(' ')) body = body.substring(1);
      lines[idx] = body;
    } else {
      lines[idx] = '# $trimmed';
    }
    final next = lines.join('\n');
    final backup = _installedText;
    final err = await installCrontab(_exec, next);
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() => _lastCrontab = backup);
    await _reload();
    if (mounted) {
      final enabled = !trimmed.startsWith('#');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(enabled ? '已禁用任务' : '已启用任务')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final jobs = _displayJobs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: DesktopHScrollRow(
            children: [
              Text(
                '计划任务',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: wb.primaryText,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '当前用户 crontab',
                style: TextStyle(fontSize: 11, color: wb.textMuted),
              ),
              const SizedBox(width: 8),
              Chip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: EdgeInsets.zero,
                label: Text(
                  _serviceActive ? '运行中' : '已停止',
                  style: TextStyle(
                    fontSize: 11,
                    color: _serviceActive
                        ? const Color(0xFF22C55E)
                        : wb.textMuted,
                  ),
                ),
                backgroundColor: wb.panelElevated,
                side: BorderSide(color: wb.border),
              ),
              const SizedBox(width: 12),
              if (_lastCrontab != null)
                TextButton(
                  onPressed: _connected && !_saving
                      ? () => unawaited(_undoLast())
                      : null,
                  child: Text(
                    AppLocalizations.of(context)?.desktopUndoLast ?? '撤销上一次',
                  ),
                ),
              if (!_editing)
                TextButton.icon(
                  onPressed: _connected && !_loading
                      ? () => setState(() => _editing = true)
                      : null,
                  icon: const Icon(Icons.edit_rounded, size: 16),
                  label: const Text('编辑'),
                ),
              if (_editing) ...[
                TextButton(
                  onPressed: _saving
                      ? null
                      : () {
                          setState(() {
                            _editing = false;
                            _editCtrl.text = _installedText;
                          });
                        },
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: _saving ? null : () => unawaited(_save()),
                  child: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('安装'),
                ),
              ],
              IconButton(
                tooltip: 'crontab 语法说明',
                onPressed: () {
                  final wb = context.wb;
                  showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: wb.panelElevated,
                      title: Text(
                        'crontab 语法',
                        style: TextStyle(color: wb.primaryText),
                      ),
                      content: SelectableText(
                        '分 时 日 月 周  命令\n'
                        '*  *  *  *  *  /path/cmd\n'
                        '0  *  *  *  *  每小时\n'
                        '0  2  *  *  *  每天 02:00\n'
                        '@reboot /path/cmd',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.45,
                          color: wb.secondaryText,
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.help_outline_rounded, size: 18),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _connected && !_loading
                    ? () => unawaited(_reload())
                    : null,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_error!, style: TextStyle(color: Colors.red.shade300, fontSize: 12)),
          ),
        if (_hint != null && !_editing)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_hint!, style: TextStyle(color: wb.textMuted, fontSize: 12)),
          ),
        if (_editing) ...[
          Builder(
            builder: (context) {
              final badNums = _malformedJobLineNumbers(_editCtrl.text);
              if (badNums.isEmpty) return const SizedBox.shrink();
              final preview = badNums.take(8).join(', ');
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text(
                  '语法可疑：第 $preview'
                  '${badNums.length > 8 ? '…（共 ${badNums.length} 行）' : ' 行'}'
                  '字段不足 6（分 时 日 月 周 命令）',
                  style: TextStyle(color: Colors.red.shade300, fontSize: 12),
                ),
              );
            },
          ),
        ],
        Expanded(
          child: _editing
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: wb.panelElevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: wb.border),
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final text = _editCtrl.text;
                        final lineCount =
                            '\n'.allMatches(text).length + 1;
                        final badSet =
                            _malformedJobLineNumbers(text).toSet();
                        final gutterWidth =
                            (28.0 + (lineCount.toString().length * 7))
                                .clamp(36.0, 64.0);
                        const style = TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.45,
                        );
                        return SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(8, 10, 10, 10),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: (constraints.maxHeight - 20)
                                  .clamp(80.0, double.infinity),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: gutterWidth,
                                  child: Text.rich(
                                    TextSpan(
                                      children: [
                                        for (var i = 1; i <= lineCount; i++)
                                          TextSpan(
                                            text: i == lineCount
                                                ? '$i'
                                                : '$i\n',
                                            style: style.copyWith(
                                              color: badSet.contains(i)
                                                  ? Colors.red.shade300
                                                  : wb.textMuted,
                                            ),
                                          ),
                                      ],
                                    ),
                                    textAlign: TextAlign.right,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: _editCtrl,
                                    autofocus: true,
                                    maxLines: null,
                                    textAlignVertical: TextAlignVertical.top,
                                    onChanged: (_) => setState(() {}),
                                    style: style.copyWith(
                                      color: wb.primaryText,
                                    ),
                                    decoration: const InputDecoration(
                                      isCollapsed: true,
                                      border: InputBorder.none,
                                      contentPadding: EdgeInsets.zero,
                                      hintText:
                                          '# m h dom mon dow command\n',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                )
              : RemoteStateView(
                  state: !_connected
                      ? RemoteState.disconnected
                      : _loading
                          ? RemoteState.loading
                          : (_error != null && _lines.isEmpty)
                              ? RemoteState.error
                              : jobs.isEmpty
                                  ? RemoteState.empty
                                  : RemoteState.data,
                  message: !_connected
                      ? '未连接'
                      : (_error != null && _lines.isEmpty)
                          ? _error
                          : '暂无任务',
                  detail: jobs.isEmpty && _error == null && _connected
                      ? '点「编辑」添加，例如：\n0 * * * * /usr/bin/date'
                      : null,
                  onRetry: () => unawaited(_reload()),
                  data: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                      itemCount: jobs.length,
                      itemBuilder: (context, i) {
                        final j = jobs[i];
                        final disabled = _isDisabledJob(j);
                        final cmd = _jobCommand(j);
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.schedule_rounded,
                            size: 18,
                            color: disabled ? wb.textMuted : wb.accentBlue,
                          ),
                          title: Text(
                            cmd,
                            style: TextStyle(
                              fontSize: 12,
                              color: disabled ? wb.textMuted : wb.primaryText,
                              fontFamily: 'monospace',
                              decoration: disabled
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${_jobSchedule(j)} · ${_nextRunLabel(j)}',
                            style: TextStyle(fontSize: 11, color: wb.textMuted),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: disabled ? '启用' : '禁用',
                                iconSize: 18,
                                onPressed: _connected && !_saving
                                    ? () => unawaited(_toggleJobComment(j))
                                    : null,
                                icon: Icon(
                                  disabled
                                      ? Icons.play_circle_outline_rounded
                                      : Icons.pause_circle_outline_rounded,
                                  color: wb.textMuted,
                                ),
                              ),
                              if (cmd.isNotEmpty && !disabled) ...[
                                TextButton(
                                  onPressed: () {
                                    widget.wm.open(
                                      DesktopAppType.terminal,
                                      args: {'inject': cmd},
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          '已打开终端并填入命令（未自动执行）',
                                        ),
                                      ),
                                    );
                                  },
                                  child: const Text('立即运行'),
                                ),
                                TextButton(
                                  onPressed: _openCronLogs,
                                  child: const Text('日志'),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                ),
        ),
      ],
    );
  }
}

/// 轻量 5 字段 cron 下次运行近似（支持 `*`、数字、`*/n`；忽略列表/范围/名称）。
/// 在 [from] 起 7 天内搜索；无法解析或超出窗口返回 null。
DateTime? cronNextRunApprox(
  String minute,
  String hour,
  String dom,
  String month,
  String dow, {
  DateTime? from,
}) {
  bool matches(String field, int value, int min, int max) {
    final f = field.trim();
    if (f == '*') return true;
    final every = RegExp(r'^\*/(\d+)$').firstMatch(f);
    if (every != null) {
      final n = int.tryParse(every.group(1)!);
      if (n == null || n <= 0) return false;
      return (value - min) % n == 0;
    }
    final v = int.tryParse(f);
    if (v == null) return false;
    if (v < min || v > max) return false;
    return v == value;
  }

  // Reject unsupported tokens early (lists, ranges, names).
  bool simple(String f) {
    final t = f.trim();
    if (t == '*') return true;
    if (RegExp(r'^\*/\d+$').hasMatch(t)) return true;
    if (RegExp(r'^\d+$').hasMatch(t)) return true;
    return false;
  }

  if (![minute, hour, dom, month, dow].every(simple)) return null;

  final start = (from ?? DateTime.now()).toLocal();
  // Align to next whole minute.
  var cursor = DateTime(
    start.year,
    start.month,
    start.day,
    start.hour,
    start.minute,
  ).add(const Duration(minutes: 1));
  final deadline = start.add(const Duration(days: 7));

  while (cursor.isBefore(deadline) || cursor.isAtSameMomentAs(deadline)) {
    final dowCron = cursor.weekday % 7; // 0=Sun .. 6=Sat
    final domOk = matches(dom, cursor.day, 1, 31);
    final dowOk = matches(dow, dowCron, 0, 6);
    final bool dayPass;
    if (dom == '*' && dow == '*') {
      dayPass = true;
    } else if (dom != '*' && dow != '*') {
      // Both restricted: either field may match (classic cron OR).
      dayPass = domOk || dowOk;
    } else {
      dayPass = domOk && dowOk;
    }

    if (matches(month, cursor.month, 1, 12) &&
        dayPass &&
        matches(hour, cursor.hour, 0, 23) &&
        matches(minute, cursor.minute, 0, 59)) {
      return cursor;
    }
    cursor = cursor.add(const Duration(minutes: 1));
  }
  return null;
}
