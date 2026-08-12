import 'dart:async';

import 'package:flutter/material.dart';

import '../services/session_player.dart';
import '../services/session_recorder.dart';
import '../theme/workbench_theme.dart';

/// Compact bar for session record / replay controls over a terminal.
class TerminalRecordingControls extends StatefulWidget {
  const TerminalRecordingControls({
    super.key,
    this.recorder,
    this.player,
    this.onToggleRecord,
    this.onPlay,
    this.onPause,
    this.onStop,
    this.onSeek,
    this.onSpeedChanged,
    this.onSave,
  });

  final SessionRecorder? recorder;
  final SessionPlayer? player;
  final VoidCallback? onToggleRecord;
  final VoidCallback? onPlay;
  final VoidCallback? onPause;
  final VoidCallback? onStop;
  final ValueChanged<Duration>? onSeek;
  final ValueChanged<double>? onSpeedChanged;
  final VoidCallback? onSave;

  @override
  State<TerminalRecordingControls> createState() =>
      _TerminalRecordingControlsState();
}

class _TerminalRecordingControlsState extends State<TerminalRecordingControls> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    widget.recorder?.addListener(_onChanged);
    widget.player?.addListener(_onChanged);
    _syncTick();
  }

  @override
  void didUpdateWidget(covariant TerminalRecordingControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.recorder, widget.recorder)) {
      oldWidget.recorder?.removeListener(_onChanged);
      widget.recorder?.addListener(_onChanged);
    }
    if (!identical(oldWidget.player, widget.player)) {
      oldWidget.player?.removeListener(_onChanged);
      widget.player?.addListener(_onChanged);
    }
    _syncTick();
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.recorder?.removeListener(_onChanged);
    widget.player?.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
    _syncTick();
  }

  void _syncTick() {
    final recording = widget.recorder?.isRecording ?? false;
    final playing = widget.player?.isPlaying ?? false;
    if (recording || playing) {
      _tick ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final rec = widget.recorder;
    final play = widget.player;
    final recording = rec?.isRecording ?? false;
    final playing = play?.isPlaying ?? false;
    final paused = play?.isPaused ?? false;
    final showPlayer = play != null &&
        (playing ||
            paused ||
            (play.state == SessionPlayerState.stopped &&
                play.events.isNotEmpty));

    if (!recording && !showPlayer && widget.onToggleRecord == null) {
      return const SizedBox.shrink();
    }

    return Material(
      color: wb.panelElevated,
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 420;
            return Row(
              children: [
                if (widget.onToggleRecord != null)
                  IconButton(
                    tooltip: recording ? '停止录制' : '开始录制',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: widget.onToggleRecord,
                    icon: Icon(
                      recording
                          ? Icons.stop_circle_outlined
                          : Icons.fiber_manual_record,
                      color: recording ? const Color(0xFFEF4444) : wb.textMuted,
                    ),
                  ),
                if (recording) ...[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFFEF4444),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _fmt(rec!.elapsed),
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: wb.primaryText,
                    ),
                  ),
                  if (rec.reachedSoftLimit && !narrow) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '已达 2h 软限制',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: wb.textMuted),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (widget.onSave != null)
                    TextButton(
                      onPressed: widget.onSave,
                      child: const Text('保存'),
                    ),
                ],
                if (showPlayer) ...[
                  IconButton(
                    tooltip: playing ? '暂停' : '播放',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: playing ? widget.onPause : widget.onPlay,
                    icon: Icon(
                      playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: wb.accentBlue,
                    ),
                  ),
                  IconButton(
                    tooltip: '停止',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: widget.onStop,
                    icon: Icon(Icons.stop_rounded, color: wb.textMuted),
                  ),
                  Expanded(
                    child: Slider(
                      value: play.duration.inMilliseconds == 0
                          ? 0
                          : (play.position.inMilliseconds /
                                  play.duration.inMilliseconds)
                              .clamp(0.0, 1.0),
                      onChanged: widget.onSeek == null
                          ? null
                          : (v) {
                              final ms =
                                  (v * play.duration.inMilliseconds).round();
                              widget.onSeek!(Duration(milliseconds: ms));
                            },
                    ),
                  ),
                  Flexible(
                    child: Text(
                      narrow
                          ? _fmt(play.position)
                          : '${_fmt(play.position)} / ${_fmt(play.duration)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: wb.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  PopupMenuButton<double>(
                    tooltip: '速度',
                    initialValue: play.speed,
                    onSelected: widget.onSpeedChanged,
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 0.5, child: Text('0.5×')),
                      PopupMenuItem(value: 1.0, child: Text('1×')),
                      PopupMenuItem(value: 2.0, child: Text('2×')),
                      PopupMenuItem(value: 4.0, child: Text('4×')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        '${play.speed}×',
                        style: TextStyle(fontSize: 12, color: wb.primaryText),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }
}
