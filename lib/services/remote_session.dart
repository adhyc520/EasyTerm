import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

/// SSH 传输层：持有 [SSHClient] / [SftpClient] 与掉线监控。
///
/// [SshWorkspaceController] 通过本类管理连接；交互式 PTY / xterm 仍由控制器负责。
/// 桌面层经 [SshWorkspaceController.clientForDesktop] / `sftp` 访问同一连接。
class RemoteSession extends ChangeNotifier {
  SSHClient? _client;
  SftpClient? _sftp;
  bool _connected = false;
  bool _dropped = false;
  bool _disposed = false;

  /// 传输意外关闭且已 [detach] 后回调（[error] 可能为 null）。
  void Function(Object? error)? onTransportClosed;

  SSHClient? get client => _client;
  SftpClient? get sftp => _sftp;
  bool get connected => _connected;
  bool get dropped => _dropped;

  /// 接管**已认证**的 [SSHClient]，打开 SFTP 并开始掉线监控。
  ///
  /// 成功后所有权归本会话；失败时会关闭 [client] 并向上抛出。
  Future<void> attach(SSHClient client) async {
    if (_disposed) {
      try {
        client.close();
      } catch (_) {}
      return;
    }
    await detach(keepNotify: false);
    try {
      final sftp = await client.sftp();
      await sftp.handshake;
      if (_disposed) {
        try {
          sftp.close();
        } catch (_) {}
        try {
          client.close();
        } catch (_) {}
        return;
      }
      _client = client;
      _sftp = sftp;
      _connected = true;
      _dropped = false;
      _startDropMonitor(client);
      notifyListeners();
    } catch (_) {
      try {
        client.close();
      } catch (_) {}
      rethrow;
    }
  }

  /// 关闭 SFTP/SSH；不触发 [onTransportClosed]。
  Future<void> detach({bool keepNotify = true}) async {
    final sftp = _sftp;
    _sftp = null;
    try {
      sftp?.close();
    } catch (_) {}

    final client = _client;
    _client = null;
    _connected = false;
    try {
      client?.close();
    } catch (_) {}

    if (keepNotify && !_disposed) notifyListeners();
  }

  void clearDropped() {
    _dropped = false;
    if (!_disposed) notifyListeners();
  }

  void _startDropMonitor(SSHClient client) {
    client.done.then(
      (_) => _onTransportClosed(client, null),
      onError: (Object e, StackTrace st) => _onTransportClosed(client, e),
    );
  }

  void _onTransportClosed(SSHClient client, Object? error) {
    unawaited(_onTransportClosedAsync(client, error));
  }

  Future<void> _onTransportClosedAsync(
    SSHClient client,
    Object? error,
  ) async {
    if (_disposed) return;
    if (!identical(_client, client)) return;
    if (!_connected) return;
    debugPrint('RemoteSession transport closed: $error');
    await detach(keepNotify: false);
    _dropped = true;
    onTransportClosed?.call(error);
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    onTransportClosed = null;
    unawaited(detach(keepNotify: false));
    super.dispose();
  }
}
