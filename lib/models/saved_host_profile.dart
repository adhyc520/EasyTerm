/// 已保存主机配置。
///
/// [password] 为可选本地明文存储，仅用于免重复输入；请勿在不可信设备上保存敏感口令。
class SavedHostProfile {
  SavedHostProfile({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.username,
    this.keyPath,
    this.password,
    required this.updatedAtMs,
  });

  final String id;
  final String label;
  final String host;
  final int port;
  final String username;
  final String? keyPath;

  /// 本地保存的 SSH 密码（可选）。私钥仍由 [keyPath] 指向的文件提供。
  final String? password;

  final int updatedAtMs;

  String get subtitle => '$username@$host:$port';

  bool matchesEndpoint({
    required String host,
    required int port,
    required String username,
  }) {
    return this.host == host && this.port == port && this.username == username;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'host': host,
    'port': port,
    'username': username,
    'keyPath': keyPath,
    'password': password,
    'updatedAtMs': updatedAtMs,
  };

  factory SavedHostProfile.fromJson(Map<String, Object?> j) {
    return SavedHostProfile(
      id: j['id']! as String,
      label: j['label']! as String,
      host: j['host']! as String,
      port: (j['port'] as num?)?.toInt() ?? 22,
      username: j['username']! as String,
      keyPath: j['keyPath'] as String?,
      password: j['password'] as String?,
      updatedAtMs: (j['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}
