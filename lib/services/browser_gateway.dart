import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'browser_gateway_rewrite.dart';
import 'local_port_forwarder.dart';

export 'browser_gateway_rewrite.dart' show kGatewaySchemeQueryKey;

const int _kMaxRewriteBodyBytes = 8 * 1024 * 1024;
const Duration _kUpstreamIoTimeout = Duration(seconds: 60);

const _hopByHopExact = {
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
};

/// Process-local HTTP reverse proxy over SSH `forwardLocal`.
///
/// Webview navigates:
/// `http://127.0.0.1:{gatewayPort}/{token}/{remoteHost}/{remotePort}/{path}?…`
///
/// **Important (dartssh2):** [SSHClient.forwardLocal] is a **single** direct-tcpip
/// channel, not a local listener. Each proxied HTTP request opens one channel.
/// For HTTPS upstream we instead use [LocalPortForwarder] (real `ssh -L` style
/// ServerSocket) + [SecureSocket.secure] (SNI = remote host) so TLS wraps a
/// normal TCP socket to loopback.
class BrowserGateway {
  BrowserGateway(this.client);

  final SSHClient client;

  final String token = _generateToken();

  HttpServer? _server;
  final Map<String, LocalPortForwarder> _httpsForwarders = {};
  bool _stopping = false;

  bool get isRunning => _server != null && !_stopping;

  int? get port => _server?.port;

  /// Idempotent: binds loopback on a free port if not already running.
  Future<void> start() async {
    if (_server != null) return;
    _stopping = false;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(
      (req) {
        unawaited(_handleRequest(req));
      },
      onError: (_) {},
      cancelOnError: false,
    );
    // SSH 传输关闭时自动停网关（避免悬挂 loopback 监听）
    unawaited(
      client.done.then((_) {
        if (_stopping || _server == null) return;
        unawaited(stop());
      }),
    );
  }

  Future<void> stop() async {
    _stopping = true;
    final server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } catch (_) {}
    final fwd = List<LocalPortForwarder>.from(_httpsForwarders.values);
    _httpsForwarders.clear();
    for (final f in fwd) {
      try {
        await f.stop();
      } catch (_) {}
    }
    _stopping = false;
  }

  /// Build a gateway URL for navigating the webview.
  Uri buildUrl({
    required String remoteHost,
    required int remotePort,
    String pathAndQuery = '/',
    bool https = false,
  }) {
    return gatewayUriFor(
      remoteHost,
      remotePort,
      pathAndQuery,
      https: https,
    );
  }

  Uri gatewayUriFor(
    String remoteHost,
    int remotePort,
    String pathAndQuery, {
    bool https = false,
  }) {
    final p = port;
    if (p == null) {
      throw StateError('BrowserGateway is not running');
    }
    return buildGatewayNavigationUri(
      gatewayPort: p,
      token: token,
      remoteHost: remoteHost,
      remotePort: remotePort,
      pathAndQuery: pathAndQuery,
      https: https,
    );
  }

  /// Rewrites an absolute `http(s):` / protocol-relative URL into a gateway URL.
  /// Returns null when [url] should be left unchanged (relative, invalid, etc.).
  String? rewriteAbsoluteUrl(
    String url, {
    required String currentRemoteHost,
    required int currentRemotePort,
    bool currentHttps = false,
  }) {
    final p = port;
    if (p == null) return null;
    return rewriteRemoteAbsoluteUrl(
      url,
      gatewayPort: p,
      token: token,
    );
  }

  // ---------------------------------------------------------------------------
  // Request handling
  // ---------------------------------------------------------------------------

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (!isRunning) {
        await _plainError(request, HttpStatus.serviceUnavailable, 'Gateway stopped');
        return;
      }

      if (!_hostHeaderAllowed(request)) {
        await _plainError(request, HttpStatus.forbidden, 'Forbidden host');
        return;
      }

      final parsed = _parseGatewayPath(request.uri);
      if (parsed == null) {
        await _plainError(request, HttpStatus.badRequest, 'Bad gateway path');
        return;
      }
      if (parsed.token != token) {
        await _plainError(request, HttpStatus.forbidden, 'Invalid token');
        return;
      }

      final isUpgrade = _isWebSocketUpgrade(request);
      if (isUpgrade) {
        await _handleWebSocket(request, parsed);
        return;
      }

      await _handleHttp(request, parsed);
    } catch (e) {
      try {
        await _plainError(
          request,
          HttpStatus.badGateway,
          'Bad Gateway: $e',
        );
      } catch (_) {}
    }
  }

  bool _hostHeaderAllowed(HttpRequest request) {
    final p = port;
    if (p == null) return false;
    final host = request.headers.value(HttpHeaders.hostHeader);
    if (host == null) return false;
    final h = host.toLowerCase();
    return h == '127.0.0.1:$p' || h == 'localhost:$p';
  }

  Future<void> _handleHttp(HttpRequest request, _GatewayTarget target) async {
    _UpstreamConn? upstream;
    try {
      upstream = await _openUpstream(target);
    } catch (e) {
      await _plainError(
        request,
        HttpStatus.badGateway,
        'Upstream connect failed: $e',
      );
      return;
    }

    try {
      final reqBytes = await _buildForwardRequestBytes(request, target);
      upstream.sink.add(reqBytes);

      final reader = _ByteStreamReader(upstream.stream);
      final statusLine = await reader
          .readLine()
          .timeout(const Duration(seconds: 30));
      if (statusLine == null || statusLine.isEmpty) {
        throw StateError('Empty upstream response');
      }
      final status = _parseStatusLine(statusLine);
      final headers = await _readHeaders(reader);

      final contentType = _headerValue(headers, 'content-type') ?? '';
      final needsRewrite = _shouldRewriteBody(contentType);

      final response = request.response;
      response.statusCode = status.code;
      try {
        response.reasonPhrase = status.reason;
      } catch (_) {}

      void copyHeaders({
        required bool stripLengthAndEncoding,
        Uint8List? rewrittenBody,
      }) {
        for (final e in headers.entries) {
          final name = e.key;
          final lower = name.toLowerCase();
          if (_hopByHopExact.contains(lower) || lower.startsWith('proxy-')) {
            continue;
          }
          if (lower == 'content-encoding') continue;
          // Origin is 127.0.0.1 gateway — upstream CSP / COOP break SPA assets.
          if (lower == 'content-security-policy' ||
              lower == 'content-security-policy-report-only' ||
              lower == 'clear-site-data' ||
              lower == 'cross-origin-opener-policy' ||
              lower == 'cross-origin-embedder-policy' ||
              lower == 'cross-origin-resource-policy') {
            continue;
          }
          if (stripLengthAndEncoding &&
              (lower == 'content-length' || lower == 'transfer-encoding')) {
            continue;
          }

          if (lower == 'location' || lower == 'refresh') {
            for (final v in e.value) {
              response.headers.add(
                name,
                _rewriteLocationOrRefresh(v, lower == 'refresh', target),
              );
            }
            continue;
          }
          if (lower == 'set-cookie') {
            for (final v in e.value) {
              response.headers.add(name, _stripCookieDomain(v));
            }
            continue;
          }
          for (final v in e.value) {
            response.headers.add(name, v);
          }
        }
        if (rewrittenBody != null) {
          response.headers.set(
            HttpHeaders.contentLengthHeader,
            rewrittenBody.length,
          );
        }
      }

      if (needsRewrite) {
        final clRaw = _headerValue(headers, 'content-length');
        final cl = clRaw == null ? null : int.tryParse(clRaw.trim());
        // 超大 HTML/CSS：不整包改写，直接流式转发（相对 URL 仍可用）。
        if (cl != null && cl > _kMaxRewriteBodyBytes) {
          copyHeaders(stripLengthAndEncoding: true);
          response.headers.set(HttpHeaders.contentLengthHeader, cl);
          await _pipeExact(
            reader,
            response,
            cl,
            timeout: _kUpstreamIoTimeout,
          );
          await response.close();
        } else {
          var body = await _readHttpBody(
                reader,
                headers,
                maxBytes: _kMaxRewriteBodyBytes,
              ) ??
              Uint8List(0);
          final isHtml = contentType.toLowerCase().contains('text/html');
          if (body.length <= _kMaxRewriteBodyBytes) {
            final text = utf8.decode(body, allowMalformed: true);
            final rewritten = rewriteGatewayResponseBody(
              text,
              gatewayPort: port!,
              token: token,
              currentRemoteHost: target.host,
              currentRemotePort: target.port,
              currentHttps: target.https,
              isHtml: isHtml,
            );
            body = Uint8List.fromList(utf8.encode(rewritten));
          }
          copyHeaders(stripLengthAndEncoding: true, rewrittenBody: body);
          response.add(body);
          await response.close();
        }
      } else {
        // Stream body; dechunk if needed so we can drop Transfer-Encoding.
        final te = _headerValue(headers, 'transfer-encoding')?.toLowerCase();
        final clRaw = _headerValue(headers, 'content-length');
        final cl = clRaw == null ? null : int.tryParse(clRaw.trim());

        if (te != null && te.contains('chunked')) {
          final body = await reader
              .readChunkedBody()
              .timeout(_kUpstreamIoTimeout);
          copyHeaders(stripLengthAndEncoding: true, rewrittenBody: body);
          response.add(body);
          await response.close();
        } else if (cl != null && cl >= 0) {
          copyHeaders(stripLengthAndEncoding: true);
          response.headers.set(HttpHeaders.contentLengthHeader, cl);
          await _pipeExact(
            reader,
            response,
            cl,
            timeout: _kUpstreamIoTimeout,
          );
          await response.close();
        } else {
          copyHeaders(stripLengthAndEncoding: true);
          await _pipeUntilEnd(
            reader,
            response,
            timeout: _kUpstreamIoTimeout,
          );
          await response.close();
        }
      }
    } catch (e) {
      try {
        await _plainError(
          request,
          HttpStatus.badGateway,
          'Bad Gateway: $e',
        );
      } catch (_) {}
    } finally {
      upstream.close();
    }
  }

  Future<void> _handleWebSocket(
    HttpRequest request,
    _GatewayTarget target,
  ) async {
    // HTTPS WebSocket: TLS via LocalPortForwarder + SecureSocket, then upgrade.
    _UpstreamConn? upstream;
    try {
      upstream = await _openUpstream(target);
    } catch (e) {
      await _plainError(
        request,
        HttpStatus.badGateway,
        'Upstream connect failed: $e',
      );
      return;
    }

    try {
      final reqBytes = await _buildForwardRequestBytes(
        request,
        target,
        forWebSocket: true,
      );
      upstream.sink.add(reqBytes);

      final reader = _ByteStreamReader(upstream.stream);
      final statusLine = await reader
          .readLine()
          .timeout(const Duration(seconds: 30));
      if (statusLine == null) {
        throw StateError('Empty upstream WS response');
      }
      final status = _parseStatusLine(statusLine);
      final headers = await _readHeaders(reader);

      if (status.code != HttpStatus.switchingProtocols) {
        final body = await _readHttpBody(reader, headers) ?? Uint8List(0);
        final response = request.response;
        response.statusCode = status.code;
        headers.forEach((name, values) {
          final lower = name.toLowerCase();
          if (_hopByHopExact.contains(lower)) return;
          for (final v in values) {
            response.headers.add(name, v);
          }
        });
        response.add(body);
        await response.close();
        upstream.close();
        return;
      }

      final response = request.response;
      response.statusCode = HttpStatus.switchingProtocols;
      headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower == 'transfer-encoding' || lower == 'content-length') {
          return;
        }
        for (final v in values) {
          response.headers.set(name, v);
        }
      });

      // Remaining buffered bytes after header parse belong to WS frames.
      // Important: SSHForwardChannel.stream is single-subscription — keep using
      // [reader] for upstream→client instead of listening on stream again.
      final prelude = reader.takeBuffered();
      final clientSocket = await response.detachSocket();

      if (prelude.isNotEmpty) {
        clientSocket.add(prelude);
      }

      final up = upstream;
      late final StreamSubscription<List<int>> fromClient;
      var cleaned = false;

      void cleanup() {
        if (cleaned) return;
        cleaned = true;
        try {
          fromClient.cancel();
        } catch (_) {}
        unawaited(reader.cancel());
        try {
          clientSocket.destroy();
        } catch (_) {}
        up.close();
      }

      // Drain the rest of the upstream via the existing reader subscription.
      unawaited(() async {
        try {
          while (true) {
            final chunk = await reader.readSome();
            if (chunk == null) break;
            if (chunk.isEmpty) continue;
            clientSocket.add(chunk);
          }
        } catch (_) {
        } finally {
          cleanup();
        }
      }());

      fromClient = clientSocket.listen(
        (data) {
          try {
            up.sink.add(data);
          } catch (_) {
            cleanup();
          }
        },
        onDone: cleanup,
        onError: (_) => cleanup(),
        cancelOnError: true,
      );
    } catch (e) {
      try {
        upstream.close();
      } catch (_) {}
      try {
        await _plainError(
          request,
          HttpStatus.badGateway,
          'WebSocket proxy failed: $e',
        );
      } catch (_) {}
    }
  }

  Future<_UpstreamConn> _openUpstream(_GatewayTarget target) async {
    const connectTimeout = Duration(seconds: 15);
    if (target.https) {
      final fwd = await _cachedHttpsForwarder(target.host, target.port)
          .timeout(connectTimeout);
      final localPort = fwd.localPort;
      if (localPort == null) {
        throw StateError('HTTPS forwarder has no local port');
      }
      // Connect to loopback forwarder, then TLS with the *remote* hostname as
      // SNI. SecureSocket.connect('127.0.0.1', …) would send SNI=127.0.0.1 and
      // break virtually all public / multi-vhost HTTPS sites.
      final raw = await Socket.connect(
        '127.0.0.1',
        localPort,
        timeout: connectTimeout,
      );
      final sock = await SecureSocket.secure(
        raw,
        host: target.host,
        onBadCertificate: (_) => true,
      );
      return _UpstreamConn.socket(sock);
    }

    // Plain HTTP: one forwardLocal channel per request (not a listener).
    final ch = await client
        .forwardLocal(target.host, target.port)
        .timeout(connectTimeout);
    return _UpstreamConn.channel(ch);
  }

  Future<LocalPortForwarder> _cachedHttpsForwarder(
    String host,
    int port,
  ) async {
    final key = '$host:$port';
    final existing = _httpsForwarders[key];
    if (existing != null && existing.isRunning) return existing;
    final fwd = LocalPortForwarder(client, host, port);
    await fwd.start();
    _httpsForwarders[key] = fwd;
    return fwd;
  }

  Future<Uint8List> _buildForwardRequestBytes(
    HttpRequest request,
    _GatewayTarget target, {
    bool forWebSocket = false,
  }) async {
    final method = request.method;
    final forwardPath = target.forwardPathAndQuery;
    final buf = BytesBuilder(copy: false);

    void writeString(String s) => buf.add(utf8.encode(s));

    writeString('$method $forwardPath HTTP/1.1\r\n');
    writeString('Host: ${_upstreamHostHeader(target)}\r\n');

    request.headers.forEach((name, values) {
      final lower = name.toLowerCase();
      if (lower == 'host') return;
      if (lower == 'content-length') return;
      if (lower == 'accept-encoding') return;
      if (lower.startsWith('proxy-')) return;
      if (_hopByHopExact.contains(lower)) {
        // Keep Connection / Upgrade for WebSocket handshake.
        if (forWebSocket &&
            (lower == 'connection' || lower == 'upgrade')) {
          for (final v in values) {
            writeString('$name: $v\r\n');
          }
        }
        return;
      }
      for (final v in values) {
        writeString('$name: $v\r\n');
      }
    });

    if (!forWebSocket) {
      writeString('Accept-Encoding: identity\r\n');
      writeString('Connection: close\r\n');
    }

    final body = await request.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (b, chunk) {
        b.add(chunk);
        return b;
      },
    );
    final bodyBytes = body.takeBytes();
    if (bodyBytes.isNotEmpty ||
        (request.method != 'GET' &&
            request.method != 'HEAD' &&
            request.method != 'OPTIONS')) {
      writeString('Content-Length: ${bodyBytes.length}\r\n');
    }

    writeString('\r\n');
    if (bodyBytes.isNotEmpty) {
      buf.add(bodyBytes);
    }
    return buf.takeBytes();
  }

  String _rewriteLocationOrRefresh(
    String value,
    bool isRefresh,
    _GatewayTarget target,
  ) {
    if (!isRefresh) {
      return _rewriteHeaderUrl(value, target) ?? value;
    }
    // Refresh: 0;url=http://...
    final match = RegExp(
      r'^(.*?;\s*url=)(.+)$',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return value;
    final prefix = match.group(1)!;
    final url = match.group(2)!.trim();
    final rewritten = _rewriteHeaderUrl(url, target);
    return rewritten == null ? value : '$prefix$rewritten';
  }

  String? _rewriteHeaderUrl(String url, _GatewayTarget target) {
    final trimmed = url.trim();
    final p = port;
    if (p == null) return null;
    // Root-relative Location would otherwise escape /{token}/{host}/{port}/.
    if (trimmed.startsWith('/') && !trimmed.startsWith('//')) {
      return rewriteGatewayRootRelativeUrl(
        trimmed,
        gatewayPort: p,
        token: token,
        currentRemoteHost: target.host,
        currentRemotePort: target.port,
        currentHttps: target.https,
      );
    }
    if (trimmed.startsWith('//') ||
        trimmed.toLowerCase().startsWith('http://') ||
        trimmed.toLowerCase().startsWith('https://')) {
      return rewriteRemoteAbsoluteUrl(
        trimmed,
        gatewayPort: p,
        token: token,
      );
    }
    try {
      final base = Uri(
        scheme: target.https ? 'https' : 'http',
        host: target.host,
        port: target.port,
        path: '/',
      );
      final resolved = base.resolve(trimmed);
      if (resolved.hasScheme &&
          (resolved.scheme == 'http' || resolved.scheme == 'https')) {
        return rewriteRemoteAbsoluteUrl(
          resolved.toString(),
          gatewayPort: p,
          token: token,
        );
      }
    } catch (_) {}
    return null;
  }

  static String _stripCookieDomain(String cookie) {
    return cookie
        .split(';')
        .where((part) {
          final t = part.trim().toLowerCase();
          return !t.startsWith('domain=');
        })
        .join(';');
  }

  static bool _shouldRewriteBody(String contentType) {
    final ct = contentType.toLowerCase();
    return ct.contains('text/html') ||
        ct.contains('text/css') ||
        ct.contains('application/javascript') ||
        ct.contains('text/javascript');
  }

  static bool _isWebSocketUpgrade(HttpRequest request) {
    final upgrade = request.headers.value('upgrade')?.toLowerCase();
    if (upgrade != 'websocket') return false;
    final connection = request.headers['connection'];
    if (connection == null) return false;
    return connection.any((v) => v.toLowerCase().contains('upgrade'));
  }

  static Future<void> _plainError(
    HttpRequest request,
    int code,
    String message,
  ) async {
    final response = request.response;
    try {
      final accept = request.headers.value(HttpHeaders.acceptHeader) ?? '';
      final wantsHtml = accept.contains('text/html') ||
          request.uri.path.toLowerCase().endsWith('.html') ||
          !accept.contains('application/json');

      response.statusCode = code;
      if (wantsHtml) {
        response.headers.contentType = ContentType.html;
        final escaped = const HtmlEscape().convert(message);
        response.write('''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>$code · EasyTerm Gateway</title>
<style>
  body{margin:0;font:14px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;
       background:#0f1419;color:#e6edf3;display:flex;min-height:100vh;align-items:center;justify-content:center}
  .card{max-width:480px;padding:28px 32px;border:1px solid #30363d;border-radius:12px;background:#161b22}
  h1{margin:0 0 8px;font-size:18px;font-weight:600}
  .code{color:#f85149;font-family:ui-monospace,Menlo,monospace;font-size:12px;margin-bottom:12px}
  p{margin:0 0 10px;color:#8b949e}
  .tip{margin-top:16px;padding:10px 12px;border-radius:8px;background:#21262d;color:#c9d1d9;font-size:12px}
  code{font-family:ui-monospace,Menlo,monospace;color:#79c0ff}
</style>
</head>
<body>
  <div class="card">
    <div class="code">HTTP $code</div>
    <h1>网关无法打开该页面</h1>
    <p>$escaped</p>
    <div class="tip">
      网关已改写 HTML/CSS 链接，并尽量拦截 <code>fetch</code>/<code>XHR</code> 中的绝对 URL。
      若仍失败，可在工具栏切换到<strong>直连</strong>模式（仅转发当前 <code>host:port</code>）。
    </div>
  </div>
</body>
</html>
''');
      } else {
        response.headers.contentType = ContentType.text;
        response.write(message);
      }
      await response.close();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  static String _generateToken() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

// ---------------------------------------------------------------------------
// Path / target parsing
// ---------------------------------------------------------------------------

class _GatewayTarget {
  _GatewayTarget({
    required this.token,
    required this.host,
    required this.port,
    required this.forwardPathAndQuery,
    required this.https,
  });

  final String token;
  final String host;
  final int port;
  final String forwardPathAndQuery;
  final bool https;
}

_GatewayTarget? _parseGatewayPath(Uri uri) {
  // Expected: /{token}/{remoteHost}/{remotePort}/{rest...}
  final segments = uri.pathSegments;
  if (segments.length < 3) return null;

  final token = segments[0];
  final host = Uri.decodeComponent(segments[1]);
  final port = int.tryParse(Uri.decodeComponent(segments[2]));
  if (port == null || port <= 0 || port > 65535) return null;

  final restSegments = segments.length > 3 ? segments.sublist(3) : <String>[];
  final path = restSegments.isEmpty
      ? '/'
      : '/${restSegments.map(Uri.decodeComponent).join('/')}';

  final q = Map<String, String>.from(uri.queryParameters);
  final schemeFlag = q.remove(kGatewaySchemeQueryKey);
  final https = schemeFlag?.toLowerCase() == 'https' || port == 443;

  final forward = Uri(
    path: path,
    queryParameters: q.isEmpty ? null : q,
  );
  // Uri(path/query) may omit leading path quirks — normalize.
  var forwardPath = forward.path.isEmpty ? '/' : forward.path;
  if (!forwardPath.startsWith('/')) forwardPath = '/$forwardPath';
  if (forward.hasQuery) {
    forwardPath = '$forwardPath?${forward.query}';
  }

  return _GatewayTarget(
    token: token,
    host: host,
    port: port,
    forwardPathAndQuery: forwardPath,
    https: https,
  );
}

String _upstreamHostHeader(_GatewayTarget target) {
  final omitPort = (!target.https && target.port == 80) ||
      (target.https && target.port == 443);
  return omitPort ? target.host : '${target.host}:${target.port}';
}

// ---------------------------------------------------------------------------
// Upstream connection + HTTP parse helpers
// ---------------------------------------------------------------------------

class _UpstreamConn {
  _UpstreamConn._({
    required this.stream,
    required this.sink,
    required this.close,
  });

  factory _UpstreamConn.channel(SSHForwardChannel ch) {
    return _UpstreamConn._(
      stream: ch.stream,
      sink: ch.sink,
      close: () {
        try {
          ch.destroy();
        } catch (_) {}
      },
    );
  }

  factory _UpstreamConn.socket(Socket sock) {
    return _UpstreamConn._(
      stream: sock,
      sink: sock,
      close: () {
        try {
          sock.destroy();
        } catch (_) {}
      },
    );
  }

  final Stream<List<int>> stream;
  final StreamSink<List<int>> sink;
  final void Function() close;
}

class _StatusLine {
  _StatusLine(this.code, this.reason);
  final int code;
  final String reason;
}

_StatusLine _parseStatusLine(String line) {
  // HTTP/1.x 200 OK
  final parts = line.split(' ');
  if (parts.length < 2) {
    throw FormatException('Bad status line: $line');
  }
  final code = int.tryParse(parts[1]);
  if (code == null) {
    throw FormatException('Bad status code: $line');
  }
  final reason = parts.length > 2 ? parts.sublist(2).join(' ') : '';
  return _StatusLine(code, reason);
}

Future<Map<String, List<String>>> _readHeaders(_ByteStreamReader reader) async {
  final headers = <String, List<String>>{};
  while (true) {
    final line = await reader.readLine();
    if (line == null || line.isEmpty) break;
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    final name = line.substring(0, idx).trim();
    final value = line.substring(idx + 1).trim();
    headers.putIfAbsent(name, () => []).add(value);
  }
  return headers;
}

String? _headerValue(Map<String, List<String>> headers, String name) {
  final lower = name.toLowerCase();
  for (final e in headers.entries) {
    if (e.key.toLowerCase() == lower && e.value.isNotEmpty) {
      return e.value.first;
    }
  }
  return null;
}

Future<Uint8List?> _readHttpBody(
  _ByteStreamReader reader,
  Map<String, List<String>> headers, {
  int? maxBytes,
}) async {
  final te = _headerValue(headers, 'transfer-encoding')?.toLowerCase();
  if (te != null && te.contains('chunked')) {
    final body = await reader.readChunkedBody();
    if (maxBytes != null && body.length > maxBytes) {
      // 已读完；调用方决定是否改写。超大则原样返回。
      return body;
    }
    return body;
  }
  final cl = _headerValue(headers, 'content-length');
  if (cl != null) {
    final n = int.tryParse(cl.trim());
    if (n == null || n < 0) return Uint8List(0);
    if (n == 0) return Uint8List(0);
    return reader.readExact(n);
  }
  // Connection: close — read until EOF (optionally cap).
  if (maxBytes != null) {
    return reader.readUntilEndCapped(maxBytes);
  }
  return reader.readUntilEnd();
}

Future<void> _pipeExact(
  _ByteStreamReader reader,
  HttpResponse response,
  int length, {
  required Duration timeout,
}) async {
  var remaining = length;
  while (remaining > 0) {
    final chunk = await reader.readSome().timeout(timeout);
    if (chunk == null) break;
    if (chunk.isEmpty) continue;
    final take =
        chunk.length <= remaining ? chunk : chunk.sublist(0, remaining);
    response.add(take);
    remaining -= take.length;
  }
}

Future<void> _pipeUntilEnd(
  _ByteStreamReader reader,
  HttpResponse response, {
  required Duration timeout,
}) async {
  while (true) {
    final chunk = await reader.readSome().timeout(timeout);
    if (chunk == null) break;
    if (chunk.isNotEmpty) response.add(chunk);
  }
}

/// Buffered line/byte reader over an upstream byte stream.
class _ByteStreamReader {
  _ByteStreamReader(Stream<List<int>> stream) {
    _sub = stream.listen(
      (chunk) {
        if (chunk.isEmpty) return;
        _buffer.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
        _pump();
      },
      onDone: () {
        _done = true;
        _pump();
      },
      onError: (e, st) {
        _error = e;
        _done = true;
        _pump();
      },
      cancelOnError: false,
    );
  }

  late final StreamSubscription<List<int>> _sub;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  final List<Completer<void>> _waiters = [];
  bool _done = false;
  Object? _error;

  void _pump() {
    while (_waiters.isNotEmpty) {
      final c = _waiters.removeAt(0);
      if (!c.isCompleted) c.complete();
    }
  }

  Future<void> _wait() {
    if (_buffer.length > 0 || _done) return Future.value();
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void _throwIfError() {
    if (_error != null) throw _error!;
  }

  Future<String?> readLine() async {
    while (true) {
      _throwIfError();
      final data = _buffer.toBytes();
      final idx = _indexOfCrlf(data);
      if (idx >= 0) {
        final lineBytes = data.sublist(0, idx);
        final rest = data.sublist(idx + 2);
        _buffer.clear();
        if (rest.isNotEmpty) _buffer.add(rest);
        return utf8.decode(lineBytes, allowMalformed: true);
      }
      if (_done) {
        if (data.isEmpty) return null;
        _buffer.clear();
        return utf8.decode(data, allowMalformed: true);
      }
      await _wait();
    }
  }

  Future<Uint8List> readExact(int n) async {
    while (_buffer.length < n && !_done) {
      _throwIfError();
      await _wait();
    }
    _throwIfError();
    final data = _buffer.toBytes();
    if (data.length < n) {
      _buffer.clear();
      return Uint8List.fromList(data);
    }
    final out = Uint8List.fromList(data.sublist(0, n));
    final rest = data.sublist(n);
    _buffer.clear();
    if (rest.isNotEmpty) _buffer.add(rest);
    return out;
  }

  Future<Uint8List> readUntilEnd() async {
    while (!_done) {
      _throwIfError();
      await _wait();
    }
    _throwIfError();
    final out = _buffer.toBytes();
    _buffer.clear();
    return Uint8List.fromList(out);
  }

  /// Read until EOF but stop accumulating past [maxBytes] (remainder discarded).
  Future<Uint8List> readUntilEndCapped(int maxBytes) async {
    final out = BytesBuilder(copy: false);
    while (!_done) {
      _throwIfError();
      if (_buffer.length > 0) {
        final data = _buffer.toBytes();
        _buffer.clear();
        final room = maxBytes - out.length;
        if (room <= 0) {
          // Keep draining so upstream doesn't stall forever.
        } else if (data.length <= room) {
          out.add(data);
        } else {
          out.add(data.sublist(0, room));
        }
      }
      if (_done) break;
      await _wait();
    }
    _throwIfError();
    if (_buffer.length > 0) {
      final data = _buffer.toBytes();
      _buffer.clear();
      final room = maxBytes - out.length;
      if (room > 0) {
        out.add(data.length <= room ? data : data.sublist(0, room));
      }
    }
    return out.takeBytes();
  }

  /// Returns the next available chunk, or null when the stream is done.
  Future<Uint8List?> readSome() async {
    while (_buffer.length == 0 && !_done) {
      _throwIfError();
      await _wait();
    }
    _throwIfError();
    if (_buffer.length == 0 && _done) return null;
    final out = _buffer.toBytes();
    _buffer.clear();
    return Uint8List.fromList(out);
  }

  Future<Uint8List> readChunkedBody() async {
    final out = BytesBuilder(copy: false);
    while (true) {
      final sizeLine = await readLine();
      if (sizeLine == null) break;
      final hex = sizeLine.split(';').first.trim();
      final size = int.tryParse(hex, radix: 16);
      if (size == null) {
        throw FormatException('Bad chunk size: $sizeLine');
      }
      if (size == 0) {
        // Trailer headers until blank line.
        while (true) {
          final t = await readLine();
          if (t == null || t.isEmpty) break;
        }
        break;
      }
      final chunk = await readExact(size);
      out.add(chunk);
      await readExact(2); // CRLF after chunk
    }
    return out.takeBytes();
  }

  Uint8List takeBuffered() {
    final out = _buffer.toBytes();
    _buffer.clear();
    return Uint8List.fromList(out);
  }

  Future<void> cancel() => _sub.cancel();

  static int _indexOfCrlf(List<int> data) {
    for (var i = 0; i + 1 < data.length; i++) {
      if (data[i] == 0x0d && data[i + 1] == 0x0a) return i;
    }
    return -1;
  }
}
