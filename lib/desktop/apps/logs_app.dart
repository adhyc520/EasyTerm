import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote_logs.dart';
import '../../services/remote_process_list.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';

/// 远端日志查看器：journal / 事件日志 / 文件 tail。
class LogsApp extends StatefulWidget {
  const LogsApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<LogsApp> createState() => _LogsAppState();
}

class _LogsAppState extends State<LogsApp> {
  Timer? _timer;
  RemoteOsKind? _os;
  RemoteLogSource _source = RemoteLogSource.journal;
  RemoteLogSnapshot? _snap;
  bool _loading = false;
  bool _autoRefresh = true;
  String? _error;
  String _filter = '';
  final _filterCtrl = TextEditingController();
  final _unitCtrl = TextEditingController();
  final _pathCtrl = TextEditingController(text: '/var/log/syslog');
  final _scroll = ScrollController();
  bool _stickBottom = true;

  @override
  void initState() {
    super.initState();
    final args = widget.window.args;
    final src = args['source']?.toString();
    if (src == 'file') {
      _source = RemoteLogSource.file;
    } else if (src == 'docker') {
      _source = RemoteLogSource.docker;
    }
    final unit = args['unit']?.toString();
    if (unit != null && unit.isNotEmpty) _unitCtrl.text = unit;
    final path = args['path']?.toString();
    if (path != null && path.isNotEmpty) _pathCtrl.text = path;
    widget.wm.addListener(_onWm);
    widget.controller.addListener(_onController);
    _scroll.addListener(_onScroll);
    unawaited(_tick());
    _armTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _filterCtrl.dispose();
    _unitCtrl.dispose();
    _pathCtrl.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    widget.wm.removeListener(_onWm);
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _onWm() {
    _armTimer();
    if (mounted) setState(() {});
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 48;
    if (atBottom != _stickBottom) _stickBottom = atBottom;
  }

  bool get _paused =>
      widget.window.state == WindowState.minimized || !_autoRefresh;

  bool get _connected =>
      widget.controller.connected && !widget.controller.dropped;

  void _armTimer() {
    _timer?.cancel();
    if (_paused) {
      _timer = null;
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_tick());
    });
  }

  Future<void> _tick() async {
    if (!mounted || widget.window.state == WindowState.minimized) return;
    if (!_connected) {
      setState(() {
        _error = '连接已断开，重连后刷新';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = _snap == null;
      _error = null;
    });
    try {
      final snap = await fetchRemoteLogs(
        widget.controller,
        osHint: _os,
        source: _source,
        unit: _unitCtrl.text.trim().isEmpty ? null : _unitCtrl.text.trim(),
        path: _pathCtrl.text.trim(),
        lines: 300,
      );
      if (!mounted) return;
      if (snap == null) {
        setState(() {
          _error = '无法获取日志';
          _loading = false;
        });
        return;
      }
      if (snap.os != RemoteOsKind.unknown) _os = snap.os;
      setState(() {
        _snap = snap;
        _loading = false;
        _error = snap.error;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_stickBottom || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<RemoteLogLine> get _filtered {
    final all = _snap?.lines ?? const [];
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return all;
    return [for (final l in all) if (l.text.toLowerCase().contains(q)) l];
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final lines = _filtered;
    final isWin = _os == RemoteOsKind.windows;

    return ColoredBox(
      color: wb.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
            child: Row(
              children: [
                Icon(Icons.article_rounded, size: 18, color: wb.accentBlue),
                const SizedBox(width: 8),
                Text(
                  '日志',
                  style: TextStyle(
                    color: wb.primaryText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 12),
                SegmentedButton<RemoteLogSource>(
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: [
                    ButtonSegment(
                      value: RemoteLogSource.journal,
                      label: Text(isWin ? '事件' : 'Journal'),
                      icon: const Icon(Icons.receipt_long_rounded, size: 16),
                    ),
                    const ButtonSegment(
                      value: RemoteLogSource.file,
                      label: Text('文件'),
                      icon: Icon(Icons.description_outlined, size: 16),
                    ),
                    const ButtonSegment(
                      value: RemoteLogSource.docker,
                      label: Text('Docker'),
                      icon: Icon(Icons.view_in_ar_rounded, size: 16),
                    ),
                  ],
                  selected: {_source},
                  onSelectionChanged: (s) {
                    setState(() => _source = s.first);
                    unawaited(_tick());
                  },
                ),
                const Spacer(),
                Tooltip(
                  message: _autoRefresh ? '暂停自动刷新' : '开启自动刷新',
                  child: IconButton(
                    iconSize: 18,
                    onPressed: () {
                      setState(() => _autoRefresh = !_autoRefresh);
                      _armTimer();
                    },
                    icon: Icon(
                      _autoRefresh
                          ? Icons.pause_circle_outline_rounded
                          : Icons.play_circle_outline_rounded,
                      color: wb.textMuted,
                    ),
                  ),
                ),
                if (_loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: '刷新',
                    iconSize: 18,
                    onPressed: _connected ? () => unawaited(_tick()) : null,
                    icon: Icon(Icons.refresh_rounded, color: wb.textMuted),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Row(
              children: [
                if (_source == RemoteLogSource.journal ||
                    _source == RemoteLogSource.docker) ...[
                  SizedBox(
                    width: 180,
                    child: TextField(
                      controller: _unitCtrl,
                      style: TextStyle(
                        fontSize: 12,
                        color: wb.primaryText,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: _source == RemoteLogSource.docker
                            ? '容器名 / ID'
                            : (isWin ? 'System / Application' : 'unit（可空）'),
                        hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      onSubmitted: (_) => unawaited(_tick()),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: TextField(
                      controller: _pathCtrl,
                      style: TextStyle(
                        fontSize: 12,
                        color: wb.primaryText,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: isWin ? r'C:\path\to\log' : '/var/log/...',
                        hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      onSubmitted: (_) => unawaited(_tick()),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                SizedBox(
                  width: _source == RemoteLogSource.journal ? 160 : 140,
                  child: TextField(
                    controller: _filterCtrl,
                    style: TextStyle(fontSize: 12, color: wb.primaryText),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '筛选',
                      hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 16,
                        color: wb.textMuted,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 0,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onChanged: (v) => setState(() => _filter = v),
                  ),
                ),
                if (_source == RemoteLogSource.journal) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _connected ? () => unawaited(_tick()) : null,
                    child: const Text('应用'),
                  ),
                ],
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text(
                _error!,
                style: TextStyle(color: wb.offline, fontSize: 12),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text(
              '${_snap?.label ?? '—'} · ${lines.length} 行'
              '${_filter.trim().isEmpty ? '' : '（已筛选）'}',
              style: TextStyle(fontSize: 11, color: wb.textMuted),
            ),
          ),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: wb.terminalBg,
                border: Border(top: BorderSide(color: wb.border)),
              ),
              child: lines.isEmpty
                  ? Center(
                      child: Text(
                        _loading ? '加载中…' : '无日志行',
                        style: TextStyle(color: wb.textMuted),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                      itemCount: lines.length,
                      itemBuilder: (context, i) {
                        final line = lines[i];
                        final color = line.isError
                            ? const Color(0xFFF87171)
                            : line.isWarn
                                ? const Color(0xFFFBBF24)
                                : wb.secondaryText;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: SelectableText(
                            line.text,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.35,
                              color: color,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: lines.isEmpty
                      ? null
                      : () async {
                          final text = lines.map((e) => e.text).join('\n');
                          await Clipboard.setData(ClipboardData(text: text));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已复制可见日志'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('复制'),
                ),
                const Spacer(),
                Text(
                  _autoRefresh ? '自动刷新 4s' : '已暂停',
                  style: TextStyle(fontSize: 11, color: wb.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
