import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../models/proxy_config.dart';

/// 经跳板机建立的目标连接（需在会话结束时关闭 [jumpClient]）。
class JumpConnectResult {
  JumpConnectResult({
    required this.targetClient,
    required this.jumpClient,
    required this.forwardedSocket,
  });

  final SSHClient targetClient;
  final SSHClient jumpClient;

  /// [SSHForwardChannel]，实现 [SSHSocket]。
  final SSHSocket forwardedSocket;

  void closeAll() {
    try {
      targetClient.close();
    } catch (_) {}
    try {
      forwardedSocket.close();
    } catch (_) {}
    try {
      jumpClient.close();
    } catch (_) {}
  }
}

/// 通过 SSH 跳板机（ProxyJump）连接目标主机。
class ProxyConnector {
  ProxyConnector._();

  /// Open a TCP connection to [targetHost]:[targetPort] via SOCKS5 or HTTP CONNECT.
  ///
  /// Throws for [ProxyType.sshJump] / [ProxyType.sshTunnel] (use SSH jump helpers).
  /// [OpenedTcpSocket.pendingBytes] holds any payload that arrived in the same
  /// segment as the proxy reply (must be fed to the app before [Socket.listen]).
  static Future<OpenedTcpSocket> openTcpViaProxy({
    required ProxyConfig proxy,
    required String targetHost,
    required int targetPort,
    Duration? timeout,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('TCP 代理在 Web 上不可用');
    }
    final host = targetHost.trim();
    if (host.isEmpty) {
      throw ArgumentError('目标主机不能为空');
    }
    if (targetPort <= 0 || targetPort > 65535) {
      throw ArgumentError('目标端口无效: $targetPort');
    }
    final connectTimeout = timeout ?? const Duration(seconds: 30);
    switch (proxy.type) {
      case ProxyType.socks5:
        return _openSocks5(
          proxy: proxy,
          targetHost: host,
          targetPort: targetPort,
          timeout: connectTimeout,
        );
      case ProxyType.http:
        return _openHttpConnect(
          proxy: proxy,
          targetHost: host,
          targetPort: targetPort,
          timeout: connectTimeout,
        );
      case ProxyType.sshJump:
      case ProxyType.sshTunnel:
        throw StateError(
          'openTcpViaProxy 不支持 ${proxy.type.name}；请使用 SSH 跳板机接口。',
        );
    }
  }

  static Future<OpenedTcpSocket> _openSocks5({
    required ProxyConfig proxy,
    required String targetHost,
    required int targetPort,
    required Duration timeout,
  }) async {
    final proxyHost = proxy.host.trim();
    if (proxyHost.isEmpty) {
      throw ArgumentError('SOCKS5 代理主机不能为空');
    }
    final socket = await Socket.connect(proxyHost, proxy.port, timeout: timeout);
    final reader = _SocketByteReader(socket);
    try {
      final user = proxy.username.trim();
      final pass = proxy.password ?? '';
      final wantAuth = user.isNotEmpty;

      // Greeting: VER=5, METHODS
      if (wantAuth) {
        socket.add(Uint8List.fromList([0x05, 0x02, 0x00, 0x02]));
      } else {
        socket.add(Uint8List.fromList([0x05, 0x01, 0x00]));
      }
      await socket.flush();

      final greeting = await reader.readExact(2).timeout(timeout);
      if (greeting[0] != 0x05) {
        throw StateError('SOCKS5 版本不匹配: ${greeting[0]}');
      }
      final method = greeting[1];
      if (method == 0xFF) {
        throw StateError('SOCKS5 代理拒绝所有认证方法');
      }
      if (method == 0x02) {
        // Username/password auth (RFC 1929)
        final userBytes = utf8.encode(user);
        final passBytes = utf8.encode(pass);
        if (userBytes.length > 255 || passBytes.length > 255) {
          throw StateError('SOCKS5 用户名或密码过长');
        }
        final auth = BytesBuilder(copy: false)
          ..addByte(0x01)
          ..addByte(userBytes.length)
          ..add(userBytes)
          ..addByte(passBytes.length)
          ..add(passBytes);
        socket.add(auth.takeBytes());
        await socket.flush();
        final authResp = await reader.readExact(2).timeout(timeout);
        if (authResp[1] != 0x00) {
          throw StateError('SOCKS5 用户名/密码认证失败');
        }
      } else if (method != 0x00) {
        throw StateError('SOCKS5 不支持的认证方法: $method');
      }

      // CONNECT request
      final req = BytesBuilder(copy: false)
        ..addByte(0x05) // VER
        ..addByte(0x01) // CONNECT
        ..addByte(0x00); // RSV
      final ip = InternetAddress.tryParse(targetHost);
      if (ip != null && ip.type == InternetAddressType.IPv4) {
        req
          ..addByte(0x01)
          ..add(ip.rawAddress);
      } else if (ip != null && ip.type == InternetAddressType.IPv6) {
        req
          ..addByte(0x04)
          ..add(ip.rawAddress);
      } else {
        final hostBytes = utf8.encode(targetHost);
        if (hostBytes.length > 255) {
          throw ArgumentError('目标主机名过长');
        }
        req
          ..addByte(0x03)
          ..addByte(hostBytes.length)
          ..add(hostBytes);
      }
      req
        ..addByte((targetPort >> 8) & 0xFF)
        ..addByte(targetPort & 0xFF);
      socket.add(req.takeBytes());
      await socket.flush();

      final respHead = await reader.readExact(4).timeout(timeout);
      if (respHead[0] != 0x05) {
        throw StateError('SOCKS5 响应版本错误');
      }
      if (respHead[1] != 0x00) {
        throw StateError('SOCKS5 CONNECT 失败，状态码 ${respHead[1]}');
      }
      final atyp = respHead[3];
      int addrLen;
      switch (atyp) {
        case 0x01:
          addrLen = 4;
          break;
        case 0x03:
          final lenByte = await reader.readExact(1).timeout(timeout);
          addrLen = lenByte[0];
          break;
        case 0x04:
          addrLen = 16;
          break;
        default:
          throw StateError('SOCKS5 未知地址类型: $atyp');
      }
      await reader.readExact(addrLen + 2).timeout(timeout);
      final pending = reader.takeLeftover();
      await reader.cancel();
      return OpenedTcpSocket(socket, pending);
    } catch (e) {
      await reader.cancel();
      try {
        await socket.close();
      } catch (_) {}
      try {
        socket.destroy();
      } catch (_) {}
      if (e is TimeoutException) {
        throw StateError('经 SOCKS5 代理连接超时（${timeout.inSeconds}s）');
      }
      rethrow;
    }
  }

  static Future<OpenedTcpSocket> _openHttpConnect({
    required ProxyConfig proxy,
    required String targetHost,
    required int targetPort,
    required Duration timeout,
  }) async {
    final proxyHost = proxy.host.trim();
    if (proxyHost.isEmpty) {
      throw ArgumentError('HTTP 代理主机不能为空');
    }
    final socket = await Socket.connect(proxyHost, proxy.port, timeout: timeout);
    final reader = _SocketByteReader(socket);
    try {
      final authority = _httpAuthority(targetHost, targetPort);
      final buf = StringBuffer()
        ..write('CONNECT $authority HTTP/1.1\r\n')
        ..write('Host: $authority\r\n');
      final user = proxy.username.trim();
      final pass = proxy.password ?? '';
      if (user.isNotEmpty) {
        final token = base64Encode(utf8.encode('$user:$pass'));
        buf.write('Proxy-Authorization: Basic $token\r\n');
      }
      buf.write('Proxy-Connection: Keep-Alive\r\n\r\n');
      socket.write(buf.toString());
      await socket.flush();

      final headerBytes = await reader.readUntilHeadersEnd().timeout(timeout);
      final headerText = utf8.decode(headerBytes, allowMalformed: true);
      final firstLine = headerText.split('\r\n').first;
      final statusMatch = RegExp(r'^HTTP/\d\.\d\s+(\d+)').firstMatch(firstLine);
      final code = int.tryParse(statusMatch?.group(1) ?? '') ?? 0;
      if (code < 200 || code >= 300) {
        throw StateError('HTTP CONNECT 失败: $firstLine');
      }
      final pending = reader.takeLeftover();
      await reader.cancel();
      return OpenedTcpSocket(socket, pending);
    } catch (e) {
      await reader.cancel();
      try {
        await socket.close();
      } catch (_) {}
      try {
        socket.destroy();
      } catch (_) {}
      if (e is TimeoutException) {
        throw StateError('经 HTTP 代理连接超时（${timeout.inSeconds}s）');
      }
      rethrow;
    }
  }

  /// Host:port for HTTP CONNECT / Host header (bracket IPv6 literals).
  static String _httpAuthority(String host, int port) {
    final ip = InternetAddress.tryParse(host);
    if (ip != null && ip.type == InternetAddressType.IPv6) {
      return '[$host]:$port';
    }
    return '$host:$port';
  }

  /// 连接跳板 → [SSHClient.forwardLocal] 到目标 → 在转发通道上建 [SSHClient]。
  static Future<JumpConnectResult> connectViaJumpHost({
    required String targetHost,
    required int targetPort,
    required String targetUsername,
    required ProxyConfig jumpHost,
    String? targetPassword,
    String? targetPrivateKeyPem,
    Duration? timeout,
  }) async {
    final forwarded = await openForwardedSocket(
      jumpHost: jumpHost,
      targetHost: targetHost,
      targetPort: targetPort,
      timeout: timeout,
    );
    final connectTimeout = timeout ?? const Duration(seconds: 30);
    try {
      List<SSHKeyPair>? targetIdentities;
      final targetPem = targetPrivateKeyPem?.trim();
      if (targetPem != null && targetPem.isNotEmpty) {
        targetIdentities = SSHKeyPair.fromPem(
          targetPem,
          (targetPassword == null || targetPassword.isEmpty)
              ? null
              : targetPassword,
        );
      }
      final targetHasPassword =
          targetPassword != null && targetPassword.isNotEmpty;
      final targetClient = SSHClient(
        forwarded.socket,
        username: targetUsername.trim(),
        identities: targetIdentities,
        onPasswordRequest: targetHasPassword
            ? () async => targetPassword
            : null,
        onUserInfoRequest: targetHasPassword
            ? (req) async =>
                  List<String>.filled(req.prompts.length, targetPassword)
            : null,
      );
      await targetClient.authenticated.timeout(connectTimeout);
      return JumpConnectResult(
        targetClient: targetClient,
        jumpClient: forwarded.jumpClient,
        forwardedSocket: forwarded.socket,
      );
    } catch (e) {
      try {
        forwarded.socket.destroy();
      } catch (_) {}
      try {
        forwarded.jumpClient.close();
      } catch (_) {}
      if (e is TimeoutException) {
        throw StateError('经跳板机认证目标超时（${connectTimeout.inSeconds}s）');
      }
      throw StateError('经跳板机连接目标失败：$e');
    }
  }

  /// 连接跳板并 [forwardLocal]，不创建目标 SSH 客户端（供 [SshWorkspaceController] 复用直连认证逻辑）。
  static Future<({SSHClient jumpClient, SSHSocket socket})>
  openForwardedSocket({
    required ProxyConfig jumpHost,
    required String targetHost,
    required int targetPort,
    Duration? timeout,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('跳板机连接在 Web 上不可用');
    }
    if (jumpHost.type != ProxyType.sshJump &&
        jumpHost.type != ProxyType.sshTunnel) {
      throw StateError(
        '不支持的代理类型 ${jumpHost.type.name}；目前仅支持 SSH 跳板机 (ProxyJump)。',
      );
    }
    final connectTimeout = timeout ?? const Duration(seconds: 30);
    final jumpHostName = jumpHost.host.trim();
    final jumpUser = jumpHost.username.trim();
    if (jumpHostName.isEmpty || jumpUser.isEmpty) {
      throw ArgumentError('跳板机主机与用户名不能为空');
    }
    if (targetHost.trim().isEmpty) {
      throw ArgumentError('目标主机不能为空');
    }

    SSHClient? jumpClient;
    try {
      final jumpSocket = await SSHSocket.connect(
        jumpHostName,
        jumpHost.port,
        timeout: connectTimeout,
      );
      List<SSHKeyPair>? jumpIdentities;
      final jumpPem = jumpHost.privateKeyPem?.trim();
      if (jumpPem != null && jumpPem.isNotEmpty) {
        jumpIdentities = SSHKeyPair.fromPem(
          jumpPem,
          (jumpHost.password == null || jumpHost.password!.isEmpty)
              ? null
              : jumpHost.password,
        );
      }
      final jumpHasPassword =
          jumpHost.password != null && jumpHost.password!.isNotEmpty;
      jumpClient = SSHClient(
        jumpSocket,
        username: jumpUser,
        identities: jumpIdentities,
        onPasswordRequest: jumpHasPassword
            ? () async => jumpHost.password!
            : null,
        onUserInfoRequest: jumpHasPassword
            ? (req) async =>
                  List<String>.filled(req.prompts.length, jumpHost.password!)
            : null,
      );
      await jumpClient.authenticated.timeout(connectTimeout);
      final socket = await jumpClient
          .forwardLocal(targetHost.trim(), targetPort)
          .timeout(connectTimeout);
      return (jumpClient: jumpClient, socket: socket);
    } on TimeoutException {
      try {
        jumpClient?.close();
      } catch (_) {}
      throw StateError('经跳板机转发超时（${connectTimeout.inSeconds}s）');
    } on SocketException catch (e) {
      try {
        jumpClient?.close();
      } catch (_) {}
      throw StateError('无法连接跳板机 ${jumpHost.subtitle}：$e');
    } catch (e) {
      try {
        jumpClient?.close();
      } catch (_) {}
      if (e is StateError || e is ArgumentError || e is UnsupportedError) {
        rethrow;
      }
      throw StateError('跳板机转发失败：$e');
    }
  }
}

/// Result of [ProxyConnector.openTcpViaProxy]: live [socket] plus any bytes
/// that arrived immediately after the proxy reply (must not be discarded).
class OpenedTcpSocket {
  OpenedTcpSocket(this.socket, [List<int>? pendingBytes])
      : pendingBytes = pendingBytes == null || pendingBytes.isEmpty
            ? const <int>[]
            : List<int>.unmodifiable(pendingBytes);

  final Socket socket;
  final List<int> pendingBytes;
}

/// Buffered single-subscription reader for proxy handshakes on a [Socket].
class _SocketByteReader {
  _SocketByteReader(Socket socket) {
    _sub = socket.listen(
      (chunk) {
        if (_closed) return;
        _buffer.add(chunk);
        _pump();
      },
      onError: (Object e, StackTrace st) {
        _error = e;
        _stack = st;
        _pump();
      },
      onDone: () {
        _done = true;
        _pump();
      },
      cancelOnError: false,
    );
  }

  StreamSubscription<List<int>>? _sub;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Completer<void>? _wait;
  Object? _error;
  StackTrace? _stack;
  bool _done = false;
  bool _closed = false;

  Future<Uint8List> readExact(int n) async {
    while (!_closed) {
      if (_error != null) {
        Error.throwWithStackTrace(_error!, _stack ?? StackTrace.current);
      }
      final bytes = _buffer.toBytes();
      if (bytes.length >= n) {
        final out = Uint8List.fromList(bytes.sublist(0, n));
        _buffer.clear();
        if (bytes.length > n) {
          _buffer.add(bytes.sublist(n));
        }
        return out;
      }
      if (_done) {
        throw StateError(
          '代理连接已关闭（期望 $n 字节，收到 ${bytes.length}）',
        );
      }
      _wait = Completer<void>();
      await _wait!.future;
    }
    throw StateError('代理读取器已关闭');
  }

  Future<Uint8List> readUntilHeadersEnd() async {
    while (!_closed) {
      if (_error != null) {
        Error.throwWithStackTrace(_error!, _stack ?? StackTrace.current);
      }
      final bytes = _buffer.toBytes();
      for (var i = 0; i + 3 < bytes.length; i++) {
        if (bytes[i] == 0x0d &&
            bytes[i + 1] == 0x0a &&
            bytes[i + 2] == 0x0d &&
            bytes[i + 3] == 0x0a) {
          final end = i + 4;
          final out = Uint8List.fromList(bytes.sublist(0, end));
          _buffer.clear();
          if (bytes.length > end) {
            _buffer.add(bytes.sublist(end));
          }
          return out;
        }
      }
      if (bytes.length > 65536) {
        throw StateError('HTTP 代理响应头过长');
      }
      if (_done) {
        throw StateError('HTTP 代理连接在响应头结束前关闭');
      }
      _wait = Completer<void>();
      await _wait!.future;
    }
    throw StateError('代理读取器已关闭');
  }

  /// Bytes buffered beyond what handshake reads consumed.
  Uint8List takeLeftover() {
    final bytes = _buffer.toBytes();
    _buffer.clear();
    return Uint8List.fromList(bytes);
  }

  void _pump() {
    final w = _wait;
    if (w != null && !w.isCompleted) {
      w.complete();
    }
  }

  Future<void> cancel() async {
    _closed = true;
    _pump();
    await _sub?.cancel();
    _sub = null;
  }
}
