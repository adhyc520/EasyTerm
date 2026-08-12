import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/remote_stream.dart';
import '../../services/terminal_session_controller.dart';
import '../../services/remote_exec_capable.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';

/// 一次性远程命令窗口：用 [RemoteStream] 流式显示输出，不占交互终端。
class RunCommandApp extends StatefulWidget {
  const RunCommandApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final TerminalSessionController controller;

  @override
  State<RunCommandApp> createState() => _RunCommandAppState();
}

class _RunCommandAppState extends State<RunCommandApp> {
  RemoteExecCapable get _exec => widget.controller as RemoteExecCapable;
static const _presets = [
    'uptime',
    'df -h',
    'free -h',
    'uname -a',
    'whoami',
  ];

  final _cmdCtrl = TextEditingController();
  final _cmdFocus = FocusNode();
  final _scroll = ScrollController();
  final StringBuffer _archived = StringBuffer();
  RemoteStream? _stream;
  bool _running = false;
  String? _error;
  bool _stickBottom = true;
  List<String> _history = const [];
  List<String> _favorites = const [];
  int _historyIndex = -1;
  String _draft = '';

  String get _hostKey =>
      '${widget.controller.username}@${widget.controller.host}:${widget.controller.port}';

  String get _prefsKey => 'run_command_history_$_hostKey';

  String get _favKey => 'run_command_favorites_$_hostKey';

  @override
  void initState() {
    super.initState();
    final initial = widget.window.args['command']?.toString();
    if (initial != null && initial.isNotEmpty) {
      _cmdCtrl.text = initial;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_run());
      });
    }
    widget.window.onConnectionRestored = () {
      if (_running) unawaited(_run());
    };
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atBottom =
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 48;
      _stickBottom = atBottom;
    });
    _cmdFocus.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _recallHistory(1);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _recallHistory(-1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    unawaited(_loadHistory());
    unawaited(_loadFavorites());
  }

  @override
  void dispose() {
    widget.window.onConnectionRestored = null;
    unawaited(_stop());
    _cmdCtrl.dispose();
    _cmdFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      if (!mounted) return;
      setState(() {
        _history = [
          for (final e in decoded)
            if (e is String && e.trim().isNotEmpty) e.trim(),
        ];
      });
    } catch (_) {}
  }

  Future<void> _persistHistory() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefsKey, jsonEncode(_history));
    } catch (_) {}
  }

  Future<void> _loadFavorites() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_favKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      if (!mounted) return;
      setState(() {
        _favorites = [
          for (final e in decoded)
            if (e is String && e.trim().isNotEmpty) e.trim(),
        ];
      });
    } catch (_) {}
  }

  Future<void> _persistFavorites() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_favKey, jsonEncode(_favorites));
    } catch (_) {}
  }

  void _remember(String cmd) {
    final next = [cmd, for (final h in _history) if (h != cmd) h];
    if (next.length > 50) next.removeRange(50, next.length);
    _history = next;
    _historyIndex = -1;
    _draft = '';
    unawaited(_persistHistory());
  }

  void _applyPreset(String cmd, {bool run = true}) {
    _cmdCtrl
      ..text = cmd
      ..selection = TextSelection.collapsed(offset: cmd.length);
    setState(() {});
    if (run) unawaited(_run());
  }

  Future<void> _toggleFavoriteCurrent() async {
    final cmd = _cmdCtrl.text.trim();
    if (cmd.isEmpty) return;
    setState(() {
      if (_favorites.contains(cmd)) {
        _favorites = [for (final f in _favorites) if (f != cmd) f];
      } else {
        _favorites = [cmd, ..._favorites];
        if (_favorites.length > 30) {
          _favorites = _favorites.sublist(0, 30);
        }
      }
    });
    await _persistFavorites();
  }

  void _recallHistory(int delta) {
    if (_history.isEmpty) return;
    if (_historyIndex < 0) {
      if (delta < 0) return;
      _draft = _cmdCtrl.text;
      _historyIndex = 0;
    } else {
      final next = _historyIndex + delta;
      if (next < 0) {
        _historyIndex = -1;
        _cmdCtrl
          ..text = _draft
          ..selection = TextSelection.collapsed(offset: _draft.length);
        setState(() {});
        return;
      }
      if (next >= _history.length) return;
      _historyIndex = next;
    }
    final cmd = _history[_historyIndex];
    _cmdCtrl
      ..text = cmd
      ..selection = TextSelection.collapsed(offset: cmd.length);
    setState(() {});
  }

  Future<void> _stop() async {
    final s = _stream;
    _stream = null;
    if (s == null) return;
    s.removeListener(_onStream);
    _exec.unregisterRemoteStream(s);
    await s.stop();
  }

  String get _liveOutput => _stream?.lines.join('\n') ?? '';

  String get _fullOutput {
    final live = _liveOutput;
    if (_archived.isEmpty) return live;
    if (live.isEmpty) return _archived.toString();
    return '$_archived$live';
  }

  void _archiveBeforeNewRun(String cmd) {
    final live = _liveOutput;
    final hasPast = _archived.isNotEmpty || live.isNotEmpty;
    if (!hasPast) return;
    if (live.isNotEmpty) {
      if (_archived.isNotEmpty && !_archived.toString().endsWith('\n')) {
        _archived.write('\n');
      }
      _archived.write(live);
    }
    if (_archived.isNotEmpty && !_archived.toString().endsWith('\n')) {
      _archived.write('\n');
    }
    _archived.write('────────\n\$ $cmd\n');
  }

  void _clearOutput() {
    unawaited(_stop().then((_) {
      if (!mounted) return;
      setState(() {
        _archived.clear();
        _running = false;
        _error = null;
        _stream = null;
      });
    }));
  }

  Future<void> _run() async {
    final cmd = _cmdCtrl.text.trim();
    if (cmd.isEmpty) return;
    if (!widget.controller.connected || widget.controller.dropped) {
      setState(() => _error = '未连接');
      return;
    }
    _remember(cmd);
    _archiveBeforeNewRun(cmd);
    await _stop();
    setState(() {
      _running = true;
      _error = null;
    });
    widget.window.title =
        '运行 · ${cmd.length > 24 ? '${cmd.substring(0, 24)}…' : cmd}';
    widget.wm.requestRebuild();
    try {
      final stream =
          await _exec.startRemoteStream(cmd, maxLines: 4000);
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
        _running = false;
        _error = '$e';
      });
    }
  }

  void _onStream() {
    final s = _stream;
    if (s == null || !mounted) return;
    setState(() {
      if (s.error != null) _error = s.error;
      if (s.closed) _running = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_stickBottom || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final output = _fullOutput;
    final hasOutput = output.isNotEmpty;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () =>
            unawaited(_run()),
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            unawaited(_run()),
      },
      child: ColoredBox(
        color: wb.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
              child: Row(
                children: [
                  Icon(Icons.play_circle_outline_rounded,
                      size: 18, color: wb.accentBlue),
                  const SizedBox(width: 8),
                  Text(
                    '运行命令',
                    style: TextStyle(
                      color: wb.primaryText,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (_running)
                    TextButton(
                      onPressed: () => unawaited(_stop().then((_) {
                            if (mounted) setState(() => _running = false);
                          })),
                      child: const Text('停止'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _cmdCtrl,
                      focusNode: _cmdFocus,
                      autofocus: true,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: wb.primaryText,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '例如：df -h · who · du -sh /var（↑↓ 召回历史）',
                        hintStyle:
                            TextStyle(color: wb.textMuted, fontSize: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => unawaited(_run()),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: _favorites.contains(_cmdCtrl.text.trim())
                        ? '取消收藏'
                        : '收藏当前命令',
                    iconSize: 20,
                    onPressed: _cmdCtrl.text.trim().isEmpty
                        ? null
                        : () => unawaited(_toggleFavoriteCurrent()),
                    icon: Icon(
                      _favorites.contains(_cmdCtrl.text.trim())
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: _favorites.contains(_cmdCtrl.text.trim())
                          ? const Color(0xFFEAB308)
                          : wb.textMuted,
                    ),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: _running ? null : () => unawaited(_run()),
                    child: const Text('运行'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final p in _presets) ...[
                      FilterChip(
                        label: Text(p, style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        onSelected: (_) => _applyPreset(p),
                      ),
                      const SizedBox(width: 6),
                    ],
                    for (final f in _favorites)
                      if (!_presets.contains(f)) ...[
                        InputChip(
                          label: Text(f, style: const TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          avatar: Icon(
                            Icons.star_rounded,
                            size: 14,
                            color: const Color(0xFFEAB308),
                          ),
                          onPressed: () => _applyPreset(f),
                          onDeleted: () {
                            setState(() {
                              _favorites = [
                                for (final x in _favorites) if (x != f) x,
                              ];
                            });
                            unawaited(_persistFavorites());
                          },
                        ),
                        const SizedBox(width: 6),
                      ],
                  ],
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text(
                  _error!,
                  style: TextStyle(color: wb.offline, fontSize: 12),
                ),
              ),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: wb.terminalBg,
                  border: Border(top: BorderSide(color: wb.border)),
                ),
                child: !hasOutput
                    ? Center(
                        child: Text(
                          _running ? '等待输出…' : '输入命令后运行',
                          style: TextStyle(color: wb.textMuted),
                        ),
                      )
                    : SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                        child: SelectableText(
                          output,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.35,
                            color: wb.secondaryText,
                          ),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: !hasOutput
                        ? null
                        : () async {
                            await Clipboard.setData(
                              ClipboardData(text: output),
                            );
                          },
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('复制'),
                  ),
                  TextButton.icon(
                    onPressed: !hasOutput && !_running ? null : _clearOutput,
                    icon: const Icon(Icons.clear_all_rounded, size: 16),
                    label: const Text('清空输出'),
                  ),
                  const Spacer(),
                  Text(
                    _running
                        ? '运行中'
                        : (_stream?.exitCode != null
                            ? '退出码 ${_stream!.exitCode}'
                            : hasOutput
                                ? '${output.split('\n').length} 行'
                                : '0 行'),
                    style: TextStyle(fontSize: 11, color: wb.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
