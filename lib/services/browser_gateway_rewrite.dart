// Pure URL rewrite helpers for BrowserGateway (unit-testable, no SSH).

/// Query flag on gateway URLs marking HTTPS upstream (stripped before forward).
const String kGatewaySchemeQueryKey = '_et_scheme';

const _kInternalDnsSuffixes = [
  '.local',
  '.internal',
  '.lan',
  '.home',
  '.corp',
  '.intranet',
  '.private',
  '.test',
  '.localhost',
];

/// Whether [host] should be reached via SSH (gateway / local forward).
///
/// Public Internet hostnames are loaded **directly** by the WebView — modern
/// sites break under HTML rewriting and HTTP/1.1 SSH proxying.
bool isSshTunneledBrowserHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return true;
  if (h == 'localhost' ||
      h == '127.0.0.1' ||
      h == '::1' ||
      h == '[::1]' ||
      h == '0.0.0.0') {
    return true;
  }

  final v4 = _parseIpv4(h);
  if (v4 != null) return _isPrivateOrLocalIpv4(v4);

  final v6 = _parseIpv6Literal(h);
  if (v6 != null) return _isPrivateOrLocalIpv6(v6);

  for (final suffix in _kInternalDnsSuffixes) {
    if (h == suffix.substring(1) || h.endsWith(suffix)) return true;
  }

  // Single-label names (docker/k8s service DNS) stay on the tunnel.
  if (!h.contains('.')) return true;

  return false;
}

List<int>? _parseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}

bool _isPrivateOrLocalIpv4(List<int> b) {
  if (b[0] == 10) return true;
  if (b[0] == 127) return true;
  if (b[0] == 192 && b[1] == 168) return true;
  if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
  if (b[0] == 169 && b[1] == 254) return true;
  if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true; // CGNAT
  return false;
}

/// Strip brackets from `[::1]`-style literals; return lowercased hex groups or null.
String? _parseIpv6Literal(String host) {
  var h = host;
  if (h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  if (!h.contains(':')) return null;
  // Enough to classify; full RFC 5952 parse not required.
  return h.toLowerCase();
}

bool _isPrivateOrLocalIpv6(String h) {
  if (h == '::1') return true;
  // Unique local fc00::/7
  if (h.startsWith('fc') || h.startsWith('fd')) return true;
  // Link-local fe80::/10
  if (h.startsWith('fe8') ||
      h.startsWith('fe9') ||
      h.startsWith('fea') ||
      h.startsWith('feb')) {
    return true;
  }
  return false;
}

/// Build a loopback gateway navigation URI.
Uri buildGatewayNavigationUri({
  required int gatewayPort,
  required String token,
  required String remoteHost,
  required int remotePort,
  String pathAndQuery = '/',
  bool https = false,
}) {
  final parsed = _splitPathAndQuery(pathAndQuery);
  final segments = <String>[
    token,
    Uri.encodeComponent(remoteHost),
    '$remotePort',
    ..._pathToSegments(parsed.path),
  ];
  final q = Map<String, String>.from(parsed.query);
  if (https) {
    q[kGatewaySchemeQueryKey] = 'https';
  } else {
    q.remove(kGatewaySchemeQueryKey);
  }
  return Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: gatewayPort,
    pathSegments: segments,
    queryParameters: q.isEmpty ? null : q,
  );
}

/// Rewrites absolute `http(s):` / protocol-relative URLs into gateway URLs.
String? rewriteRemoteAbsoluteUrl(
  String url, {
  required int gatewayPort,
  required String token,
}) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;

  Uri? uri;
  try {
    if (trimmed.startsWith('//')) {
      uri = Uri.parse('http:$trimmed');
    } else {
      uri = Uri.parse(trimmed);
    }
  } catch (_) {
    return null;
  }

  if (!uri.hasScheme) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.host.isEmpty) return null;

  // Already on the local gateway — leave alone.
  final hostLower = uri.host.toLowerCase();
  if ((hostLower == '127.0.0.1' || hostLower == 'localhost') &&
      uri.hasPort &&
      uri.port == gatewayPort) {
    return null;
  }

  // Public Internet hosts: keep absolute URL so WebView fetches them locally
  // (CDN / fonts / analytics). Tunneling them via SSH breaks most modern sites.
  if (!isSshTunneledBrowserHost(uri.host)) {
    return null;
  }

  final https = scheme == 'https';
  final remotePort = uri.hasPort ? uri.port : (https ? 443 : 80);
  final pathAndQuery = uri.hasQuery
      ? '${uri.path.isEmpty ? '/' : uri.path}?${uri.query}'
      : (uri.path.isEmpty ? '/' : uri.path);

  try {
    final gw = buildGatewayNavigationUri(
      gatewayPort: gatewayPort,
      token: token,
      remoteHost: uri.host,
      remotePort: remotePort,
      pathAndQuery: pathAndQuery,
      https: https,
    );
    if (uri.hasFragment) {
      return gw.replace(fragment: uri.fragment).toString();
    }
    return gw.toString();
  } catch (_) {
    return null;
  }
}

/// Rewrite a root-relative path (`/assets/x.js`) onto the gateway prefix.
///
/// Without this, browsers resolve `/…` against `http://127.0.0.1:{port}/…`
/// and drop `/{token}/{host}/{remotePort}/`, so SPA CSS/JS 404 → white screen
/// while `<title>` from the HTML document still appears.
String? rewriteGatewayRootRelativeUrl(
  String pathAndQuery, {
  required int gatewayPort,
  required String token,
  required String currentRemoteHost,
  required int currentRemotePort,
  required bool currentHttps,
}) {
  final trimmed = pathAndQuery.trim();
  if (trimmed.isEmpty) return null;
  if (!trimmed.startsWith('/') || trimmed.startsWith('//')) return null;
  try {
    return buildGatewayNavigationUri(
      gatewayPort: gatewayPort,
      token: token,
      remoteHost: currentRemoteHost,
      remotePort: currentRemotePort,
      pathAndQuery: trimmed,
      https: currentHttps,
    ).toString();
  } catch (_) {
    return null;
  }
}

bool _isSkippableBrowserUrl(String trimmed) {
  if (trimmed.isEmpty || trimmed.startsWith('#')) return true;
  final lower = trimmed.toLowerCase();
  return lower.startsWith('data:') ||
      lower.startsWith('javascript:') ||
      lower.startsWith('mailto:') ||
      lower.startsWith('blob:') ||
      lower.startsWith('about:');
}

/// Rewrite HTML/CSS body absolute URLs; optionally inject fetch/XHR shim.
///
/// JavaScript responses are intentionally not rewritten here — SPA bundles are
/// huge and almost never contain `href`/`url()` attributes; the HTML shim covers
/// `fetch`/XHR instead. Running regex rewrite on JS would freeze the UI isolate.
String rewriteGatewayResponseBody(
  String body, {
  required int gatewayPort,
  required String token,
  required String currentRemoteHost,
  required int currentRemotePort,
  required bool currentHttps,
  required bool isHtml,
}) {
  String? rewrite(String url) {
    final trimmed = url.trim();
    if (_isSkippableBrowserUrl(trimmed)) return null;

    // Root-relative: must stay under /{token}/{host}/{port}/…
    if (trimmed.startsWith('/') && !trimmed.startsWith('//')) {
      return rewriteGatewayRootRelativeUrl(
        trimmed,
        gatewayPort: gatewayPort,
        token: token,
        currentRemoteHost: currentRemoteHost,
        currentRemotePort: currentRemotePort,
        currentHttps: currentHttps,
      );
    }
    if (trimmed.startsWith('//') ||
        trimmed.toLowerCase().startsWith('http://') ||
        trimmed.toLowerCase().startsWith('https://')) {
      return rewriteRemoteAbsoluteUrl(
        trimmed,
        gatewayPort: gatewayPort,
        token: token,
      );
    }
    try {
      final base = Uri(
        scheme: currentHttps ? 'https' : 'http',
        host: currentRemoteHost,
        port: currentRemotePort,
        path: '/',
      );
      final resolved = base.resolve(trimmed);
      if (resolved.hasScheme &&
          (resolved.scheme == 'http' || resolved.scheme == 'https')) {
        return rewriteRemoteAbsoluteUrl(
          resolved.toString(),
          gatewayPort: gatewayPort,
          token: token,
        );
      }
    } catch (_) {}
    return null;
  }

  var out = body.replaceAllMapped(
    RegExp(
      r'''\b(href|src|action)\s*=\s*(["'])(.*?)\2''',
      caseSensitive: false,
      dotAll: false,
    ),
    (m) {
      final attr = m.group(1)!;
      final quote = m.group(2)!;
      final url = m.group(3)!;
      final rewritten = rewrite(url);
      if (rewritten == null) return m.group(0)!;
      return '$attr=$quote$rewritten$quote';
    },
  );

  out = out.replaceAllMapped(
    RegExp(
      r'''url\(\s*(["']?)([^"'()\s]+)\1\s*\)''',
      caseSensitive: false,
    ),
    (m) {
      final quote = m.group(1) ?? '';
      final url = m.group(2)!;
      final rewritten = rewrite(url);
      if (rewritten == null) return m.group(0)!;
      return 'url($quote$rewritten$quote)';
    },
  );

  if (isHtml) {
    out = injectGatewayFetchShim(
      out,
      gatewayPort: gatewayPort,
      token: token,
      currentRemoteHost: currentRemoteHost,
      currentRemotePort: currentRemotePort,
      currentHttps: currentHttps,
    );
  }

  return out;
}

/// Inject a small script that rewrites absolute http(s) URLs used by fetch/XHR.
String injectGatewayFetchShim(
  String html, {
  required int gatewayPort,
  required String token,
  required String currentRemoteHost,
  required int currentRemotePort,
  required bool currentHttps,
}) {
  if (html.contains('data-et-gw-shim')) return html;

  final script = '''
<script data-et-gw-shim="1">
(function(){
  var TOKEN=${_jsString(token)};
  var GW_PORT=$gatewayPort;
  var REMOTE_HOST=${_jsString(currentRemoteHost)};
  var REMOTE_PORT=$currentRemotePort;
  var REMOTE_HTTPS=${currentHttps ? 'true' : 'false'};
  var SCHEME_KEY=${_jsString(kGatewaySchemeQueryKey)};
  var INTERNAL_SUFFIX=[".local",".internal",".lan",".home",".corp",".intranet",".private",".test",".localhost"];
  function isTunneledHost(h){
    h=(h||"").toLowerCase();
    if(!h) return true;
    if(h==="localhost"||h==="127.0.0.1"||h==="::1"||h==="0.0.0.0") return true;
    var m=/^(\\d+)\\.(\\d+)\\.(\\d+)\\.(\\d+)\$/.exec(h);
    if(m){
      var a=+m[1],b=+m[2];
      if(a===10||a===127) return true;
      if(a===192&&b===168) return true;
      if(a===172&&b>=16&&b<=31) return true;
      if(a===169&&b===254) return true;
      if(a===100&&b>=64&&b<=127) return true;
      return false;
    }
    if(h.indexOf(":")>=0){
      if(h==="::1") return true;
      if(h.indexOf("fc")===0||h.indexOf("fd")===0) return true;
      if(/^fe[89ab]/.test(h)) return true;
      return false;
    }
    for(var i=0;i<INTERNAL_SUFFIX.length;i++){
      var s=INTERNAL_SUFFIX[i];
      if(h===s.slice(1)||h.length>s.length&&h.slice(-s.length)===s) return true;
    }
    if(h.indexOf(".")<0) return true;
    return false;
  }
  function gwUrl(path, search, hash, https){
    var q=search||"";
    if(https){
      q=q?(q+"&"+SCHEME_KEY+"=https"):("?"+SCHEME_KEY+"=https");
    }
    return "http://127.0.0.1:"+GW_PORT+"/"+TOKEN+"/"+encodeURIComponent(REMOTE_HOST)+"/"+REMOTE_PORT+(path||"/")+q+(hash||"");
  }
  function rewrite(u){
    try{
      if(!u || typeof u!=="string") return u;
      // Root-relative API/static paths must keep the gateway prefix.
      if(u.charAt(0)==="/" && u.charAt(1)!=="/"){
        var qi=u.indexOf("?");
        var hi=u.indexOf("#");
        var path=u, search="", hash="";
        if(qi>=0 && (hi<0||qi<hi)){
          path=u.slice(0,qi);
          if(hi>=0){ search=u.slice(qi,hi); hash=u.slice(hi); }
          else { search=u.slice(qi); }
        } else if(hi>=0){
          path=u.slice(0,hi); hash=u.slice(hi);
        }
        return gwUrl(path||"/", search, hash, REMOTE_HTTPS);
      }
      var a=document.createElement("a");
      a.href=u;
      var proto=a.protocol.toLowerCase();
      if(proto!=="http:" && proto!=="https:") return u;
      var h=a.hostname.toLowerCase();
      if((h==="127.0.0.1"||h==="localhost") && String(a.port)===String(GW_PORT)) return u;
      if(!isTunneledHost(h)) return u;
      var https=proto==="https:";
      var port=a.port?a.port:(https?"443":"80");
      var path=a.pathname||"/";
      var search=a.search||"";
      if(https){
        search=search?(search+"&"+SCHEME_KEY+"=https"):("?"+SCHEME_KEY+"=https");
      }
      return "http://127.0.0.1:"+GW_PORT+"/"+TOKEN+"/"+encodeURIComponent(a.hostname)+"/"+port+path+search+(a.hash||"");
    }catch(e){ return u; }
  }
  try{
    var _fetch=window.fetch;
    if(typeof _fetch==="function"){
      window.fetch=function(input, init){
        if(typeof input==="string"){ input=rewrite(input); }
        else if(input && typeof input.url==="string"){
          try{ input=new Request(rewrite(input.url), input); }catch(_){}
        }
        return _fetch.call(this, input, init);
      };
    }
  }catch(_){}
  try{
    var XO=XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open=function(){
      if(arguments.length>1 && typeof arguments[1]==="string"){
        arguments[1]=rewrite(arguments[1]);
      }
      return XO.apply(this, arguments);
    };
  }catch(_){}
})();
</script>
''';

  final lower = html.toLowerCase();
  final headIdx = lower.indexOf('<head');
  if (headIdx >= 0) {
    final gt = html.indexOf('>', headIdx);
    if (gt >= 0) {
      return html.substring(0, gt + 1) + script + html.substring(gt + 1);
    }
  }
  final htmlIdx = lower.indexOf('<html');
  if (htmlIdx >= 0) {
    final gt = html.indexOf('>', htmlIdx);
    if (gt >= 0) {
      return html.substring(0, gt + 1) + script + html.substring(gt + 1);
    }
  }
  return script + html;
}

String _jsString(String s) => jsonEncodeForJs(s);

/// Minimal JSON string encode for embedding in JS.
String jsonEncodeForJs(String s) {
  final b = StringBuffer('"');
  for (final r in s.runes) {
    switch (r) {
      case 0x22: // "
        b.write(r'\"');
      case 0x5C: // \
        b.write(r'\\');
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      default:
        if (r < 0x20) {
          b.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
        } else {
          b.writeCharCode(r);
        }
    }
  }
  b.write('"');
  return b.toString();
}

({String path, Map<String, String> query}) _splitPathAndQuery(String pathAndQuery) {
  final raw = pathAndQuery.isEmpty ? '/' : pathAndQuery;
  final uri = raw.startsWith('http://') || raw.startsWith('https://')
      ? Uri.parse(raw)
      : Uri.parse(raw.startsWith('/') ? raw : '/$raw');
  return (
    path: uri.path.isEmpty ? '/' : uri.path,
    query: Map<String, String>.from(uri.queryParameters),
  );
}

List<String> _pathToSegments(String path) {
  if (path.isEmpty || path == '/') return const [];
  final trimmed = path.startsWith('/') ? path.substring(1) : path;
  return trimmed.split('/');
}
