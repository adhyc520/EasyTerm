import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// 本地 `ssh -L` 等价：`ServerSocket` 监听，每连接一条 [SSHClient.forwardLocal] 通道。
///
/// 注意：dartssh2 的 `forwardLocal` **不是**本地监听器，只是单条 direct-tcpip 通道。
class LocalPortForwarder {
  LocalPortForwarder(this.client, this.remoteHost, this.remotePort);

  final SSHClient client;
  final String remoteHost;
  final int remotePort;

  ServerSocket? _server;
  StreamSubscription<Socket>? _sub;
  final List<Socket> _clients = [];
  bool _stopped = false;

  int? get localPort => _server?.port;

  bool get isRunning => _server != null && !_stopped;

  Future<void> start({int? localPort}) async {
    if (_server != null) return;
    _stopped = false;
    _server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      localPort ?? 0,
    );
    _sub = _server!.listen(_onClient, onError: (_) {}, cancelOnError: false);
    unawaited(
      client.done.then((_) {
        if (_stopped) return;
        unawaited(stop());
      }),
    );
  }

  Future<void> _onClient(Socket sock) async {
    if (_stopped) {
      sock.destroy();
      return;
    }
    _clients.add(sock);
    SSHForwardChannel? ch;
    try {
      ch = await client.forwardLocal(remoteHost, remotePort);
      _pipe(sock, ch);
    } catch (_) {
      try {
        sock.destroy();
      } catch (_) {}
      try {
        ch?.destroy();
      } catch (_) {}
      _clients.remove(sock);
    }
  }

  void _pipe(Socket sock, SSHForwardChannel ch) {
    late final StreamSubscription<Uint8List> fromRemote;
    late final StreamSubscription<List<int>> fromLocal;

    void cleanup() {
      _clients.remove(sock);
      try {
        sock.destroy();
      } catch (_) {}
      try {
        ch.destroy();
      } catch (_) {}
    }

    fromRemote = ch.stream.listen(
      (data) {
        try {
          sock.add(data);
        } catch (_) {
          cleanup();
        }
      },
      onDone: () {
        unawaited(fromLocal.cancel());
        cleanup();
      },
      onError: (_) {
        unawaited(fromLocal.cancel());
        cleanup();
      },
      cancelOnError: true,
    );

    fromLocal = sock.listen(
      (data) {
        try {
          ch.sink.add(data);
        } catch (_) {
          cleanup();
        }
      },
      onDone: () {
        unawaited(fromRemote.cancel());
        cleanup();
      },
      onError: (_) {
        unawaited(fromRemote.cancel());
        cleanup();
      },
      cancelOnError: true,
    );
  }

  Future<void> stop() async {
    _stopped = true;
    await _sub?.cancel();
    _sub = null;
    for (final s in List<Socket>.from(_clients)) {
      try {
        s.destroy();
      } catch (_) {}
    }
    _clients.clear();
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
  }
}
