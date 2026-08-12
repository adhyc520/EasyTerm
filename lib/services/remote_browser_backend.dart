import 'browser_gateway.dart';
import 'browser_gateway_rewrite.dart';
import 'local_port_forwarder.dart';

/// Address-bar → navigable URI for the embedded remote browser.
abstract class RemoteBrowserBackend {
  /// Parse user address-bar input into a URL the webview can load.
  Future<Uri> resolveUrl(String input);

  Future<void> close();

  /// Short UI label: `网关` or `直连`.
  String get modeLabel;
}

/// Scheme B — browse via [BrowserGateway] URL rewriting.
class GatewayBrowserBackend implements RemoteBrowserBackend {
  GatewayBrowserBackend(this.gateway);

  final BrowserGateway gateway;

  @override
  String get modeLabel => '网关';

  @override
  Future<Uri> resolveUrl(String input) async {
    final t = parseBrowserAddressBar(input);
    // Public sites: load directly in WebView (local network), not via SSH.
    if (!isSshTunneledBrowserHost(t.host)) {
      return buildDirectBrowserNavigationUri(t);
    }
    if (!gateway.isRunning) {
      await gateway.start();
    }
    return gateway.buildUrl(
      remoteHost: t.host,
      remotePort: t.port,
      pathAndQuery: t.pathAndQuery,
      https: t.https,
    );
  }

  @override
  Future<void> close() async {
    // Gateway lifetime is owned by the workspace / desktop manager.
  }
}

/// Opens a registered [LocalPortForwarder] (workspace tracks for teardown).
typedef OpenLocalForwardFn = Future<LocalPortForwarder> Function(
  String remoteHost,
  int remotePort,
);

/// Stops and unregisters a forwarder previously opened via [OpenLocalForwardFn].
typedef ReleaseLocalForwardFn = Future<void> Function(LocalPortForwarder? fwd);

/// Scheme A — `ssh -L` style [LocalPortForwarder]; one host:port at a time.
///
/// Prefer constructing with [openForward]/[releaseForward] so forwards are
/// registered on [SshWorkspaceController] and cleaned up on disconnect.
class LocalForwardBrowserBackend implements RemoteBrowserBackend {
  LocalForwardBrowserBackend({
    required this.openForward,
    required this.releaseForward,
  });

  final OpenLocalForwardFn openForward;
  final ReleaseLocalForwardFn releaseForward;

  LocalPortForwarder? _fwd;
  String? _host;
  int? _port;

  @override
  String get modeLabel => '直连';

  @override
  Future<Uri> resolveUrl(String input) async {
    final t = parseBrowserAddressBar(input);
    if (!isSshTunneledBrowserHost(t.host)) {
      return buildDirectBrowserNavigationUri(t);
    }

    if (_fwd == null ||
        !_fwd!.isRunning ||
        _host != t.host ||
        _port != t.port) {
      await releaseForward(_fwd);
      _fwd = await openForward(t.host, t.port);
      _host = t.host;
      _port = t.port;
    }

    final localPort = _fwd!.localPort;
    if (localPort == null) {
      throw StateError('LocalPortForwarder has no local port');
    }

    final path = t.pathAndQuery.startsWith('/')
        ? t.pathAndQuery
        : '/${t.pathAndQuery}';
    final scheme = t.https ? 'https' : 'http';
    return Uri.parse('$scheme://127.0.0.1:$localPort$path');
  }

  @override
  Future<void> close() async {
    await releaseForward(_fwd);
    _fwd = null;
    _host = null;
    _port = null;
  }
}

/// Parsed address-bar target (remote host/port/path + https flag).
class BrowserAddressTarget {
  const BrowserAddressTarget({
    required this.host,
    required this.port,
    required this.pathAndQuery,
    required this.https,
  });

  final String host;
  final int port;
  final String pathAndQuery;
  final bool https;
}

/// Public / non-tunneled URL for the WebView (real host, not 127.0.0.1).
Uri buildDirectBrowserNavigationUri(BrowserAddressTarget t) {
  final omitPort =
      (!t.https && t.port == 80) || (t.https && t.port == 443);
  final raw = t.pathAndQuery.isEmpty ? '/' : t.pathAndQuery;
  final uri = raw.startsWith('http://') || raw.startsWith('https://')
      ? Uri.parse(raw)
      : Uri.parse(raw.startsWith('/') ? raw : '/$raw');
  return Uri(
    scheme: t.https ? 'https' : 'http',
    host: t.host,
    port: omitPort ? null : t.port,
    path: uri.path.isEmpty ? '/' : uri.path,
    queryParameters:
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
    fragment: uri.hasFragment ? uri.fragment : null,
  );
}

/// 供系统浏览器打开的公网 URL；内网/隧道主机返回 null（勿泄露网关 loopback+token）。
Uri? externalBrowserNavigationUri(String input) {
  final t = parseBrowserAddressBar(input);
  if (isSshTunneledBrowserHost(t.host)) return null;
  final uri = buildDirectBrowserNavigationUri(t);
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri;
}

/// Parse `"localhost:3000/path"`, `"http://host:port/x"`, `"host:port"`, etc.
///
/// Defaults: host `localhost`, port `80` (or `443` when scheme is https).
BrowserAddressTarget parseBrowserAddressBar(String input) {
  var s = input.trim();
  if (s.isEmpty) {
    return const BrowserAddressTarget(
      host: 'localhost',
      port: 80,
      pathAndQuery: '/',
      https: false,
    );
  }

  // Bare host:port[/path] without scheme — prepend http:// for Uri.parse.
  // Do not treat "localhost:3000" as scheme "localhost".
  if (!s.contains('://')) {
    s = 'http://$s';
  }

  final uri = Uri.parse(s);
  final https = uri.scheme.toLowerCase() == 'https';
  final host = uri.host.isEmpty ? 'localhost' : uri.host;
  // Uri.parse('http://host:3000') → port 3000; 'http://host' → default 80/443.
  final effectivePort = uri.hasPort ? uri.port : (https ? 443 : 80);

  var path = uri.path.isEmpty ? '/' : uri.path;
  if (uri.hasQuery) {
    path = '$path?${uri.query}';
  }

  return BrowserAddressTarget(
    host: host,
    port: effectivePort,
    pathAndQuery: path,
    https: https || effectivePort == 443,
  );
}

/// Direct public-URL browsing (no SSH tunnel). Used when the session has no
/// port-forward capability (Telnet / Serial).
class DirectOnlyBrowserBackend implements RemoteBrowserBackend {
  @override
  String get modeLabel => '直连';

  @override
  Future<Uri> resolveUrl(String input) async {
    final t = parseBrowserAddressBar(input);
    return buildDirectBrowserNavigationUri(t);
  }

  @override
  Future<void> close() async {}
}
