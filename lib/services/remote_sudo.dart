import 'dart:convert';

/// 远端特权命令：识别 sudo 密码需求，并把 `sudo -n` 转为 `sudo -S`。
abstract final class RemoteSudo {
  static const passwordRequired = '__SUDO_PASSWORD_REQUIRED__';
  static const authFailed = '__SUDO_AUTH_FAILED__';
  static const cancelled = '__SUDO_CANCELLED__';

  static bool isPasswordRequired(String? err) => err == passwordRequired;

  static bool isAuthFailed(String? err) => err == authFailed;

  static bool isCancelled(String? err) => err == cancelled;

  /// 是否像「需要交互输入密码」的 sudo 输出。
  static bool looksLikePasswordRequired(String msg) {
    final lower = msg.toLowerCase();
    return lower.contains('a password is required') ||
        lower.contains('password is required') ||
        lower.contains('sudo: a password is required') ||
        (lower.contains('sudo:') && lower.contains('password'));
  }

  /// 是否像「密码错误」的 sudo 输出。
  static bool looksLikeAuthFailed(String msg) {
    final lower = msg.toLowerCase();
    return lower.contains('sorry, try again') ||
        lower.contains('incorrect password') ||
        lower.contains('authentication failure') ||
        lower.contains('1 incorrect password attempt') ||
        lower.contains('3 incorrect password attempts');
  }

  /// `sudo -n …` → `sudo -S -p '' …`（从 stdin 读密码，抑制提示符）。
  static String toStdinCommand(String sudoNCommand) =>
      sudoNCommand.replaceAll('sudo -n ', "sudo -S -p '' ");

  static List<int> passwordStdin(String password) =>
      utf8.encode('$password\n');

  /// 解析带 `__EC:N` 的特权命令输出；成功返回 `null`。
  static String? interpretExit(
    String? raw, {
    required bool usedPassword,
    String? terminalHint,
  }) {
    if (raw == null) return '命令失败或已断开';
    final m = RegExp(r'__EC:(\d+)').firstMatch(raw);
    final ec = int.tryParse(m?.group(1) ?? '') ?? 1;
    if (ec == 0) return null;
    final msg = raw.replaceAll(RegExp(r'__EC:\d+\s*$'), '').trim();
    if (usedPassword) {
      if (looksLikeAuthFailed(msg) || looksLikePasswordRequired(msg)) {
        return authFailed;
      }
      return msg.isEmpty ? '操作失败 (exit $ec)' : msg;
    }
    if (looksLikePasswordRequired(msg)) {
      return passwordRequired;
    }
    // 兼容仍返回中文终端提示的旧路径。
    if (terminalHint != null &&
        msg.contains('sudo:') &&
        msg.toLowerCase().contains('password')) {
      return passwordRequired;
    }
    return msg.isEmpty ? '操作失败 (exit $ec)' : msg;
  }
}
