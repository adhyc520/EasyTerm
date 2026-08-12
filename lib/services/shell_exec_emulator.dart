import 'dart:async';
import 'dart:convert';

import 'remote_stream.dart';

/// Byte-stream shell backend for [ShellExecEmulator].
abstract class ShellBackend {
  void write(List<int> bytes);
  Stream<List<int>> get output;
}

/// Simulates SSH-style exec over an interactive shell using sentinel markers.
///
/// [run] and [startStream] are mutually exclusive on the same backend: a stream
/// blocks queued runs until stopped, and starting a stream waits for in-flight
/// runs to finish.
///
/// Finite [startStream] commands are wrapped with begin/end sentinels and the
/// returned [RemoteStream] closes when the command exits. Follow-style commands
/// (`tail -f`, `journalctl -f`, …) stay open until [RemoteStream.stop].
class ShellExecEmulator {
  ShellExecEmulator(
    this._backend, {
    Encoding encoding = const Utf8Codec(allowMalformed: true),
  }) : _encoding = encoding {
    _fanout = StreamController<List<int>>.broadcast();
    _sub = _backend.output.listen(
      (chunk) {
        if (!_fanout.isClosed) _fanout.add(chunk);
        if (chunk.isEmpty) return;
        if (_followActive) {
          // Follow streams consume via fanout only — do not grow job buffer.
          return;
        }
        _buf.write(_encoding.decode(chunk));
        if (_streamJob != null) {
          _drainStreamJob();
        } else {
          _drainJobs();
        }
      },
      onError: (Object e) {
        _lastError = '$e';
        if (!_fanout.isClosed) _fanout.addError(e);
        _failCurrent(e);
        _failStreamJob(e);
      },
      onDone: () {
        // Fail in-flight jobs so RemoteStream / run completers settle and
        // release() / finally blocks free the exclusive gate. Do NOT call
        // _leaveExclusive here — that can race a newly entered holder.
        _failCurrent(StateError('shell backend closed'));
        _failStreamJob(StateError('shell backend closed'));
        _followActive = false;
        if (!_fanout.isClosed) unawaited(_fanout.close());
      },
    );
  }

  final ShellBackend _backend;
  final Encoding _encoding;
  late final StreamController<List<int>> _fanout;
  StreamSubscription<List<int>>? _sub;

  final _queue = <_QueuedJob>[];
  bool _draining = false;
  int _seq = 0;
  String? _lastError;
  int? _lastExitCode;
  final StringBuffer _buf = StringBuffer();

  /// Exclusive holder: completes when the current run/stream finishes.
  Completer<void>? _exclusive;

  /// Active finite stream job (sentinel-wrapped).
  _StreamJob? _streamJob;

  /// Follow-mode stream: fanout only, no `_buf` growth.
  bool _followActive = false;

  String? get lastError => _lastError;

  /// Exit code from the most recent completed [run] (null on timeout/fail).
  int? get lastExitCode => _lastExitCode;

  Future<void> _enterExclusive({
    Duration waitTimeout = const Duration(seconds: 12),
  }) async {
    final deadline = DateTime.now().add(waitTimeout);
    while (true) {
      final current = _exclusive;
      if (current == null) {
        _exclusive = Completer<void>();
        return;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException(
          'exec busy: another run/stream holds the shell',
        );
      }
      try {
        await current.future.timeout(left);
      } on TimeoutException {
        throw TimeoutException(
          'exec busy: another run/stream holds the shell',
        );
      }
    }
  }

  void _leaveExclusive() {
    final c = _exclusive;
    _exclusive = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<String?> run(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    List<int>? stdinBytes,
  }) async {
    _lastExitCode = null;
    try {
      await _enterExclusive();
    } on TimeoutException {
      _lastError = 'exec 繁忙（可能有日志跟随占用），稍后重试';
      return null;
    }
    try {
      return await _runLocked(command, timeout: timeout, stdinBytes: stdinBytes);
    } finally {
      _leaveExclusive();
    }
  }

  Future<String?> _runLocked(
    String command, {
    required Duration timeout,
    List<int>? stdinBytes,
  }) async {
    final id = _nextId();
    final begin = '\x01B$id\x01';
    final end = '\x01E$id\x01';
    final completer = Completer<_RunOutcome?>();
    final job = _QueuedJob(
      id: id,
      begin: begin,
      end: end,
      completer: completer,
    );
    _queue.add(job);

    final escapedBegin = _shSingleQuote(begin);
    final escapedEnd = _shSingleQuote(end);
    // Leading newline clears a half-typed line on shared primary shells (Telnet/Serial).
    final script =
        "\nprintf '%s' $escapedBegin; $command; printf '\\n%s:%s\\n' $escapedEnd \"\$?\"\n";
    _backend.write(_encoding.encode(script));
    if (stdinBytes != null && stdinBytes.isNotEmpty) {
      _backend.write(stdinBytes);
    }

    try {
      final outcome = await completer.future.timeout(timeout, onTimeout: () {
        _lastError = 'exec timeout (${timeout.inSeconds}s)';
        _lastExitCode = null;
        _queue.remove(job);
        try {
          _backend.write([0x03]);
        } catch (_) {}
        _buf.clear();
        if (!completer.isCompleted) completer.complete(null);
        return null;
      });
      if (outcome == null) {
        _lastExitCode = null;
        return null;
      }
      _lastExitCode = outcome.exitCode;
      return outcome.output;
    } catch (e) {
      _lastError = '$e';
      _lastExitCode = null;
      return null;
    }
  }

  /// Starts a streaming command. Blocks [run] until the returned stream is
  /// closed / [RemoteStream.stop]ped (or this emulator is disposed).
  ///
  /// When [follow] is null, follow mode is inferred from the command line
  /// (`tail -f`, `journalctl -f`, …). Finite commands auto-close the stream.
  Future<RemoteStream> startStream(
    String command, {
    int maxLines = 5000,
    List<int>? stdinBytes,
    bool? follow,
  }) async {
    try {
      await _enterExclusive();
    } on TimeoutException {
      _lastError = 'exec 繁忙，无法启动日志流';
      throw StateError(_lastError!);
    }
    _buf.clear();
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _followActive = false;
      _streamJob = null;
      _leaveExclusive();
    }

    final isFollow = follow ?? looksLikeFollowCommand(command);
    if (isFollow) {
      _followActive = true;
      final stream = RemoteStream.fromByteSource(
        command: command,
        maxLines: maxLines,
        stdout: _fanout.stream.map((c) => _encoding.decode(c)),
        cancel: () async {
        if (!_followActive) {
          // Already released via natural close / dispose — do not inject ^C.
          release();
          return;
        }
        try {
          _backend.write([0x03]);
        } catch (_) {}
        release();
      },
    );
      unawaited(stream.waitUntilClosed().whenComplete(release));
      _backend.write(_encoding.encode('$command\n'));
      if (stdinBytes != null && stdinBytes.isNotEmpty) {
        _backend.write(stdinBytes);
      }
      return stream;
    }

    final id = _nextId();
    final begin = '\x01B$id\x01';
    final end = '\x01E$id\x01';
    final stdoutCtrl = StreamController<String>();
    final exitCompleter = Completer<int?>();
    final job = _StreamJob(
      begin: begin,
      end: end,
      stdout: stdoutCtrl,
      exit: exitCompleter,
    );
    _streamJob = job;

    final stream = RemoteStream.fromByteSource(
      command: command,
      maxLines: maxLines,
      stdout: stdoutCtrl.stream,
      exitCode: exitCompleter.future,
      cancel: () async {
        if (job.finished) {
          release();
          return;
        }
        try {
          _backend.write([0x03]);
        } catch (_) {}
        await _finishStreamJob(job, exitCode: null, interrupted: true);
        release();
      },
    );
    unawaited(stream.waitUntilClosed().whenComplete(release));

    final escapedBegin = _shSingleQuote(begin);
    final escapedEnd = _shSingleQuote(end);
    final script =
        "printf '%s' $escapedBegin; $command; printf '\\n%s:%s\\n' $escapedEnd \"\$?\"\n";
    _backend.write(_encoding.encode(script));
    if (stdinBytes != null && stdinBytes.isNotEmpty) {
      _backend.write(stdinBytes);
    }
    return stream;
  }

  /// Whether [command] looks like a never-ending follow/tail process.
  static bool looksLikeFollowCommand(String command) {
    final c = command.trim();
    if (c.isEmpty) return false;
    if (RegExp(r'\btail\b(?:\s+-[^\s]*)*\s+-[fF]\b').hasMatch(c)) {
      return true;
    }
    if (RegExp(r'\btail\b.*\s-[fF]\b').hasMatch(c)) return true;
    if (RegExp(r'\bjournalctl\b.*\s-f\b').hasMatch(c)) return true;
    if (RegExp(r'\bless\s+\+F\b').hasMatch(c)) return true;
    if (RegExp(r'\bfollow\b', caseSensitive: false).hasMatch(c) &&
        RegExp(r'\b(-f|--follow)\b').hasMatch(c)) {
      return true;
    }
    return false;
  }

  String _nextId() {
    _seq = (_seq + 1) & 0xffff;
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}$_seq';
  }

  static String _shSingleQuote(String s) {
    return "'${s.replaceAll("'", "'\\''")}'";
  }

  void _drainStreamJob() {
    final job = _streamJob;
    if (job == null || job.finished) return;
    var text = _buf.toString();

    if (!job.begun) {
      final bi = text.indexOf(job.begin);
      if (bi < 0) {
        // Bound search window so a missing begin cannot grow forever.
        if (text.length > 16384) {
          _buf.clear();
          _buf.write(text.substring(text.length - 4096));
        }
        return;
      }
      job.begun = true;
      text = text.substring(bi + job.begin.length);
      _buf
        ..clear()
        ..write(text);
    }

    text = _buf.toString();
    final ei = text.indexOf(job.end);
    if (ei < 0) {
      final keep = job.end.length + 8;
      if (text.length > keep) {
        final emit = text.substring(0, text.length - keep);
        job.emit(emit);
        _buf
          ..clear()
          ..write(text.substring(text.length - keep));
      }
      return;
    }

    final body = text.substring(0, ei);
    if (body.isNotEmpty) job.emit(body);

    final afterEnd = text.substring(ei);
    final codeMatch =
        RegExp('^${RegExp.escape(job.end)}:(\\d+)').firstMatch(afterEnd);
    var consumeTo = ei + job.end.length;
    int? code;
    if (codeMatch != null) {
      code = int.tryParse(codeMatch.group(1) ?? '');
      consumeTo = ei + codeMatch.group(0)!.length;
    }
    if (consumeTo < text.length &&
        (text.codeUnitAt(consumeTo) == 0x0a ||
            text.codeUnitAt(consumeTo) == 0x0d)) {
      final c = text.codeUnitAt(consumeTo);
      consumeTo++;
      if (c == 0x0d &&
          consumeTo < text.length &&
          text.codeUnitAt(consumeTo) == 0x0a) {
        consumeTo++;
      }
    }
    _buf.clear();
    if (consumeTo < text.length) {
      _buf.write(text.substring(consumeTo));
    }

    unawaited(_finishStreamJob(job, exitCode: code));
  }

  Future<void> _finishStreamJob(
    _StreamJob job, {
    required int? exitCode,
    bool interrupted = false,
  }) async {
    if (job.finished) return;
    job.finished = true;
    if (identical(_streamJob, job)) _streamJob = null;
    if (!job.exit.isCompleted) {
      job.exit.complete(interrupted ? null : exitCode);
    }
    if (!job.stdout.isClosed) {
      await job.stdout.close();
    }
  }

  void _failStreamJob(Object e) {
    final job = _streamJob;
    if (job == null || job.finished) return;
    job.finished = true;
    _streamJob = null;
    if (!job.exit.isCompleted) job.exit.complete(null);
    if (!job.stdout.isClosed) {
      job.stdout.addError(e);
      unawaited(job.stdout.close());
    }
  }

  void _drainJobs() {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.first;
        final text = _buf.toString();
        final bi = text.indexOf(job.begin);
        if (bi < 0) break;
        final afterBegin = bi + job.begin.length;
        final ei = text.indexOf(job.end, afterBegin);
        if (ei < 0) break;
        var body = text.substring(afterBegin, ei);
        final afterEnd = text.substring(ei);
        final codeMatch =
            RegExp('^${RegExp.escape(job.end)}:(\\d+)').firstMatch(afterEnd);
        var consumeTo = ei + job.end.length;
        int? code;
        if (codeMatch != null) {
          code = int.tryParse(codeMatch.group(1) ?? '');
          consumeTo = ei + codeMatch.group(0)!.length;
        }
        if (consumeTo < text.length &&
            (text.codeUnitAt(consumeTo) == 0x0a ||
                text.codeUnitAt(consumeTo) == 0x0d)) {
          final c = text.codeUnitAt(consumeTo);
          consumeTo++;
          if (c == 0x0d &&
              consumeTo < text.length &&
              text.codeUnitAt(consumeTo) == 0x0a) {
            consumeTo++;
          }
        }
        _buf.clear();
        if (consumeTo < text.length) {
          _buf.write(text.substring(consumeTo));
        }

        body = _stripAnsi(body);
        body = _stripCommandEcho(body, job);
        _queue.removeAt(0);
        if (!job.completer.isCompleted) {
          job.completer.complete(
            _RunOutcome(output: body, exitCode: code),
          );
        }
      }
    } finally {
      _draining = false;
    }
  }

  String _stripAnsi(String s) {
    return s.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '');
  }

  String _stripCommandEcho(String body, _QueuedJob job) {
    final lines = const LineSplitter().convert(body);
    if (lines.isEmpty) return body;
    final first = lines.first.trim();
    if (first.contains(job.begin) || first.startsWith('printf')) {
      return lines.skip(1).join('\n');
    }
    return body;
  }

  void _failCurrent(Object e) {
    while (_queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      if (!job.completer.isCompleted) {
        job.completer.complete(null);
      }
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _followActive = false;
    final sj = _streamJob;
    if (sj != null) {
      await _finishStreamJob(sj, exitCode: null, interrupted: true);
    }
    if (!_fanout.isClosed) await _fanout.close();
    _failCurrent(StateError('disposed'));
    _leaveExclusive();
  }
}

class _RunOutcome {
  const _RunOutcome({required this.output, required this.exitCode});

  final String output;
  final int? exitCode;
}

class _QueuedJob {
  _QueuedJob({
    required this.id,
    required this.begin,
    required this.end,
    required this.completer,
  });

  final String id;
  final String begin;
  final String end;
  final Completer<_RunOutcome?> completer;
}

class _StreamJob {
  _StreamJob({
    required this.begin,
    required this.end,
    required this.stdout,
    required this.exit,
  });

  final String begin;
  final String end;
  final StreamController<String> stdout;
  final Completer<int?> exit;
  bool begun = false;
  bool finished = false;

  void emit(String chunk) {
    if (finished || chunk.isEmpty || stdout.isClosed) return;
    stdout.add(chunk);
  }
}
