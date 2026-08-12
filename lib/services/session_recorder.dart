import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum SessionEventType { input, output, resize }

class SessionEvent {
  const SessionEvent({
    required this.type,
    required this.data,
    required this.offset,
    this.cols,
    this.rows,
  });

  final SessionEventType type;
  final String data;
  final Duration offset;
  final int? cols;
  final int? rows;

  Map<String, Object?> toJson() => {
        'type': type.name,
        'data': data,
        'offsetMs': offset.inMilliseconds,
        if (cols != null) 'cols': cols,
        if (rows != null) 'rows': rows,
      };

  factory SessionEvent.fromJson(Map<String, Object?> json) {
    final typeName = json['type'] as String? ?? 'output';
    final type = SessionEventType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => SessionEventType.output,
    );
    final ms = (json['offsetMs'] as num?)?.toInt() ?? 0;
    return SessionEvent(
      type: type,
      data: json['data'] as String? ?? '',
      offset: Duration(milliseconds: ms),
      cols: (json['cols'] as num?)?.toInt(),
      rows: (json['rows'] as num?)?.toInt(),
    );
  }
}

enum SessionRecordingFormat { asciicastV2, internalJson }

/// Records PTY I/O for local replay / asciinema export.
class SessionRecorder extends ChangeNotifier {
  /// Soft cap — recording continues past this but [reachedSoftLimit] is true.
  static const Duration maxDuration = Duration(hours: 2);

  final List<SessionEvent> _events = [];
  bool _recording = false;
  DateTime? _startTime;
  int _cols = 80;
  int _rows = 24;
  bool _softLimitNotified = false;

  bool get isRecording => _recording;
  DateTime? get startTime => _startTime;
  List<SessionEvent> get events => List.unmodifiable(_events);
  bool get reachedSoftLimit {
    final start = _startTime;
    if (start == null) return false;
    return DateTime.now().difference(start) >= maxDuration;
  }

  Duration get elapsed {
    final start = _startTime;
    if (start == null) return Duration.zero;
    return DateTime.now().difference(start);
  }

  void start({int cols = 80, int rows = 24}) {
    _events.clear();
    _recording = true;
    _startTime = DateTime.now();
    _cols = cols;
    _rows = rows;
    _softLimitNotified = false;
    notifyListeners();
  }

  void stop() {
    if (!_recording) return;
    _recording = false;
    notifyListeners();
  }

  Duration _offset([DateTime? at]) {
    final start = _startTime ?? DateTime.now();
    return (at ?? DateTime.now()).difference(start);
  }

  void _maybeSoftLimit() {
    if (_softLimitNotified || !reachedSoftLimit) return;
    _softLimitNotified = true;
    notifyListeners();
  }

  void recordOutput(String data, [DateTime? timestamp]) {
    if (!_recording || data.isEmpty) return;
    _events.add(
      SessionEvent(
        type: SessionEventType.output,
        data: data,
        offset: _offset(timestamp),
      ),
    );
    _maybeSoftLimit();
  }

  void recordInput(String data, [DateTime? timestamp]) {
    if (!_recording || data.isEmpty) return;
    _events.add(
      SessionEvent(
        type: SessionEventType.input,
        data: data,
        offset: _offset(timestamp),
      ),
    );
    _maybeSoftLimit();
  }

  void recordResize(int cols, int rows, [DateTime? timestamp]) {
    if (!_recording) return;
    _cols = cols;
    _rows = rows;
    _events.add(
      SessionEvent(
        type: SessionEventType.resize,
        data: '',
        offset: _offset(timestamp),
        cols: cols,
        rows: rows,
      ),
    );
    _maybeSoftLimit();
  }

  /// Writes asciicast v2 (JSON lines) or internal JSON array to [path].
  Future<void> saveToFile(
    String path, {
    SessionRecordingFormat format = SessionRecordingFormat.asciicastV2,
    String? title,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    if (format == SessionRecordingFormat.internalJson) {
      final payload = {
        'version': 1,
        'cols': _cols,
        'rows': _rows,
        'startedAt': _startTime?.toIso8601String(),
        'events': _events.map((e) => e.toJson()).toList(),
      };
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
      return;
    }

    final buf = StringBuffer();
    final header = {
      'version': 2,
      'width': _cols,
      'height': _rows,
      'timestamp': (_startTime ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
      if (title != null && title.isNotEmpty) 'title': title,
      'env': {'TERM': 'xterm-256color'},
    };
    buf.writeln(jsonEncode(header));
    for (final e in _events) {
      final sec = e.offset.inMicroseconds / 1e6;
      switch (e.type) {
        case SessionEventType.output:
          buf.writeln(jsonEncode([sec, 'o', e.data]));
        case SessionEventType.input:
          buf.writeln(jsonEncode([sec, 'i', e.data]));
        case SessionEventType.resize:
          final cols = e.cols ?? _cols;
          final rows = e.rows ?? _rows;
          buf.writeln(jsonEncode([sec, 'r', '${cols}x$rows']));
      }
    }
    await file.writeAsString(buf.toString());
  }
}
