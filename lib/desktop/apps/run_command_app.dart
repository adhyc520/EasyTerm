import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote_stream.dart';
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
  final SshWorkspaceController controller;

  @override
  State<RunCommandApp> createState() => _RunCommandAppState();
}

class _RunCommandAppState extends State<RunCommandApp> {
  final _cmdCtrl = TextEditingController();
  final _scroll = ScrollController();
  RemoteStream? _stream;
  bool _running = false;
  String? _error;
  bool _stickBottom = true;

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
  }

  @override
  void dispose() {
    widget.window.onConnectionRestored = null;
    unawaited(_stop());
    _cmdCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _stop() async {
    final s = _stream;
    _stream = null;
    if (s == null) return;
    s.removeListener(_onStream);
    widget.controller.unregisterRemoteStream(s);
    await s.stop();
  }

  Future<void> _run() async {
    final cmd = _cmdCtrl.text.trim();
    if (cmd.isEmpty) return;
    if (!widget.controller.connected || widget.controller.dropped) {
      setState(() => _error = '未连接');
      return;
    }
    await _stop();
    setState(() {
      _running = true;
      _error = null;
    });
    widget.window.title = '运行 · ${cmd.length > 24 ? '${cmd.substring(0, 24)}…' : cmd}';
    widget.wm.requestRebuild();
    try {
      final stream = await widget.controller.startRemoteStream(cmd, maxLines: 4000);
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
    final lines = _stream?.lines ?? const <String>[];

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
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: wb.primaryText,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '例如：df -h · who · du -sh /var',
                        hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      onSubmitted: (_) => unawaited(_run()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _running ? null : () => unawaited(_run()),
                    child: const Text('运行'),
                  ),
                ],
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
                child: lines.isEmpty
                    ? Center(
                        child: Text(
                          _running ? '等待输出…' : '输入命令后运行',
                          style: TextStyle(color: wb.textMuted),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                        itemCount: lines.length,
                        itemBuilder: (context, i) {
                          return SelectableText(
                            lines[i],
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.35,
                              color: wb.secondaryText,
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
                            await Clipboard.setData(
                              ClipboardData(text: lines.join('\n')),
                            );
                          },
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('复制'),
                  ),
                  const Spacer(),
                  Text(
                    _running
                        ? '运行中'
                        : (_stream?.exitCode != null
                            ? '退出码 ${_stream!.exitCode}'
                            : '${lines.length} 行'),
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
