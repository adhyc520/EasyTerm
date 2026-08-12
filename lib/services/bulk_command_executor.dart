import 'dart:async';
import 'dart:convert';

import 'ssh_workspace_controller.dart';
import 'remote_exec_capable.dart';
import 'terminal_session_controller.dart';

class BulkCommandResult {
  BulkCommandResult({
    required this.host,
    required this.duration,
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.timedOut = false,
    this.error,
  });

  final String host;
  final int? exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;
  final bool timedOut;
  final String? error;

  bool get ok => error == null && !timedOut && (exitCode == null || exitCode == 0);
}

/// 在多台已连接主机上批量执行命令。
class BulkCommandExecutor {
  BulkCommandExecutor();

  static const int maxOutputLines = 1000;

  Future<List<BulkCommandResult>> executeOnHosts({
    required List<TerminalSessionController> hosts,
    required String command,
    required int timeoutSec,
    bool parallel = true,
    int maxConcurrency = 10,
  }) async {
    final cmd = command.trim();
    if (cmd.isEmpty) {
      return [
        for (final h in hosts)
          BulkCommandResult(
            host: _label(h),
            duration: Duration.zero,
            error: '命令为空',
          ),
      ];
    }
    final timeout = Duration(seconds: timeoutSec.clamp(1, 3600));
    final concurrency = maxConcurrency.clamp(1, 64);

    if (!parallel || hosts.length <= 1) {
      final out = <BulkCommandResult>[];
      for (final h in hosts) {
        out.add(await _runOne(h, cmd, timeout));
      }
      return out;
    }

    final results = List<BulkCommandResult?>.filled(hosts.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next;
        next++;
        if (i >= hosts.length) return;
        results[i] = await _runOne(hosts[i], cmd, timeout);
      }
    }

    final workers = List.generate(
      concurrency.clamp(1, hosts.length),
      (_) => worker(),
    );
    await Future.wait(workers);
    return [
      for (var i = 0; i < results.length; i++)
        results[i] ??
            BulkCommandResult(
              host: _label(hosts[i]),
              duration: Duration.zero,
              error: '未执行',
            ),
    ];
  }

  static String _label(TerminalSessionController h) => h.sessionLabel;

  static String _trimOutput(String text) {
    final lines = const LineSplitter().convert(text);
    if (lines.length <= maxOutputLines) return text;
    final kept = lines.sublist(lines.length - maxOutputLines);
    return '[… truncated ${lines.length - maxOutputLines} lines …]\n${kept.join('\n')}';
  }

  Future<BulkCommandResult> _runOne(
    TerminalSessionController host,
    String command,
    Duration timeout,
  ) async {
    final label = _label(host);
    final sw = Stopwatch()..start();
    if (!host.connected || host.dropped) {
      sw.stop();
      return BulkCommandResult(
        host: label,
        duration: sw.elapsed,
        error: '未连接',
      );
    }

    if (host is SshWorkspaceController) {
      final client = host.clientForDesktop;
      if (client != null) {
        try {
          final result = await client.runWithResult(command).timeout(timeout);
          sw.stop();
          return BulkCommandResult(
            host: label,
            exitCode: result.exitCode,
            stdout: _trimOutput(
              utf8.decode(result.stdout, allowMalformed: true),
            ),
            stderr: _trimOutput(
              utf8.decode(result.stderr, allowMalformed: true),
            ),
            duration: sw.elapsed,
          );
        } on TimeoutException {
          sw.stop();
          return BulkCommandResult(
            host: label,
            duration: sw.elapsed,
            timedOut: true,
            error: '超时（${timeout.inSeconds}s）',
          );
        } catch (e) {
          sw.stop();
          return BulkCommandResult(
            host: label,
            duration: sw.elapsed,
            error: '$e',
          );
        }
      }
    }

    if (host is RemoteExecCapable) {
      final exec = host as RemoteExecCapable;
      try {
        final out = await exec.runQueued(
          command,
          timeout: timeout,
          // Avoid injecting into the user's interactive Telnet console.
          allowInteractiveFallback: false,
        );
        sw.stop();
        if (out == null) {
          return BulkCommandResult(
            host: label,
            duration: sw.elapsed,
            error: exec.lastRemoteCommandError ?? '执行失败',
          );
        }
        return BulkCommandResult(
          host: label,
          exitCode: exec.lastRemoteExitCode,
          stdout: _trimOutput(out),
          duration: sw.elapsed,
        );
      } on TimeoutException {
        sw.stop();
        return BulkCommandResult(
          host: label,
          duration: sw.elapsed,
          timedOut: true,
          error: '超时（${timeout.inSeconds}s）',
        );
      } catch (e) {
        sw.stop();
        return BulkCommandResult(
          host: label,
          duration: sw.elapsed,
          error: '$e',
        );
      }
    }

    sw.stop();
    return BulkCommandResult(
      host: label,
      duration: sw.elapsed,
      error: '当前协议不支持远程执行',
    );
  }
}
