/// 跳板 / 代理类型。
enum ProxyType {
  sshJump,
  sshTunnel,
  socks5,
  http,
}

/// 跳板机或代理配置（目前主要用于 SSH ProxyJump）。
class ProxyConfig {
  ProxyConfig({
    required this.type,
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKeyPem,
  });

  final ProxyType type;
  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKeyPem;

  String get subtitle => '$username@$host:$port';

  Map<String, Object?> toJson() => {
    'type': type.name,
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'privateKeyPem': privateKeyPem,
  };

  factory ProxyConfig.fromJson(Map<String, Object?> j) {
    final typeName = (j['type'] as String?) ?? ProxyType.sshJump.name;
    final type = ProxyType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => ProxyType.sshJump,
    );
    return ProxyConfig(
      type: type,
      host: (j['host'] as String?)?.trim() ?? '',
      port: (j['port'] as num?)?.toInt() ?? 22,
      username: (j['username'] as String?)?.trim() ?? '',
      password: j['password'] as String?,
      privateKeyPem: j['privateKeyPem'] as String?,
    );
  }

  ProxyConfig copyWith({
    ProxyType? type,
    String? host,
    int? port,
    String? username,
    String? password,
    String? privateKeyPem,
  }) {
    return ProxyConfig(
      type: type ?? this.type,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      privateKeyPem: privateKeyPem ?? this.privateKeyPem,
    );
  }
}
