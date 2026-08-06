// Pure URL rewrite helpers for BrowserGateway (unit-testable, no SSH).

/// Query flag on gateway URLs marking HTTPS upstream (stripped before forward).
const String kGatewaySchemeQueryKey = '_et_scheme';

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

/// Rewrite HTML/CSS/JS body absolute URLs; optionally inject fetch/XHR shim.
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
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('/') && !trimmed.startsWith('//')) {
      return null;
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
    );
  }

  return out;
}

/// Inject a small script that rewrites absolute http(s) URLs used by fetch/XHR.
String injectGatewayFetchShim(
  String html, {
  required int gatewayPort,
  required String token,
}) {
  if (html.contains('data-et-gw-shim')) return html;

  final script = '''
<script data-et-gw-shim="1">
(function(){
  var TOKEN=${_jsString(token)};
  var GW_PORT=$gatewayPort;
  var SCHEME_KEY=${_jsString(kGatewaySchemeQueryKey)};
  function rewrite(u){
    try{
      if(!u || typeof u!=="string") return u;
      var a=document.createElement("a");
      a.href=u;
      var proto=a.protocol.toLowerCase();
      if(proto!=="http:" && proto!=="https:") return u;
      var h=a.hostname.toLowerCase();
      if((h==="127.0.0.1"||h==="localhost") && String(a.port)===String(GW_PORT)) return u;
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
