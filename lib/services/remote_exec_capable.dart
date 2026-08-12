import 'remote_host_metrics.dart';
import 'remote_process_list.dart' show RemoteOsKind;
import 'remote_stream.dart';

/// Remote command execution (native SSH exec or ShellExecEmulator).
abstract class RemoteExecCapable {
  bool get connected;
  bool get dropped;

  Future<String?> runQueued(
    String command, {
    Duration timeout = const Duration(seconds: 15),
    List<int>? stdinBytes,
  });

  /// Alias used by metrics helpers (same as [runQueued]).
  ///
  /// Implementers should forward to [runQueued]. (Default bodies on abstract
  /// interface methods are unreliable under circular imports in this package.)
  Future<String?> runRemoteForStatus(String command);

  String? get lastRemoteCommandError;

  /// Telnet/Serial 等仿真 exec：调用方应避免额外的重量级命令（如 docker stats）。
  bool get lightweightRemoteExec;

  Future<RemoteStream> startRemoteStream(
    String command, {
    int maxLines = 5000,
    List<int>? stdinBytes,
  });

  void unregisterRemoteStream(RemoteStream stream);

  Future<RemoteHostSnapshot?> snapshot({
    Duration maxAge = const Duration(seconds: 3),
    RemoteOsKind? osHint,
  });

  /// Working directory: SFTP absolute('.') on SSH; `pwd` via exec elsewhere.
  String get remoteCwd;
}
