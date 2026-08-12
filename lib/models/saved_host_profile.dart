import 'connection_protocol.dart';
import 'proxy_config.dart';
import 'serial_port_config.dart';
import '../services/terminal_charset.dart';

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
    List<String>? tags,
    this.proxyConfig,
    this.protocol = ConnectionProtocol.ssh,
    this.serialConfig,
    this.encoding,
    this.autoInjectCredentials = true,
  }) : tags = List<String>.from(tags ?? const []);

  final String id;
  final String label;
  final String host;
  final int port;
  final String username;
  final String? keyPath;

  /// 本地保存的 SSH 密码（可选）。私钥仍由 [keyPath] 指向的文件提供。
  final String? password;

  final int updatedAtMs;

  /// 关联的 [HostTag.id] 列表。
  final List<String> tags;

  /// 可选跳板机 / 代理。
  final ProxyConfig? proxyConfig;

  final ConnectionProtocol protocol;
  final SerialPortConfig? serialConfig;
  final TerminalEncoding? encoding;
  final bool autoInjectCredentials;

  String get subtitle {
    switch (protocol) {
      case ConnectionProtocol.serial:
        return serialConfig?.subtitle ?? '$host@$port';
      case ConnectionProtocol.telnet:
        final user = username.trim();
        if (user.isEmpty) return '$host:$port';
        return '$user@$host:$port';
      case ConnectionProtocol.ssh:
        return '$username@$host:$port';
    }
  }

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
        'tags': tags,
        'proxyConfig': proxyConfig?.toJson(),
        'protocol': protocol.name,
        'serialConfig': serialConfig?.toJson(),
        'encoding': encoding?.name,
        'autoInjectCredentials': autoInjectCredentials,
      };

  factory SavedHostProfile.fromJson(Map<String, Object?> j) {
    final rawTags = j['tags'];
    final tags = <String>[];
    if (rawTags is List) {
      for (final e in rawTags) {
        if (e is String && e.isNotEmpty) tags.add(e);
      }
    }
    ProxyConfig? proxy;
    final rawProxy = j['proxyConfig'];
    if (rawProxy is Map) {
      proxy = ProxyConfig.fromJson(Map<String, Object?>.from(rawProxy));
    }
    SerialPortConfig? serial;
    final rawSerial = j['serialConfig'];
    if (rawSerial is Map) {
      serial = SerialPortConfig.fromJson(Map<String, Object?>.from(rawSerial));
    }
    final encRaw = j['encoding']?.toString();
    final encoding =
        encRaw == null || encRaw.isEmpty ? null : TerminalEncoding.fromName(encRaw);
    return SavedHostProfile(
      id: j['id']! as String,
      label: j['label']! as String,
      host: j['host']! as String,
      port: (j['port'] as num?)?.toInt() ?? 22,
      username: j['username']! as String,
      keyPath: j['keyPath'] as String?,
      password: j['password'] as String?,
      updatedAtMs: (j['updatedAtMs'] as num?)?.toInt() ?? 0,
      tags: tags,
      proxyConfig: proxy,
      protocol: ConnectionProtocol.fromName(j['protocol']?.toString()),
      serialConfig: serial,
      encoding: encoding,
      autoInjectCredentials: j['autoInjectCredentials'] as bool? ?? true,
    );
  }

  SavedHostProfile copyWith({
    String? label,
    String? host,
    int? port,
    String? username,
    String? keyPath,
    String? password,
    int? updatedAtMs,
    List<String>? tags,
    ProxyConfig? proxyConfig,
    bool clearProxyConfig = false,
    ConnectionProtocol? protocol,
    SerialPortConfig? serialConfig,
    bool clearSerialConfig = false,
    TerminalEncoding? encoding,
    bool clearEncoding = false,
    bool? autoInjectCredentials,
  }) {
    return SavedHostProfile(
      id: id,
      label: label ?? this.label,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      keyPath: keyPath ?? this.keyPath,
      password: password ?? this.password,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      tags: tags ?? this.tags,
      proxyConfig: clearProxyConfig ? null : (proxyConfig ?? this.proxyConfig),
      protocol: protocol ?? this.protocol,
      serialConfig:
          clearSerialConfig ? null : (serialConfig ?? this.serialConfig),
      encoding: clearEncoding ? null : (encoding ?? this.encoding),
      autoInjectCredentials:
          autoInjectCredentials ?? this.autoInjectCredentials,
    );
  }
}
