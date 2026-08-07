import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/remote_cron.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';

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
  final SshWorkspaceController controller;

  @override
  State<CronApp> createState() => _CronAppState();
}

class _CronAppState extends State<CronApp> {
  final _editCtrl = TextEditingController();
  List<CronLine> _lines = const [];
  bool _loading = false;
  bool _saving = false;
  bool _editing = false;
  String? _error;
  String? _hint;

  bool get _connected =>
      widget.controller.connected && !widget.controller.dropped;

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
    final text = await fetchCrontabText(widget.controller);
    if (!mounted) return;
    if (text == null) {
      setState(() {
        _loading = false;
        _error = widget.controller.lastRemoteCommandError == null
            ? '无法读取 crontab'
            : '刷新失败：${widget.controller.lastRemoteCommandError}';
      });
      return;
    }
    setState(() {
      _lines = parseCrontab(text);
      _editCtrl.text = text;
      _loading = false;
      _hint = text.trim().isEmpty ? '当前用户无 crontab' : null;
    });
  }

  Future<void> _save() async {
    if (_saving || !_connected) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await installCrontab(widget.controller, _editCtrl.text);
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() => _editing = false);
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('crontab 已安装')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final jobs = _lines.where((l) => l.isJob).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(
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
              const Spacer(),
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
                            _editCtrl.text =
                                _lines.map((l) => l.raw).join('\n');
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
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _editing
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      child: TextField(
                        controller: _editCtrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: wb.primaryText,
                        ),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: wb.panelElevated,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: wb.border),
                          ),
                          hintText: '# m h dom mon dow command\n',
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                      itemCount: jobs.isEmpty ? 1 : jobs.length,
                      itemBuilder: (context, i) {
                        if (jobs.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              '暂无任务。点「编辑」添加，例如：\n0 * * * * /usr/bin/date',
                              style: TextStyle(color: wb.textMuted, fontSize: 12),
                            ),
                          );
                        }
                        final j = jobs[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.schedule_rounded,
                            size: 18,
                            color: wb.accentBlue,
                          ),
                          title: Text(
                            j.command ?? '',
                            style: TextStyle(
                              fontSize: 12,
                              color: wb.primaryText,
                              fontFamily: 'monospace',
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            j.scheduleLabel,
                            style: TextStyle(fontSize: 11, color: wb.textMuted),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
