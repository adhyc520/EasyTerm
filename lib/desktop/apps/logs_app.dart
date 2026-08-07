import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote_logs.dart';
import '../../services/remote_process_list.dart';
import '../../services/remote_stream.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';

/// 远端日志查看器：journal / 事件日志 / 文件 tail；支持实时跟随。
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
  bool _liveFollow = true;
  String? _error;
  String _filter = '';
  final _filterCtrl = TextEditingController();
  final _unitCtrl = TextEditingController();
  final _pathCtrl = TextEditingController(text: '/var/log/syslog');
  final _scroll = ScrollController();
  bool _stickBottom = true;

  RemoteStream? _stream;
  List<RemoteLogLine> _liveLines = const [];
  bool _wantLive = true;

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
    _liveFollow = widget.wm.desktopSettings.liveLogsDefault;
    _wantLive = _liveFollow;
    widget.wm.addListener(_onWm);
    widget.controller.addListener(_onController);
    widget.window.onConnectionRestored = _onConnectionRestored;
    _scroll.addListener(_onScroll);
    unawaited(_bootstrap());
  }

  void _onConnectionRestored() {
    if (!mounted) return;
    setState(() => _error = null);
    unawaited(_restartMode());
  }

  Future<void> _bootstrap() async {
    await _detectOs();
    if (!mounted) return;
    await _restartMode();
  }

  Future<void> _detectOs() async {
    if (!_connected) return;
    try {
      _os = await detectRemoteOs(widget.controller);
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_stopStream());
    _filterCtrl.dispose();
    _unitCtrl.dispose();
    _pathCtrl.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    widget.window.onConnectionRestored = null;
    widget.wm.removeListener(_onWm);
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _onWm() {
    if (widget.window.state == WindowState.minimized) {
      unawaited(_stopStream());
      _timer?.cancel();
      _timer = null;
    } else {
      unawaited(_restartMode());
    }
    if (mounted) setState(() {});
  }

  void _onController() {
    if (!mounted) return;
    if (!_connected) {
      unawaited(_stopStream());
      setState(() => _error = '连接已断开，重连后刷新');
      return;
    }
    // 重连后若仍想跟随，自动重开。
    if (_wantLive && _liveFollow && _stream == null) {
      unawaited(_restartMode());
    }
    setState(() {});
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

  bool get _canLive {
    if (_os == RemoteOsKind.windows) return false;
    return buildLinuxLogFollowCommand(
          source: _source,
          unit: _unitCtrl.text.trim().isEmpty ? null : _unitCtrl.text.trim(),
          path: _pathCtrl.text.trim(),
          lines: 300,
        ) !=
        null;
  }

  Future<void> _restartMode() async {
    if (!mounted || widget.window.state == WindowState.minimized) return;
    await _stopStream();
    _timer?.cancel();
    _timer = null;
    if (!_connected || !_autoRefresh) return;
    if (_liveFollow && _canLive) {
      await _startLive();
    } else {
      await _tick();
      _armSnapshotTimer();
    }
  }

  void _armSnapshotTimer() {
    _timer?.cancel();
    if (_paused || (_liveFollow && _canLive)) {
      _timer = null;
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_tick());
    });
  }

  Future<void> _stopStream() async {
    final s = _stream;
    _stream = null;
    if (s == null) return;
    s.removeListener(_onStream);
    widget.controller.unregisterRemoteStream(s);
    await s.stop();
  }

  Future<void> _startLive() async {
    if (!_connected) return;
    final cmd = buildLinuxLogFollowCommand(
      source: _source,
      unit: _unitCtrl.text.trim().isEmpty ? null : _unitCtrl.text.trim(),
      path: _pathCtrl.text.trim(),
      lines: 300,
    );
    if (cmd == null) {
      setState(() {
        _liveFollow = false;
        _error = '当前来源不支持实时跟随，已切回快照';
      });
      await _tick();
      _armSnapshotTimer();
      return;
    }
    setState(() {
      _loading = _liveLines.isEmpty;
      _error = null;
    });
    try {
      final stream = await widget.controller.startRemoteStream(cmd);
      if (!mounted) {
        await stream.stop();
        return;
      }
      _stream = stream;
      stream.addListener(_onStream);
      _onStream();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '实时跟随启动失败：$e';
        _loading = false;
        _liveFollow = false;
      });
      await _tick();
      _armSnapshotTimer();
    }
  }

  void _onStream() {
    final s = _stream;
    if (s == null || !mounted) return;
    setState(() {
      _liveLines = remoteLogLinesFromRaw(s.lines);
      _loading = false;
      if (s.error != null) _error = s.error;
      if (s.closed && s.error == null && _wantLive) {
        _error = '日志流已结束';
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_stickBottom || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
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
      _loading = _snap == null && _liveLines.isEmpty;
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
    final all = (_liveFollow && _canLive && _stream != null)
        ? _liveLines
        : (_snap?.lines ?? const []);
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return all;
    return [for (final l in all) if (l.text.toLowerCase().contains(q)) l];
  }

  String get _modeLabel {
    if (_liveFollow && _canLive && _stream != null) return '实时跟随';
    if (_autoRefresh) return '快照 4s';
    return '已暂停';
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
                  style: const ButtonStyle(
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
                    unawaited(_restartMode());
                  },
                ),
                const Spacer(),
                if (!isWin)
                  Tooltip(
                    message: _liveFollow ? '切换为快照轮询' : '切换为实时跟随',
                    child: IconButton(
                      iconSize: 18,
                      onPressed: () {
                        setState(() {
                          _liveFollow = !_liveFollow;
                          _wantLive = _liveFollow;
                        });
                        unawaited(_restartMode());
                      },
                      icon: Icon(
                        _liveFollow
                            ? Icons.stream_rounded
                            : Icons.photo_camera_outlined,
                        color: _liveFollow ? wb.accentBlue : wb.textMuted,
                      ),
                    ),
                  ),
                Tooltip(
                  message: _autoRefresh ? '暂停' : '继续',
                  child: IconButton(
                    iconSize: 18,
                    onPressed: () {
                      setState(() => _autoRefresh = !_autoRefresh);
                      unawaited(_restartMode());
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
                    onPressed: !_connected
                        ? null
                        : () {
                            if (_liveFollow && _canLive) {
                              unawaited(_restartMode());
                            } else {
                              unawaited(_tick());
                            }
                          },
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
                      onSubmitted: (_) => unawaited(_restartMode()),
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
                      onSubmitted: (_) => unawaited(_restartMode()),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                SizedBox(
                  width: _source == RemoteLogSource.journal ? 160 : 140,
                  child: TextField(
                    controller: _filterCtrl,
                    autofocus: true,
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
                    onPressed:
                        _connected ? () => unawaited(_restartMode()) : null,
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
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_snap?.label ?? (_source == RemoteLogSource.file ? _pathCtrl.text : (_unitCtrl.text.isEmpty ? '—' : _unitCtrl.text))} · ${lines.length} 行'
                    '${_filter.trim().isEmpty ? '' : '（已筛选）'}',
                    style: TextStyle(fontSize: 11, color: wb.textMuted),
                  ),
                ),
                if (!_stickBottom)
                  TextButton(
                    onPressed: () {
                      _stickBottom = true;
                      if (_scroll.hasClients) {
                        _scroll.jumpTo(_scroll.position.maxScrollExtent);
                      }
                      setState(() {});
                    },
                    child: const Text('回到底部'),
                  ),
              ],
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
                  _modeLabel,
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
