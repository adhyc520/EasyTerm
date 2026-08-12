/// 跳板 / 代理类型。
enum ProxyType {
  sshJump,
  sshTunnel,
  socks5,
  http,
}

/// 跳板机或代理配置（目前主要用于 SSH ProxyJump）。
///
/// [privateKeyPem] 仅作运行时内存字段，[toJson] 不会写入磁盘；持久化请用 [keyPath]。
class ProxyConfig {
  ProxyConfig({
    required this.type,
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.keyPath,
    this.privateKeyPem,
  });

  final ProxyType type;
  final String host;
  final int port;
  final String username;
  final String? password;

  /// 跳板私钥路径（持久化）；连接时再读入 [privateKeyPem]。
  final String? keyPath;

  /// 运行时已加载的 PEM；不落盘。
  final String? privateKeyPem;

  String get subtitle => '$username@$host:$port';

  Map<String, Object?> toJson() => {
        'type': type.name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'keyPath': keyPath,
        // 故意不序列化 privateKeyPem，避免整钥写入主机配置文件。
      };

  factory ProxyConfig.fromJson(Map<String, Object?> j) {
    final typeName = (j['type'] as String?) ?? ProxyType.sshJump.name;
    final type = ProxyType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => ProxyType.sshJump,
    );
    // 旧版可能把 PEM 写进 JSON；加载时忽略，强制走 keyPath。
    return ProxyConfig(
      type: type,
      host: (j['host'] as String?)?.trim() ?? '',
      port: (j['port'] as num?)?.toInt() ?? 22,
      username: (j['username'] as String?)?.trim() ?? '',
      password: j['password'] as String?,
      keyPath: (j['keyPath'] as String?)?.trim(),
      privateKeyPem: null,
    );
  }

  ProxyConfig copyWith({
    ProxyType? type,
    String? host,
    int? port,
    String? username,
    String? password,
    String? keyPath,
    String? privateKeyPem,
    bool clearPrivateKeyPem = false,
    bool clearKeyPath = false,
  }) {
    return ProxyConfig(
      type: type ?? this.type,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      keyPath: clearKeyPath ? null : (keyPath ?? this.keyPath),
      privateKeyPem:
          clearPrivateKeyPem ? null : (privateKeyPem ?? this.privateKeyPem),
    );
  }
}
