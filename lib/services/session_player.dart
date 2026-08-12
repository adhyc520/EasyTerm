import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'session_recorder.dart';

enum SessionPlayerState { idle, playing, paused, stopped }

/// Replays a [SessionRecorder] capture into a terminal via [onOutput].
class SessionPlayer extends ChangeNotifier {
  final List<SessionEvent> _events = [];
  SessionPlayerState _state = SessionPlayerState.idle;
  double _speed = 1.0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _cols = 80;
  int _rows = 24;
  Timer? _timer;
  int _eventIndex = 0;
  DateTime? _playAnchorWall;
  Duration? _playAnchorPos;

  /// Called with output chunks to write into a Terminal.
  void Function(String data)? onOutput;

  /// Called on resize events during playback.
  void Function(int cols, int rows)? onResize;

  SessionPlayerState get state => _state;
  bool get isPlaying => _state == SessionPlayerState.playing;
  bool get isPaused => _state == SessionPlayerState.paused;
  double get speed => _speed;
  Duration get position => _position;
  Duration get duration => _duration;
  int get cols => _cols;
  int get rows => _rows;
  List<SessionEvent> get events => List.unmodifiable(_events);

  Future<void> loadFromFile(String path) async {
    stop();
    _events.clear();
    final raw = await File(path).readAsString();
    final trimmed = raw.trimLeft();
    if (trimmed.startsWith('{') && !trimmed.contains('\n')) {
      _loadInternalJson(jsonDecode(trimmed) as Map<String, dynamic>);
    } else if (trimmed.startsWith('{')) {
      // Could be pretty-printed internal JSON or asciicast header line.
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map && decoded.containsKey('events')) {
          _loadInternalJson(Map<String, dynamic>.from(decoded));
        } else {
          _loadAsciicast(raw);
        }
      } catch (_) {
        _loadAsciicast(raw);
      }
    } else {
      _loadAsciicast(raw);
    }
    _state = SessionPlayerState.idle;
    _position = Duration.zero;
    _eventIndex = 0;
    notifyListeners();
  }

  void loadEvents(
    List<SessionEvent> events, {
    int cols = 80,
    int rows = 24,
  }) {
    stop();
    _events
      ..clear()
      ..addAll(events);
    _cols = cols;
    _rows = rows;
    _duration = _events.isEmpty ? Duration.zero : _events.last.offset;
    _state = SessionPlayerState.idle;
    _position = Duration.zero;
    _eventIndex = 0;
    notifyListeners();
  }

  void _loadInternalJson(Map<String, dynamic> map) {
    _cols = (map['cols'] as num?)?.toInt() ?? 80;
    _rows = (map['rows'] as num?)?.toInt() ?? 24;
    final list = map['events'] as List<dynamic>? ?? const [];
    for (final e in list) {
      if (e is Map) {
        _events.add(SessionEvent.fromJson(Map<String, Object?>.from(e)));
      }
    }
    _duration = _events.isEmpty ? Duration.zero : _events.last.offset;
  }

  void _loadAsciicast(String raw) {
    final lines = const LineSplitter().convert(raw);
    if (lines.isEmpty) return;
    try {
      final header = jsonDecode(lines.first) as Map<String, dynamic>;
      _cols = (header['width'] as num?)?.toInt() ?? 80;
      _rows = (header['height'] as num?)?.toInt() ?? 24;
    } catch (_) {}
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      try {
        final row = jsonDecode(line) as List<dynamic>;
        if (row.length < 3) continue;
        final sec = (row[0] as num).toDouble();
        final kind = row[1] as String;
        final data = row[2] as String;
        final offset = Duration(microseconds: (sec * 1e6).round());
        switch (kind) {
          case 'o':
            _events.add(
              SessionEvent(
                type: SessionEventType.output,
                data: data,
                offset: offset,
              ),
            );
          case 'i':
            _events.add(
              SessionEvent(
                type: SessionEventType.input,
                data: data,
                offset: offset,
              ),
            );
          case 'r':
            final parts = data.split('x');
            final c = int.tryParse(parts.first) ?? _cols;
            final r = parts.length > 1
                ? (int.tryParse(parts[1]) ?? _rows)
                : _rows;
            _events.add(
              SessionEvent(
                type: SessionEventType.resize,
                data: '',
                offset: offset,
                cols: c,
                rows: r,
              ),
            );
        }
      } catch (_) {
        // Skip malformed lines.
      }
    }
    _duration = _events.isEmpty ? Duration.zero : _events.last.offset;
  }

  void play({double speed = 1.0}) {
    if (_events.isEmpty) return;
    _speed = speed <= 0 ? 1.0 : speed;
    if (_state == SessionPlayerState.paused) {
      _state = SessionPlayerState.playing;
      _armTimer();
      notifyListeners();
      return;
    }
    if (_position >= _duration && _duration > Duration.zero) {
      seek(Duration.zero);
    }
    _state = SessionPlayerState.playing;
    _armTimer();
    notifyListeners();
  }

  void pause() {
    if (_state != SessionPlayerState.playing) return;
    _timer?.cancel();
    _timer = null;
    _state = SessionPlayerState.paused;
    notifyListeners();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _state = SessionPlayerState.stopped;
    _position = Duration.zero;
    _eventIndex = 0;
    _playAnchorWall = null;
    _playAnchorPos = null;
    notifyListeners();
  }

  void seek(Duration offset) {
    final target = offset < Duration.zero
        ? Duration.zero
        : (offset > _duration ? _duration : offset);
    _position = target;
    // Find first event at/after target; emit all output up to target instantly.
    _eventIndex = 0;
    while (_eventIndex < _events.length &&
        _events[_eventIndex].offset <= target) {
      _emit(_events[_eventIndex], silentTime: true);
      _eventIndex++;
    }
    if (_state == SessionPlayerState.playing) {
      _armTimer();
    }
    notifyListeners();
  }

  void setSpeed(double speed) {
    _speed = speed <= 0 ? 1.0 : speed;
    if (_state == SessionPlayerState.playing) {
      _armTimer();
    }
    notifyListeners();
  }

  void _armTimer() {
    _timer?.cancel();
    _playAnchorWall = DateTime.now();
    _playAnchorPos = _position;
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _tick();
    });
  }

  void _tick() {
    if (_state != SessionPlayerState.playing) return;
    final wall = _playAnchorWall;
    final anchor = _playAnchorPos;
    if (wall == null || anchor == null) return;
    final elapsed = DateTime.now().difference(wall);
    final scaled = Duration(
      microseconds: (elapsed.inMicroseconds * _speed).round(),
    );
    _position = anchor + scaled;
    while (_eventIndex < _events.length &&
        _events[_eventIndex].offset <= _position) {
      _emit(_events[_eventIndex]);
      _eventIndex++;
    }
    if (_eventIndex >= _events.length) {
      _position = _duration;
      _timer?.cancel();
      _timer = null;
      _state = SessionPlayerState.stopped;
    }
    notifyListeners();
  }

  void _emit(SessionEvent e, {bool silentTime = false}) {
    switch (e.type) {
      case SessionEventType.output:
        onOutput?.call(e.data);
      case SessionEventType.input:
        // Inputs are not echoed during replay unless desired; skip.
        break;
      case SessionEventType.resize:
        final c = e.cols ?? _cols;
        final r = e.rows ?? _rows;
        _cols = c;
        _rows = r;
        onResize?.call(c, r);
    }
    if (!silentTime) {
      // position already advanced by tick
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
