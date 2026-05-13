import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart'
    show ChangeNotifier, TargetPlatform, defaultTargetPlatform, kIsWeb, debugPrint;
import 'package:path/path.dart' as p;
import 'package:xterm/xterm.dart';

import '../io/file_read.dart';
import '../util/remote_paths.dart';
import 'sftp_fs_transfer.dart' as sftp_transfer;
import 'workbench_settings_store.dart';

const int kMaxEditorBytes = 512 * 1024;

class SshWorkspaceController extends ChangeNotifier {
  SshWorkspaceController({
    required this.settings,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.privateKeyPem,
  });

  final WorkbenchSettingsStore settings;
  final String host;
  final int port;
  final String username;
  final String password;
  final String? privateKeyPem;

  SSHClient? _client;
  SSHSession? _shell;
  SftpClient? _sftp;

  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;

  Terminal? _terminal;

  Terminal? get terminal => _terminal;

  String _remoteCwd = '/';
  bool _loadingDir = false;
  List<SftpName> _entries = [];
  String? _error;
  bool _connecting = false;
  bool _connected = false;

  String get remoteCwd => _remoteCwd;
  List<SftpName> get entries => List.unmodifiable(_entries);
  String? get error => _error;
  bool get loadingDir => _loadingDir;
  bool get connecting => _connecting;
  bool get connected => _connected;

  SftpClient? get sftp => _sftp;

  void _setError(String? e) {
    _error = e;
    notifyListeners();
  }

  Future<void> connect() async {
    if (_connecting || _connected) return;
    _connecting = true;
    _setError(null);
    notifyListeners();

    final totalAttempts = 1 + settings.connectRetryCount;
    Object? lastError;

    for (var attempt = 0; attempt < totalAttempts; attempt++) {
      try {
        final socket = await SSHSocket.connect(
          host,
          port,
          timeout: Duration(seconds: settings.connectTimeoutSec),
        );

        List<SSHKeyPair>? identities;
        if (privateKeyPem != null && privateKeyPem!.trim().isNotEmpty) {
          identities = SSHKeyPair.fromPem(privateKeyPem!, password.isEmpty ? null : password);
        }

        _client = SSHClient(
          socket,
          username: username,
          identities: identities,
          onPasswordRequest: identities != null ? null : () async => password,
          keepAliveInterval: settings.sshKeepAliveSec <= 0
              ? null
              : Duration(seconds: settings.sshKeepAliveSec),
        );

        await _client!.authenticated;

        _shell = await _client!.shell(
          pty: SSHPtyConfig(
            type: settings.terminalTermType,
            width: settings.ptyDefaultColumns,
            height: settings.ptyDefaultRows,
          ),
        );

        _sftp = await _client!.sftp();
        await _sftp!.handshake;

        _remoteCwd = await _sftp!.absolute('.');
        await refreshDirectory();

        _initTerminal();
        _wireShell();

        _connected = true;
        lastError = null;
        break;
      } catch (e, st) {
        lastError = e;
        debugPrint('SSH connect attempt ${attempt + 1}/$totalAttempts: $e\n$st');
        await disconnect();
        if (attempt < totalAttempts - 1) {
          await Future<void>.delayed(Duration(seconds: settings.retryIntervalSec));
        }
      }
    }

    if (!_connected && lastError != null) {
      _setError(lastError.toString());
    }

    _connecting = false;
    notifyListeners();
  }

  void _initTerminal() {
    _terminal = Terminal(
      maxLines: settings.terminalMaxLines,
      platform: _xtermPlatform(),
      onOutput: (data) {
        final session = _shell;
        if (session == null) return;
        session.write(Uint8List.fromList(utf8.encode(data)));
      },
      onResize: (w, h, pw, ph) {
        _shell?.resizeTerminal(w, h, pw, ph);
      },
    );
  }

  TerminalTargetPlatform _xtermPlatform() {
    if (kIsWeb) return TerminalTargetPlatform.web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return TerminalTargetPlatform.android;
      case TargetPlatform.iOS:
        return TerminalTargetPlatform.ios;
      case TargetPlatform.fuchsia:
        return TerminalTargetPlatform.fuchsia;
      case TargetPlatform.linux:
        return TerminalTargetPlatform.linux;
      case TargetPlatform.macOS:
        return TerminalTargetPlatform.macos;
      case TargetPlatform.windows:
        return TerminalTargetPlatform.windows;
    }
  }

  void _wireShell() {
    final session = _shell;
    if (session == null) return;

    _stdoutSub?.cancel();
    _stderrSub?.cancel();

    final term = _terminal;
    if (term == null) return;

    _stdoutSub = session.stdout.listen(
      (data) {
        term.write(utf8.decode(data, allowMalformed: true));
      },
      onError: (e) => debugPrint('stdout: $e'),
    );

    _stderrSub = session.stderr.listen(
      (data) {
        term.write(utf8.decode(data, allowMalformed: true));
      },
      onError: (e) => debugPrint('stderr: $e'),
    );
  }

  Future<void> refreshDirectory() async {
    final client = _sftp;
    if (client == null) return;
    _loadingDir = true;
    notifyListeners();
    try {
      final list = await client.listdir(_remoteCwd);
      list.sort((a, b) {
        if (a.attr.isDirectory != b.attr.isDirectory) {
          return a.attr.isDirectory ? -1 : 1;
        }
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      _entries = list.where((e) => e.filename != '.' && e.filename != '..').toList();
    } catch (e) {
      _setError('SFTP: $e');
    } finally {
      _loadingDir = false;
      notifyListeners();
    }
  }

  Future<void> navigateInto(String name) async {
    final path = remoteJoin(_remoteCwd, name);
    final client = _sftp;
    if (client == null) return;
    try {
      final attrs = await client.stat(path);
      if (attrs.isDirectory) {
        _remoteCwd = path;
        await refreshDirectory();
      }
    } catch (e) {
      _setError(e.toString());
      notifyListeners();
    }
  }

  Future<void> navigateUp() async {
    final parent = remoteDirname(_remoteCwd);
    if (parent == _remoteCwd) return;
    _remoteCwd = parent;
    await refreshDirectory();
  }

  Future<void> navigateToRoot() async {
    _remoteCwd = '/';
    await refreshDirectory();
  }

  /// 跳转到绝对目录路径（须为已存在的目录）。
  Future<void> navigateToAbsolutePath(String absolutePath) async {
    final client = _sftp;
    if (client == null) return;
    var path = absolutePath.replaceAll('\\', '/');
    if (path.isEmpty) return;
    if (path != '/' && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (!path.startsWith('/')) return;
    try {
      final attrs = await client.stat(path);
      if (!attrs.isDirectory) {
        _setError('路径不是目录: $path');
        notifyListeners();
        return;
      }
      _remoteCwd = path;
      await refreshDirectory();
    } catch (e) {
      _setError(e.toString());
      notifyListeners();
    }
  }

  Future<void> deleteRemote(String name) async {
    final client = _sftp;
    if (client == null) return;
    final path = remoteJoin(_remoteCwd, name);
    final entry = _entries.firstWhere((e) => e.filename == name);
    try {
      if (entry.attr.isDirectory) {
        await client.rmdir(path);
      } else {
        await client.remove(path);
      }
      await refreshDirectory();
    } catch (e) {
      _setError(e.toString());
      notifyListeners();
    }
  }

  /// 从本机路径上传文件或整个目录到当前远程工作目录。
  Future<void> uploadLocalFsPath(String localPath) async {
    final client = _sftp;
    if (client == null) return;
    await sftp_transfer.uploadLocalPathToRemote(sftp: client, remoteCwd: _remoteCwd, localPath: localPath);
    await refreshDirectory();
  }

  Future<void> uploadLocalFile({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final client = _sftp;
    if (client == null) return;
    final path = remoteJoin(_remoteCwd, fileName);
    final file = await client.open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(bytes);
    } finally {
      await file.close();
    }
    await refreshDirectory();
  }

  /// 将当前目录下的远程文件流式保存到本机绝对路径（无编辑器体积上限）。
  Future<void> downloadRemoteFileToLocalPath(String relativeName, String localFilePath) async {
    final client = _sftp;
    if (client == null) return;
    await sftp_transfer.saveRemoteFileToLocalPath(
      sftp: client,
      remoteCwd: _remoteCwd,
      relativeName: relativeName,
      localFilePath: localFilePath,
    );
  }

  /// 将远程子目录下载到本机 [localParentPath] 下，生成 `localParentPath/relativeDirName/`。
  Future<void> downloadRemoteDirectoryToLocal(String relativeDirName, String localParentPath) async {
    final client = _sftp;
    if (client == null) return;
    final remotePath = remoteJoin(_remoteCwd, relativeDirName);
    final localDest = p.join(localParentPath, relativeDirName);
    await sftp_transfer.downloadRemoteTreeToLocalPath(
      sftp: client,
      remotePath: remotePath,
      localDirPath: localDest,
    );
  }

  Future<Uint8List?> readRemoteFile(String relativeName) async {
    final client = _sftp;
    if (client == null) return null;
    final path = remoteJoin(_remoteCwd, relativeName);
    final file = await client.open(path, mode: SftpFileOpenMode.read);
    try {
      final stat = await file.stat();
      final size = stat.size ?? 0;
      if (size > kMaxEditorBytes) {
        throw StateError('文件过大（$size 字节），上限为 $kMaxEditorBytes 字节');
      }
      return await file.readBytes();
    } finally {
      await file.close();
    }
  }

  Future<void> writeRemoteFile(String relativeName, Uint8List bytes) async {
    final client = _sftp;
    if (client == null) return;
    final path = remoteJoin(_remoteCwd, relativeName);
    final file = await client.open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(bytes);
    } finally {
      await file.close();
    }
    await refreshDirectory();
  }

  Future<int?> remoteMtime(String relativeName) async {
    final client = _sftp;
    if (client == null) return null;
    final path = remoteJoin(_remoteCwd, relativeName);
    final attrs = await client.stat(path);
    return attrs.modifyTime;
  }

  /// 与交互 shell 并行执行的非交互命令（用于底部状态栏等）。
  Future<String?> runRemoteForStatus(String command) async {
    final c = _client;
    if (c == null || !_connected) return null;
    try {
      final out = await c.run(command, stderr: false);
      return utf8.decode(out, allowMalformed: true).trim();
    } catch (e) {
      debugPrint('runRemoteForStatus: $e');
      return null;
    }
  }

  Future<void> disconnect() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;

    try {
      _shell?.close();
    } catch (_) {}
    _shell = null;

    try {
      _sftp?.close();
    } catch (_) {}
    _sftp = null;

    try {
      _client?.close();
    } catch (_) {}
    _client = null;

    _terminal = null;
    _connected = false;
    _entries = [];
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(disconnect());
    super.dispose();
  }
}

Future<String?> loadPrivateKeyFromPath(String? path) async {
  if (path == null || path.trim().isEmpty) return null;
  return readTextFile(path.trim());
}

bool looksLikeTextBytes(Uint8List data, {int sample = 4096}) {
  final n = data.length < sample ? data.length : sample;
  for (var i = 0; i < n; i++) {
    if (data[i] == 0) return false;
  }
  return true;
}
