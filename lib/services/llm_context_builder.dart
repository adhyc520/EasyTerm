import 'terminal_session_controller.dart';
import 'remote_exec_capable.dart';
import 'ssh_workspace_controller.dart';

/// 系统上下文缓存条目（uname / distro 等）。
final class _CachedHostInfo {
  _CachedHostInfo({
    required this.uname,
    required this.distro,
    required this.uptime,
    required this.fetchedAt,
  });

  final String uname;
  final String distro;
  final String uptime;
  final DateTime fetchedAt;
}

final Map<String, _CachedHostInfo> _systemInfoCache = {};

String _cacheKey(TerminalSessionController c) =>
    '${c.username}@${c.host}:${c.port}';

/// 构建注入给 LLM 的系统上下文（主机 / 用户 / cwd / OS）。
Future<String> buildSystemContext(
  TerminalSessionController c, {
  bool zh = true,
  String? customPrompt,
}) async {
  final info = await _cachedSystemInfo(c);
  final osLabel = [
    if (info?.uname.isNotEmpty == true) info!.uname,
    if (info?.distro.isNotEmpty == true) info!.distro,
  ].join(' · ');

  final custom = customPrompt?.trim();
  if (custom != null && custom.isNotEmpty) {
    return _applyTemplateVars(
      custom,
      host: c.host,
      user: c.username,
      cwd: c.terminalCwd,
      os: osLabel.isEmpty ? (zh ? '未知' : 'unknown') : osLabel,
    );
  }

  final buf = StringBuffer();
  if (zh) {
    buf.writeln('你是 EasyTerm 里 SSH 终端旁的助手。用户已连接远程 shell。');
    buf.writeln('回答与推理可能分字段或分标签返回；向用户说明时区分「思考」与正式答复。');
    buf.writeln();
    buf.writeln('## 当前环境');
    buf.writeln('- 主机: ${c.host}');
    buf.writeln('- 用户: ${c.username}');
    buf.writeln('- 当前目录: ${c.terminalCwd}');
    if (info != null) {
      if (info.uname.isNotEmpty) buf.writeln('- 系统: ${info.uname}');
      if (info.distro.isNotEmpty) buf.writeln('- 发行版: ${info.distro}');
      if (info.uptime.isNotEmpty) buf.writeln('- 运行时间: ${info.uptime}');
    }
    buf.writeln();
    buf.writeln('## 可用工具');
    buf.writeln(
      '- 文件: file_read / file_write / file_list / file_search / file_grep',
    );
    buf.writeln(
      '- 系统: system_info / process_list / disk_usage / network_info / package_query',
    );
    buf.writeln('- 终端: terminal_run（每次注入前用户弹窗确认）');
    buf.writeln('- file_write 同样需要用户确认。');
    buf.writeln();
    buf.writeln('## 行为准则');
    buf.writeln('- 修改文件前先读取确认内容');
    buf.writeln('- 优先使用绝对路径');
    buf.writeln('- 危险命令需谨慎；terminal_run / file_write 已有确认环节');
    buf.writeln('- 工具结果据实引用，勿编造输出');
    buf.writeln('- 若命令未以换行结尾，客户端会自动补回车以便 shell 提交');
  } else {
    buf.writeln(
      'You assist next to an SSH terminal in EasyTerm. The user has an active remote shell.',
    );
    buf.writeln(
      'Separate reasoning from the final answer when presenting to the user.',
    );
    buf.writeln();
    buf.writeln('## Environment');
    buf.writeln('- Host: ${c.host}');
    buf.writeln('- User: ${c.username}');
    buf.writeln('- CWD: ${c.terminalCwd}');
    if (info != null) {
      if (info.uname.isNotEmpty) buf.writeln('- OS: ${info.uname}');
      if (info.distro.isNotEmpty) buf.writeln('- Distro: ${info.distro}');
      if (info.uptime.isNotEmpty) buf.writeln('- Uptime: ${info.uptime}');
    }
    buf.writeln();
    buf.writeln('## Tools');
    buf.writeln(
      '- Files: file_read / file_write / file_list / file_search / file_grep',
    );
    buf.writeln(
      '- System: system_info / process_list / disk_usage / network_info / package_query',
    );
    buf.writeln('- Terminal: terminal_run (user must approve every injection)');
    buf.writeln('- file_write also requires user approval.');
    buf.writeln();
    buf.writeln('## Guidelines');
    buf.writeln('- Read a file before modifying it');
    buf.writeln('- Prefer absolute paths');
    buf.writeln('- Quote tool results faithfully; do not invent output');
    buf.writeln(
      '- If command text has no trailing newline, the client appends CR',
    );
  }
  return buf.toString().trimRight();
}

String _applyTemplateVars(
  String template, {
  required String host,
  required String user,
  required String cwd,
  required String os,
}) {
  return template
      .replaceAll('{{host}}', host)
      .replaceAll('{{user}}', user)
      .replaceAll('{{cwd}}', cwd)
      .replaceAll('{{os}}', os);
}

Future<_CachedHostInfo?> _cachedSystemInfo(TerminalSessionController c) async {
  if (!c.connected) return _systemInfoCache[_cacheKey(c)];
  final key = _cacheKey(c);
  final existing = _systemInfoCache[key];
  final now = DateTime.now();
  if (existing != null &&
      now.difference(existing.fetchedAt) < const Duration(minutes: 5)) {
    return existing;
  }
  try {
    final raw = await (c as RemoteExecCapable).runRemoteForStatus(
      r'{ uname -a; echo __SEP__; '
      r'(grep -E "^(PRETTY_NAME|NAME)=" /etc/os-release 2>/dev/null | head -n 2); '
      r'echo __SEP__; uptime; } 2>&1',
    );
    if (raw == null || raw.trim().isEmpty) return existing;
    final parts = raw.split('__SEP__');
    String uname = '';
    String distro = '';
    String uptime = '';
    if (parts.isNotEmpty) uname = parts[0].trim();
    if (parts.length > 1) {
      distro = parts[1]
          .trim()
          .replaceAll(RegExp(r'PRETTY_NAME=|"|NAME='), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    if (parts.length > 2) uptime = parts[2].trim();
    final info = _CachedHostInfo(
      uname: uname,
      distro: distro,
      uptime: uptime,
      fetchedAt: now,
    );
    _systemInfoCache[key] = info;
    return info;
  } catch (_) {
    return existing;
  }
}

/// 测试或重置时可清空缓存。
void clearLlmSystemInfoCache() => _systemInfoCache.clear();
