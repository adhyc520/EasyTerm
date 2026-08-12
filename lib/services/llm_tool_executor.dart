import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../util/remote_paths.dart';
import 'terminal_session_controller.dart';
import 'sftp_browser_host.dart';
import 'remote_exec_capable.dart';
import 'ssh_workspace_controller.dart';

/// 单次工具执行的宿主上下文。
final class ToolContext {
  ToolContext({
    required this.controller,
    this.onProgress,
  });

  final TerminalSessionController controller;
  final void Function(String toolName, String status)? onProgress;
}

/// 远端工具执行器抽象。
abstract class ToolExecutor {
  String get toolName;

  Future<String> execute(Map<String, dynamic> args, ToolContext ctx);
}

const int kLlmToolMaxOutputBytes = 50 * 1024;

String _shellSingleQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

String truncateToolOutput(String text, {int maxBytes = kLlmToolMaxOutputBytes}) {
  final units = utf8.encode(text);
  if (units.length <= maxBytes) return text;
  final keep = utf8.decode(units.sublist(0, maxBytes), allowMalformed: true);
  return '$keep\n… (truncated, ${units.length} bytes total, showing first $maxBytes)';
}

String toolJsonOk(Map<String, Object?> fields) =>
    jsonEncode({'ok': true, ...fields});

String toolJsonErr(String error, {String? detail, Map<String, Object?>? extra}) {
  final m = <String, Object?>{'ok': false, 'error': error};
  if (detail != null) m['detail'] = detail;
  if (extra != null) m.addAll(extra);
  return jsonEncode(m);
}

String resolveToolRemotePath(TerminalSessionController c, String path) {
  final t = path.trim();
  if (t.isEmpty) return normalizeRemotePath(c.terminalCwd);
  if (isRemoteAbsolutePath(t)) return normalizeRemotePath(t);
  return normalizeRemotePath(remoteJoin(c.terminalCwd, t));
}

Map<String, dynamic> parseToolArgs(Object? arguments) {
  if (arguments is Map) {
    return Map<String, dynamic>.from(arguments);
  }
  if (arguments is! String) return {};
  final raw = arguments.trim();
  if (raw.isEmpty) return {};
  try {
    final d = jsonDecode(raw);
    if (d is Map) return Map<String, dynamic>.from(d);
  } catch (_) {}
  return {};
}

String? _argString(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is String) return v;
  if (v == null) return null;
  return v.toString();
}

int? _argInt(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

Future<String?> _runShell(
  ToolContext ctx,
  String command, {
  bool allowInteractiveFallback = false,
}) async {
  final c = ctx.controller;
  if (!c.connected) return null;
  final exec = c is RemoteExecCapable ? c as RemoteExecCapable : null;
  if (exec == null) return null;
  return exec.runQueued(
    command,
    allowInteractiveFallback: allowInteractiveFallback,
  );
}

Future<String> _sftpReadAbsolute(
  TerminalSessionController c,
  String absolutePath, {
  int maxBytes = kLlmToolMaxOutputBytes,
}) async {
  if (c is! SftpBrowserHost) {
    throw StateError('sftp_unavailable');
  }
  final client = (c as SftpBrowserHost).sftp;
  if (client == null) {
    throw StateError('sftp_unavailable');
  }
  final file = await client.open(absolutePath, mode: SftpFileOpenMode.read);
  try {
    final stat = await file.stat();
    final size = stat.size ?? 0;
    // Cap at maxBytes+1 so we can detect truncation without loading the whole file.
    final readLen = size <= 0 ? maxBytes + 1 : math.min(size, maxBytes + 1);
    final bytes = await file.readBytes(length: readLen);
    var truncated = size > maxBytes || bytes.length > maxBytes;
    final slice = truncated && bytes.length > maxBytes
        ? bytes.sublist(0, maxBytes)
        : bytes;
    var text = utf8.decode(slice, allowMalformed: true);
    if (truncated) {
      text = truncateToolOutput(text, maxBytes: maxBytes);
    }
    return toolJsonOk({
      'path': absolutePath,
      'size': size,
      'truncated': truncated,
      'content': text,
    });
  } finally {
    await file.close();
  }
}

Future<String> _sftpWriteAbsolute(
  TerminalSessionController c,
  String absolutePath,
  String content,
) async {
  final client = (c as SftpBrowserHost).sftp;
  if (client == null) {
    throw StateError('sftp_unavailable');
  }
  final bytes = Uint8List.fromList(utf8.encode(content));
  final file = await client.open(
    absolutePath,
    mode:
        SftpFileOpenMode.create |
        SftpFileOpenMode.write |
        SftpFileOpenMode.truncate,
  );
  try {
    await file.writeBytes(bytes);
  } finally {
    await file.close();
  }
  return toolJsonOk({
    'path': absolutePath,
    'bytes_written': bytes.length,
  });
}

Future<String> _sftpListAbsolute(
  TerminalSessionController c,
  String absolutePath,
) async {
  final client = (c as SftpBrowserHost).sftp;
  if (client == null) {
    throw StateError('sftp_unavailable');
  }
  final list = await client.listdir(absolutePath);
  final entries = <Map<String, Object?>>[];
  for (final e in list) {
    if (e.filename == '.' || e.filename == '..') continue;
    final attrs = e.attr;
    entries.add({
      'name': e.filename,
      'is_dir': attrs.isDirectory,
      'is_file': attrs.isFile,
      'size': attrs.size,
      'mode': attrs.mode?.toString(),
      'mtime': attrs.modifyTime,
    });
  }
  final encoded = toolJsonOk({
    'path': absolutePath,
    'count': entries.length,
    'entries': entries,
  });
  return truncateToolOutput(encoded);
}

// --- Concrete executors ---

final class FileReadExecutor implements ToolExecutor {
  @override
  String get toolName => 'file_read';

  @override
  Future<String> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final pathArg = _argString(args, 'path')?.trim();
    if (pathArg == null || pathArg.isEmpty) {
      return toolJsonErr('missing_path');
    }
    final path = resolveToolRemotePath(ctx.controller, pathArg);
    ctx.onProgress?.call(toolName, 'reading $path');
    try {
      return await _sftpReadAbsolute(ctx.controller, path);
    } catch (e) {
      final q = _shellSingleQuote(path);
      final raw = await _runShell(
        ctx,
        'LC_ALL=C head -c $kLlmToolMaxOutputBytes $q 2>&1; echo; echo __EC:\$?',
      );
      if (raw == null) {
        return toolJsonErr('no_ssh', detail: '$e');
      }
      return toolJsonOk({
        'path': path,
        'via': 'shell',
        'content': truncateToolOutput(raw),
        'sftp_error': '$e',
      });
    }
  }
}

final class FileWriteExecutor implements ToolExecutor {
  @override
  String get toolName => 'file_write';

  @override
  Future<String> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final pathArg = _argString(args, 'path')?.trim();
    final content = _argString(args, 'content');
    if (pathArg == null || pathArg.isEmpty) {
      return toolJsonErr('missing_path');
    }
    if (content == null) {
      return toolJsonErr('missing_content');
    }
    final path = resolveToolRemotePath(ctx.controller, pathArg);
    ctx.onProgress?.call(toolName, 'writing $path');
    try {
      return await _sftpWriteAbsolute(ctx.controller, path, content);
    } catch (e) {
      final q = _shellSingleQuote(path);
      // 通过 base64 管道写入，避免 shell 元字符问题。
      final b64 = base64Encode(utf8.encode(content));
      final raw = await _runShell(
        ctx,
        'printf %s ${_shellSingleQuote(b64)} | base64 -d > $q 2>&1; echo __EC:\$?',
      );
      if (raw == null) {
        return toolJsonErr('no_ssh', detail: '$e');
      }
      final ok = raw.contains('__EC:0');
      if (!ok) {
        return toolJsonErr(
          'write_failed',
          detail: truncateToolOutput(raw),
          extra: {'path': path, 'sftp_error': '$e'},
        );
      }
      return toolJsonOk({
        'path': path,
        'via': 'shell',
        'bytes_written': utf8.encode(content).length,
        'sftp_error': '$e',
      });
    }
  }
}

final class FileListExecutor implements ToolExecutor {
  @override
  String get toolName => 'file_list';

  @override
  Future<String> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final pathArg = _argString(args, 'path')?.trim();
    final path = resolveToolRemotePath(
      ctx.controller,
      pathArg == null || pathArg.isEmpty ? '.' : pathArg,
    );
    ctx.onProgress?.call(toolName, 'listing $path');
    try {
      return await _sftpListAbsolute(ctx.controller, path);
    } catch (e) {
      final q = _shellSingleQuote(path);
      final raw = await _runShell(ctx, 'LC_ALL=C ls -la $q 2>&1');
      if (raw == null) {
        return toolJsonErr('no_ssh', detail: '$e');
      }
      return toolJsonOk({
        'path': path,
        'via': 'shell',
        'listing': truncateToolOutput(raw),
        'sftp_error': '$e',
      });
    }
  }
}

final class FileSearchExecutor implements ToolExecutor {
  @override
  String get toolName => 'file_search';

  @override
  Future<String> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final pattern = _argString(args, 'pattern')?.trim();
    if (pattern == null || pattern.isEmpty) {
      return toolJsonErr('missing_pattern');
    }
    final rootArg = _argString(args, 'path')?.trim();
    final root = resolveToolRemotePath(
      ctx.controller,
      rootArg == null || rootArg.isEmpty ? '.' : rootArg,
    );
    final maxDepth = (_argInt(args, 'max_depth') ?? 6).clamp(1, 20);
    final limit = (_argInt(args, 'limit') ?? 80).clamp(1, 500);
    ctx.onProgress?.call(toolName, 'find $pattern in $root');
    final cmd =
        'LC_ALL=C find ${_shellSingleQuote(root)} -maxdepth $maxDepth '
        '-name ${_shellSingleQuote(pattern)} 2>/dev/null | head -n $limit';
    final raw = await _runShell(ctx, cmd);
    if (raw == null) return toolJsonErr('no_ssh');
    final lines = raw
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return truncateToolOutput(
      toolJsonOk({
        'root': root,
        'pattern': pattern,
        'count': lines.length,
        'paths': lines,
      }),
    );
  }
}

final class FileGrepExecutor implements ToolExecutor {
  @override
  String get toolName => 'file_grep';

  @override
  Future<String> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final pattern = _argString(args, 'pattern');
    if (pattern == null || pattern.isEmpty) {
      return toolJsonErr('missing_pattern');
    }
    final pathArg = _argString(args, 'path')?.trim();
    final path = resolveToolRemotePath(
      ctx.controller,
      pathArg == null || pathArg.isEmpty ? '.' : pathArg,
    );
    final limit = (_argInt(args, 'limit') ?? 60).clamp(1, 400);
    ctx.onProgress?.call(toolName, 'grep $pattern in $path');
    final cmd =
        'LC_ALL=C grep -RIn --exclude-dir=.git --exclude-dir=node_modules '
        '-e ${_shellSingleQuote(pattern)} ${_shellSingleQuote(path)} 2>/dev/null '
        '| head -n $limit';
    final raw = await _runShell(ctx, cmd);
    if (raw == null) return toolJsonErr('no_ssh');
    return toolJsonOk({
      'path': path,
      'pattern': pattern,
      'matches': truncateToolOutput(raw),
    });
  }
}

final class SystemInfoExecutor implements ToolExecutor {
  @override
  String get toolName => 'system_info';

  @override
  Future<String> execute(Map<String, dynamic> args, ToolContext ctx) async {
    ctx.onProgress?.call(toolName, 'collecting');
    const cmd =
        r'{ uname -a; echo ---; (cat /etc/os-release 2>/dev/null || true); echo ---; uptime; echo ---; hostname; echo ---; whoami; echo ---; date; } 2>&1';
    final raw = await _runShell(ctx, cmd);
    if (raw == null) return toolJsonErr('no_ssh');
    return toolJsonOk({'info': truncateToolOutput(raw)});
  }
}

final class ProcessListExecutor implements ToolExecutor {
  @override
  String get toolName => 'process_list';

  @override
  Future<String> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final filter = _argString(args, 'filter')?.trim();
    final limit = (_argInt(args, 'limit') ?? 80).clamp(1, 300);
    ctx.onProgress?.call(toolName, 'ps');
    var cmd = 'LC_ALL=C ps aux 2>&1 | head -n ${limit + 1}';
    if (filter != null && filter.isNotEmpty) {
      cmd =
          'LC_ALL=C ps aux 2>&1 | head -n 1; '
          'LC_ALL=C ps aux 2>&1 | grep -F ${_shellSingleQuote(filter)} | '
          'grep -v grep | head -n $limit';
    }
    final raw = await _runShell(ctx, cmd);
    if (raw == null) return toolJsonErr('no_ssh');
    return toolJsonOk({'processes': truncateToolOutput(raw)});
  }
}

final class DiskUsageExecutor implements ToolExecutor {
  @override
  String get toolName => 'disk_usage';

  @override
  Future<String> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final pathArg = _argString(args, 'path')?.trim();
    ctx.onProgress?.call(toolName, 'df/du');
    if (pathArg != null && pathArg.isNotEmpty) {
      final path = resolveToolRemotePath(ctx.controller, pathArg);
      final raw = await _runShell(
        ctx,
        'LC_ALL=C df -h ${_shellSingleQuote(path)} 2>&1; echo ---; '
        'LC_ALL=C du -sh ${_shellSingleQuote(path)} 2>&1; echo ---; '
        'LC_ALL=C du -h --max-depth=1 ${_shellSingleQuote(path)} 2>&1 | '
        'sort -hr | head -n 40',
      );
      if (raw == null) return toolJsonErr('no_ssh');
      return toolJsonOk({
        'path': path,
        'usage': truncateToolOutput(raw),
      });
    }
    final raw = await _runShell(ctx, 'LC_ALL=C df -hT 2>&1');
    if (raw == null) return toolJsonErr('no_ssh');
    return toolJsonOk({'usage': truncateToolOutput(raw)});
  }
}

final class NetworkInfoExecutor implements ToolExecutor {
  @override
  String get toolName => 'network_info';

  @override
  Future<String> execute(Map<String, dynamic> args, ToolContext ctx) async {
    ctx.onProgress?.call(toolName, 'network');
    const cmd =
        r'{ (ip -br addr 2>/dev/null || ifconfig 2>/dev/null || true); echo ---; '
        r'(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || true); echo ---; '
        r'(ip route 2>/dev/null || route -n 2>/dev/null || true); } 2>&1';
    final raw = await _runShell(ctx, cmd);
    if (raw == null) return toolJsonErr('no_ssh');
    return toolJsonOk({'network': truncateToolOutput(raw)});
  }
}

final class PackageQueryExecutor implements ToolExecutor {
  @override
  String get toolName => 'package_query';

  @override
  Future<String> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final query = _argString(args, 'query')?.trim();
    if (query == null || query.isEmpty) {
      return toolJsonErr('missing_query');
    }
    final limit = (_argInt(args, 'limit') ?? 40).clamp(1, 200);
    ctx.onProgress?.call(toolName, 'packages $query');
    final q = _shellSingleQuote(query);
    final cmd =
        '{ '
        'if command -v dpkg >/dev/null 2>&1; then dpkg -l 2>/dev/null | grep -i $q | head -n $limit; '
        'elif command -v rpm >/dev/null 2>&1; then rpm -qa 2>/dev/null | grep -i $q | head -n $limit; '
        'elif command -v pacman >/dev/null 2>&1; then pacman -Qs $q 2>/dev/null | head -n $limit; '
        'elif command -v apk >/dev/null 2>&1; then apk info 2>/dev/null | grep -i $q | head -n $limit; '
        'else echo "no_known_package_manager"; fi; '
        '} 2>&1';
    final raw = await _runShell(ctx, cmd);
    if (raw == null) return toolJsonErr('no_ssh');
    return toolJsonOk({
      'query': query,
      'packages': truncateToolOutput(raw),
    });
  }
}

/// 工具名 → 执行器，并生成 OpenAI tools JSON。
final class LlmToolRegistry {
  LlmToolRegistry._(this._byName);

  factory LlmToolRegistry.standard() {
    final list = <ToolExecutor>[
      FileReadExecutor(),
      FileWriteExecutor(),
      FileListExecutor(),
      FileSearchExecutor(),
      FileGrepExecutor(),
      SystemInfoExecutor(),
      ProcessListExecutor(),
      DiskUsageExecutor(),
      NetworkInfoExecutor(),
      PackageQueryExecutor(),
    ];
    return LlmToolRegistry._({for (final e in list) e.toolName: e});
  }

  final Map<String, ToolExecutor> _byName;

  ToolExecutor? operator [](String name) => _byName[name];

  bool contains(String name) => _byName.containsKey(name);

  static const requiresApproval = {'file_write', 'terminal_run'};

  static bool needsApproval(String name) => requiresApproval.contains(name);

  Future<String> execute(
    String name,
    Map<String, dynamic> args,
    ToolContext ctx,
  ) async {
    final exec = _byName[name];
    if (exec == null) {
      return toolJsonErr('unknown_tool', extra: {'name': name});
    }
    try {
      return await exec.execute(args, ctx);
    } catch (e) {
      return toolJsonErr('exception', detail: '$e', extra: {'name': name});
    }
  }

  List<Map<String, Object?>> openAiTools({required bool zh}) {
    return [
      _fn(
        'file_read',
        zh
            ? '通过 SFTP（失败则 shell）读取远端文件内容。大文件自动截断。'
            : 'Read a remote file via SFTP (shell fallback). Large files are truncated.',
        {
          'path': {
            'type': 'string',
            'description': zh ? '文件路径（绝对或相对当前目录）' : 'File path (absolute or relative to cwd)',
          },
        },
        const ['path'],
      ),
      _fn(
        'file_write',
        zh
            ? '写入远端文件（需用户确认）。优先 SFTP，失败则 shell。'
            : 'Write a remote file (requires user approval). Prefers SFTP, shell fallback.',
        {
          'path': {
            'type': 'string',
            'description': zh ? '目标文件路径' : 'Destination file path',
          },
          'content': {
            'type': 'string',
            'description': zh ? '要写入的完整文本内容' : 'Full text content to write',
          },
        },
        const ['path', 'content'],
      ),
      _fn(
        'file_list',
        zh ? '列出远端目录内容。' : 'List a remote directory.',
        {
          'path': {
            'type': 'string',
            'description': zh ? '目录路径，默认当前目录' : 'Directory path; defaults to cwd',
          },
        },
        const <String>[],
      ),
      _fn(
        'file_search',
        zh ? '按文件名模式搜索（find -name）。' : 'Search files by name pattern (find -name).',
        {
          'pattern': {
            'type': 'string',
            'description': zh ? '文件名 glob，如 *.conf' : 'Filename glob, e.g. *.conf',
          },
          'path': {
            'type': 'string',
            'description': zh ? '搜索根目录' : 'Search root directory',
          },
          'max_depth': {'type': 'integer', 'description': 'maxdepth'},
          'limit': {'type': 'integer', 'description': 'max results'},
        },
        const ['pattern'],
      ),
      _fn(
        'file_grep',
        zh ? '在文件中搜索文本内容（grep -RIn）。' : 'Search file contents (grep -RIn).',
        {
          'pattern': {
            'type': 'string',
            'description': zh ? '要搜索的文本/正则' : 'Text or regex to search',
          },
          'path': {
            'type': 'string',
            'description': zh ? '搜索路径' : 'Path to search',
          },
          'limit': {'type': 'integer', 'description': 'max match lines'},
        },
        const ['pattern'],
      ),
      _fn(
        'system_info',
        zh
            ? '获取系统信息（uname、发行版、uptime 等）。'
            : 'Get system info (uname, distro, uptime, etc.).',
        const <String, Object?>{},
        const <String>[],
      ),
      _fn(
        'process_list',
        zh ? '列出进程（ps aux），可按关键字过滤。' : 'List processes (ps aux), optional filter.',
        {
          'filter': {
            'type': 'string',
            'description': zh ? '进程名/命令过滤关键字' : 'Filter substring for process name/cmd',
          },
          'limit': {'type': 'integer'},
        },
        const <String>[],
      ),
      _fn(
        'disk_usage',
        zh ? '查看磁盘占用（df/du）。' : 'Inspect disk usage (df/du).',
        {
          'path': {
            'type': 'string',
            'description': zh ? '可选：指定路径做 du' : 'Optional path for du',
          },
        },
        const <String>[],
      ),
      _fn(
        'network_info',
        zh
            ? '查看网络接口与监听端口（ip/ss）。'
            : 'Network interfaces and listening ports (ip/ss).',
        const <String, Object?>{},
        const <String>[],
      ),
      _fn(
        'package_query',
        zh
            ? '查询已安装软件包（dpkg/rpm/pacman/apk）。'
            : 'Query installed packages (dpkg/rpm/pacman/apk).',
        {
          'query': {
            'type': 'string',
            'description': zh ? '包名关键字' : 'Package name keyword',
          },
          'limit': {'type': 'integer'},
        },
        const ['query'],
      ),
    ];
  }

  static Map<String, Object?> _fn(
    String name,
    String description,
    Map<String, Object?> properties,
    List<String> required,
  ) {
    final params = <String, Object?>{
      'type': 'object',
      'properties': properties,
    };
    if (required.isNotEmpty) {
      params['required'] = required;
    }
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': params,
      },
    };
  }
}
