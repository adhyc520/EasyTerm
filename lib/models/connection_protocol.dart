/// Connection transport for a workspace session.
enum ConnectionProtocol {
  ssh,
  telnet,
  serial;

  int get defaultPort => switch (this) {
        ssh => 22,
        telnet => 23,
        serial => 0,
      };

  bool get supportsPrivateKey => this == ssh;
  bool get supportsSftp => this == ssh;
  bool get supportsForward => this == ssh;
  bool get supportsProxyJump => this == ssh;
  bool get supportsTcpProxy => this != serial;
  bool get supportsSecondaryShell => this != serial;
  bool get supportsIac => this == telnet;
  /// 可视化桌面依赖 SSH exec/SFTP；Telnet/串口仅终端模式。
  bool get supportsDesktop => this == ssh;

  String get displayName => switch (this) {
        ssh => 'SSH',
        telnet => 'Telnet',
        serial => 'Serial',
      };

  static ConnectionProtocol fromName(String? name) {
    switch (name?.trim().toLowerCase()) {
      case 'telnet':
        return ConnectionProtocol.telnet;
      case 'serial':
        return ConnectionProtocol.serial;
      default:
        return ConnectionProtocol.ssh;
    }
  }
}
