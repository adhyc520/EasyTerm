import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart'
    show
        ChangeNotifier,
        Listenable,
        TargetPlatform,
        defaultTargetPlatform,
        kIsWeb,
        debugPrint;
import 'package:flutter/widgets.dart' show Locale;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_native_extensions/raw_clipboard.dart' as sne;
import 'package:xterm/xterm.dart';

import '../io/file_read.dart';
import '../l10n/app_localizations.dart';
import '../util/remote_paths.dart';
import 'browser_gateway.dart';
import 'local_port_forwarder.dart';
import 'remote_command_queue.dart';
import 'remote_host_metrics.dart';
import 'remote_session.dart';
import 'remote_shell.dart';
import 'remote_stream.dart';
import 'sftp_browser_host.dart';
import 'sftp_fs_transfer.dart' as sftp_transfer;
import 'sftp_planned_upload.dart';
import 'sftp_remote_clipboard.dart';
import 'sftp_remote_copy.dart' as sftp_copy;
import 'sftp_upload_progress_hooks.dart';
import 'sftp_upload_task_list.dart';
import 'workbench_settings_store.dart';

const int kMaxEditorBytes = 512 * 1024;

const int _kDragChunkBytes = 256 * 1024;

/// 单次「虚拟文件拖出」会话内的取消 / 终态状态机。
///
/// 把零散的 `cancelled`、`terminal`、`sinkClosed` 三个布尔合到一个小对象里，
/// [streamRemoteFileIntoDragSink] 的成功 / 取消 / 失败三个路径都只需要调用一个
/// finishXxx 入口，避免漏掉清理或重复回调队列。
class _SftpDragVirtualFileSession {
  _SftpDragVirtualFileSession({
    required this.taskId,
    required this.taskList,
    required this.sink,
    required this.onCancelChannel,
  }) {
    onCancelChannel.addListener(_onCancel);
  }

  final String taskId;
  final SftpUploadTaskList taskList;
  final dynamic sink;
  final Listenable onCancelChannel;

  bool _userCancelled = false;
  bool _sinkClosed = false;
  bool _terminal = false;

  /// 用户取消（拖放层或队列任一处）。
  bool get cancelled =>
      _userCancelled || taskList.isCancellationRequested(taskId);

  void _onCancel() {
    _userCancelled = true;
  }

  void _closeSinkOnce() {
    if (_sinkClosed) return;
    try {
      sink.close();
      _sinkClosed = true;
    } catch (_) {}
  }

  void _addErrorToSinkQuiet(Object error, StackTrace stackTrace) {
    try {
      sink.addError(error, stackTrace);
    } catch (_) {
      /* sink may already be torn down */
    }
  }

  void finishSuccess() {
    if (_terminal) return;
    _closeSinkOnce();
    taskList.succeed(taskId);
    _terminal = true;
  }

  /// 取消时必须先把错误注入 sink，再 close。
  ///
  /// 虚拟文件拖出走的是「先承诺 fileSize，再喂字节直到 close」的协议，
  /// 如果只 close 而不 addError，Finder / Explorer 会等不到承诺的剩余字节
  /// 而陷入无响应状态——这就是「拖动完毕后停止下载，文件管理器卡死」的根因。
  void finishCancelled() {
    if (_terminal) return;
    taskList.removeCancelled(taskId);
    _terminal = true;
    _addErrorToSinkQuiet(const SftpUserCancelled(), StackTrace.current);
    _closeSinkOnce();
  }

  void finishFailed(Object error, StackTrace stackTrace) {
    if (_terminal) return;
    taskList.fail(taskId, error);
    _terminal = true;
    _addErrorToSinkQuiet(error, stackTrace);
    _closeSinkOnce();
  }

  /// 最后一道兜底：若上层异常路径漏掉了 finishXxx，dispose 会以「取消」语义补上
  /// addError + close，避免 sink 半开。
  void dispose() {
    onCancelChannel.removeListener(_onCancel);
    if (!_terminal) {
      if (cancelled) {
        finishCancelled();
      } else {
        // 流没有走到任何终态又没 cancel：通常是出现了未捕获的异常路径。
        // 视作失败，提交一次 addError 防止 OS 端无限等待。
        finishFailed(const SftpUserCancelled(), StackTrace.current);
      }
    } else if (!_sinkClosed) {
      _closeSinkOnce();
    }
  }
}

bool _sshClosedBeforeAuthMessage(String message) {
  final m = message.toLowerCase();
  return m.contains('connection closed before authentication');
}

/// SSH 协议在失败时不区分「密码错」与「密钥错」，此处按当前填写的凭据给出最可能的原因说明。
String formatSshConnectionError(
  Object error, {
  required AppLocalizations l10n,
  required bool hadPrivateKey,
  required bool passwordProvided,
}) {
  if (error is SSHInternalError) {
    return formatSshConnectionError(
      error.error,
      l10n: l10n,
      hadPrivateKey: hadPrivateKey,
      passwordProvided: passwordProvided,
    );
  }
  if (error is SSHAuthFailError) {
    if (hadPrivateKey && passwordProvided) {
      return l10n.sshAuthFailKeyAndPassword;
    }
    if (hadPrivateKey) {
      return l10n.sshAuthFailKey;
    }
    if (passwordProvided) {
      return l10n.sshAuthFailPassword;
    }
    return l10n.sshAuthFailNone;
  }
  if (error is SSHAuthAbortError) {
    final reason = error.reason;
    if (reason is SSHAuthFailError) {
      return formatSshConnectionError(
        reason,
        l10n: l10n,
        hadPrivateKey: hadPrivateKey,
        passwordProvided: passwordProvided,
      );
    }
    if (reason is SSHInternalError) {
      return formatSshConnectionError(
        reason.error,
        l10n: l10n,
        hadPrivateKey: hadPrivateKey,
        passwordProvided: passwordProvided,
      );
    }
    if (passwordProvided &&
        !hadPrivateKey &&
        _sshClosedBeforeAuthMessage(error.message)) {
      return l10n.sshNotConnectedLikelyWrongPassword;
    }
    if (reason != null) {
      return l10n.sshAuthAbort('${error.message} ($reason)');
    }
    return l10n.sshAuthAbort(error.message);
  }
  if (error is SSHKeyDecodeError) {
    return l10n.sshKeyDecode(error.message);
  }
  return error.toString();
}

/// 凭据错误或本地密钥格式问题下，新开 TCP 重试没有意义（与设置里的 [WorkbenchSettingsStore.connectRetryCount] 区分开）。
bool _sshAuthOrKeyIssueExhaustedNoBenefitFromTcpRetry(Object error) {
  if (error is SSHInternalError) {
    return _sshAuthOrKeyIssueExhaustedNoBenefitFromTcpRetry(error.error);
  }
  if (error is SSHAuthFailError) return true;
  if (error is SSHKeyDecodeError) return true;
  if (error is SSHAuthAbortError) {
    final reason = error.reason;
    if (reason != null) {
      return _sshAuthOrKeyIssueExhaustedNoBenefitFromTcpRetry(reason);
    }
    return false;
  }
  return false;
}

/// 根据异常类型判断是否应弹出「更正口令 / 密钥」类 UI（不依赖本地化后的 [String]）。
bool sshFailureShouldOfferCredentialSheet(
  Object error, {
  required bool passwordProvided,
  required bool hadPrivateKey,
}) {
  if (error is SSHInternalError) {
    return sshFailureShouldOfferCredentialSheet(
      error.error,
      passwordProvided: passwordProvided,
      hadPrivateKey: hadPrivateKey,
    );
  }
  if (_sshAuthOrKeyIssueExhaustedNoBenefitFromTcpRetry(error)) return true;
  if (error is SSHAuthAbortError) {
    final reason = error.reason;
    if (reason != null) {
      return sshFailureShouldOfferCredentialSheet(
        reason,
        passwordProvided: passwordProvided,
        hadPrivateKey: hadPrivateKey,
      );
    }
    if (passwordProvided &&
        !hadPrivateKey &&
        _sshClosedBeforeAuthMessage(error.message)) {
      return true;
    }
  }
  return false;
}

class SshWorkspaceController extends ChangeNotifier implements SftpBrowserHost {
  SshWorkspaceController({
    required this.settings,
    required this.host,
    required this.port,
    required this.username,
    required String password,
    String? privateKeyPem,
  }) : _password = password,
       _privateKeyPem = privateKeyPem {
    _remoteSession.onTransportClosed = _onRemoteTransportClosed;
  }

  final WorkbenchSettingsStore settings;
  final String host;
  final int port;
  final String username;
  String _password;
  String? _privateKeyPem;

  String get password => _password;
  String? get privateKeyPem => _privateKeyPem;

  final RemoteSession _remoteSession = RemoteSession();

  /// 传输会话（SSHClient + SftpClient + 掉线监控）。
  RemoteSession get remoteSession => _remoteSession;

  SSHClient? get _client => _remoteSession.client;
  SftpClient? get _sftp => _remoteSession.sftp;

  SSHSession? _shell;

  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;

  Terminal? _terminal;

  Terminal? get terminal => _terminal;

  /// 将文本注入当前远程 shell（经 xterm 输入路径，终端中可见）。
  void pasteRemoteInput(String text) {
    if (!_connected) return;
    _terminal?.paste(text);
  }

  /// 规范化 LLM 常见换行后注入远端 PTY；若末尾无换行/回车则追加 **`\r`**（与 xterm
  /// 默认 Return 键一致），避免 `\r\n` 在 Unix shell 下出现多余 `^M` 或错位。
  ///
  /// 使用 [Terminal.textInput] 而非 [Terminal.paste]：bracketed paste 会导致换行
  /// 不触发 readline 提交行。
  String pasteRemoteInputWithLineSubmit(String text) {
    if (!_connected) return text;
    var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (t.isNotEmpty && !t.endsWith('\n') && !t.endsWith('\r')) {
      t = '$t\r';
    }
    _terminal?.textInput(t);
    return t;
  }

  /// 截取当前终端缓冲区尾部纯文本，供助手回传给大模型。
  String snapshotTerminalTail({int maxLines = 120, int maxChars = 24000}) {
    final t = _terminal;
    if (t == null || !_connected) return '';
    try {
      final buf = t.buffer;
      final h = buf.height;
      final w = buf.viewWidth;
      if (h <= 0 || w <= 0) return '';
      final startY = math.max(0, h - maxLines);
      final range = BufferRangeLine(
        CellOffset(0, startY),
        CellOffset(w - 1, h - 1),
      );
      var text = buf.getText(range);
      if (text.length > maxChars) {
        text = text.substring(text.length - maxChars);
      }
      return text;
    } catch (e, st) {
      debugPrint('snapshotTerminalTail: $e\n$st');
      return '';
    }
  }

  /// 仅在本地终端视图追加文本（不发送到远端 PTY），用于助手回显抓取结果等。
  void injectTerminalLocalDisplay(String text) {
    final t = _terminal;
    if (t == null || !_connected) return;
    try {
      t.write(text);
      notifyListeners();
    } catch (e, st) {
      debugPrint('injectTerminalLocalDisplay: $e\n$st');
    }
  }

  String _remoteCwd = '/';
  bool _loadingDir = false;
  List<SftpName> _entries = [];
  String? _error;
  bool _connecting = false;
  bool _connected = false;
  bool _sessionDisposed = false;

  /// 曾连上后又意外断开（传输层关闭 / 出错）。为 `true` 时 [_terminal] 仍保留，
  /// 供 UI 在历史缓冲之上叠加「重新连接」入口。
  bool _dropped = false;

  @override
  String get remoteCwd => _remoteCwd;
  @override
  List<SftpName> get entries => List.unmodifiable(_entries);
  String? get error => _error;
  @override
  bool get loadingDir => _loadingDir;
  bool get connecting => _connecting;
  bool get connected => _connected;
  bool get dropped => _dropped;

  bool _suggestCredentialSheetAfterFailure = false;

  /// 上一次 [connect] 以「凭据相关」理由结束时为 `true`（口令/密钥等），用于弹出修改凭据表单。
  bool get suggestCredentialSheetAfterFailure =>
      _suggestCredentialSheetAfterFailure;

  @override
  SftpClient? get sftp => _sftp;

  /// 相对当前 cwd，或已是绝对路径（以 `/` 开头）时原样返回。
  String resolveRemotePath(String nameOrAbsolute) {
    final n = nameOrAbsolute.replaceAll('\\', '/');
    if (n.startsWith('/')) return n;
    return remoteJoin(_remoteCwd, n);
  }

  /// 桌面层复用同一 [SSHClient]；断线时为 `null`。
  SSHClient? get clientForDesktop => _client;

  BrowserGateway? _browserGateway;
  final List<LocalPortForwarder> _desktopForwards = [];

  /// 桌面多终端：在同一 [SSHClient] 上开独立 PTY。
  Future<RemoteShell> openShell({int? cols, int? rows}) async {
    final client = _client;
    if (client == null) {
      throw StateError('SSH 未连接');
    }
    return RemoteShell.open(
      client,
      settings: settings,
      cols: cols,
      rows: rows,
    );
  }

  /// 懒创建并启动进程内 HTTP 网关（方案 B）；掉线/断连时由 [_teardownConnection] 停止。
  Future<BrowserGateway> getOrCreateGateway() async {
    final client = _client;
    if (client == null) {
      throw StateError('SSH 未连接');
    }
    final existing = _browserGateway;
    if (existing != null && existing.isRunning) {
      // 客户端更换后需重建
      if (identical(existing.client, client)) return existing;
      await existing.stop();
      _browserGateway = null;
    }
    final gw = BrowserGateway(client);
    await gw.start();
    _browserGateway = gw;
    return gw;
  }

  /// 方案 A 兜底：本地监听 + 每连接一条 forwardLocal。
  /// 断连时本控制器会统一 [stop]；调用方也可 [releaseLocalForward]。
  Future<LocalPortForwarder> openLocalForward(
    String remoteHost,
    int remotePort, {
    int? localPort,
  }) async {
    final client = _client;
    if (client == null) {
      throw StateError('SSH 未连接');
    }
    final fwd = LocalPortForwarder(client, remoteHost, remotePort);
    await fwd.start(localPort: localPort);
    _desktopForwards.add(fwd);
    return fwd;
  }

  /// 停止并移出登记表（浏览器直连切换目标端口时用）。
  Future<void> releaseLocalForward(LocalPortForwarder? fwd) async {
    if (fwd == null) return;
    _desktopForwards.remove(fwd);
    try {
      await fwd.stop();
    } catch (_) {}
  }

  /// 拖曳上传任务列表（仅监听本对象可避免整页文件树随字节进度重建）。
  @override
  final SftpUploadTaskList uploadTasks = SftpUploadTaskList();

  void _setError(String? e, {bool notify = true}) {
    _error = e;
    if (notify) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_sessionDisposed) return;
    super.notifyListeners();
  }

  Future<void> connect() async {
    if (_connecting || _connected) return;
    if (_sessionDisposed) return;
    _connecting = true;
    _dropped = false;
    _remoteSession.clearDropped();
    _suggestCredentialSheetAfterFailure = false;
    _setError(null);
    notifyListeners();

    final totalAttempts = 1 + settings.connectRetryCount;
    Object? lastError;

    try {
      for (var attempt = 0; attempt < totalAttempts; attempt++) {
        if (_sessionDisposed) return;
        try {
          final socket = await SSHSocket.connect(
            host,
            port,
            timeout: Duration(seconds: settings.connectTimeoutSec),
          );
          if (_sessionDisposed) {
            try {
              socket.close();
            } catch (_) {}
            return;
          }

          List<SSHKeyPair>? identities;
          final pem = _privateKeyPem?.trim();
          if (pem != null && pem.isNotEmpty) {
            identities = SSHKeyPair.fromPem(
              pem,
              _password.isEmpty ? null : _password,
            );
          }

          // 公钥失败时仍应尝试密码；部分服务端只开启 keyboard-interactive（未开启 password 方法）。
          final hasPassword = _password.isNotEmpty;
          final client = SSHClient(
            socket,
            username: username,
            identities: identities,
            onPasswordRequest: hasPassword ? () async => _password : null,
            onUserInfoRequest: hasPassword
                ? (req) async =>
                      List<String>.filled(req.prompts.length, _password)
                : null,
            keepAliveInterval: settings.sshKeepAliveSec <= 0
                ? null
                : Duration(seconds: settings.sshKeepAliveSec),
          );

          await client.authenticated;
          if (_sessionDisposed) {
            try {
              client.close();
            } catch (_) {}
            return;
          }

          await _remoteSession.attach(client);
          if (_sessionDisposed) return;

          _shell = await _client!.shell(
            pty: SSHPtyConfig(
              type: settings.terminalTermType,
              width: settings.ptyDefaultColumns,
              height: settings.ptyDefaultRows,
            ),
          );

          if (_sessionDisposed) return;

          _remoteCwd = await _sftp!.absolute('.');
          await refreshDirectory();
          if (_sessionDisposed) return;

          // 重连时复用已有 Terminal，保留滚动缓冲；首次连接才新建。
          if (_terminal == null) {
            _initTerminal();
          }
          _wireShell();

          _connected = true;
          _dropped = false;
          lastError = null;
          break;
        } catch (e, st) {
          lastError = e;
          debugPrint(
            'SSH connect attempt ${attempt + 1}/$totalAttempts: $e\n$st',
          );
          // 重连（_terminal 已存在）时保留终端历史；首次连接照旧彻底清空。
          await _teardownConnection(keepTerminal: _terminal != null);
          if (_sshAuthOrKeyIssueExhaustedNoBenefitFromTcpRetry(e)) {
            break;
          }
          if (attempt < totalAttempts - 1) {
            await Future<void>.delayed(
              Duration(seconds: settings.retryIntervalSec),
            );
          }
        }
      }

      // 须在 _connecting 置假之前写入；否则终端区域仍走「连接中」分支，用户看不到本地化错误文案。
      if (!_connected && lastError != null) {
        final hadPrivateKey =
            _privateKeyPem != null && _privateKeyPem!.trim().isNotEmpty;
        _suggestCredentialSheetAfterFailure =
            sshFailureShouldOfferCredentialSheet(
              lastError,
              passwordProvided: _password.isNotEmpty,
              hadPrivateKey: hadPrivateKey,
            );
        try {
          final l10n = lookupAppLocalizations(Locale(settings.appLocaleCode));
          _setError(
            formatSshConnectionError(
              lastError,
              l10n: l10n,
              hadPrivateKey: hadPrivateKey,
              passwordProvided: _password.isNotEmpty,
            ),
            notify: false,
          );
        } catch (e, st) {
          debugPrint('SSH format connection error failed: $e\n$st');
          _setError('$lastError', notify: false);
        }
      } else if (!_connected) {
        _suggestCredentialSheetAfterFailure = false;
      }
    } finally {
      _connecting = false;
      notifyListeners();
    }
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

    _stdoutSub = session.stdout.listen((data) {
      term.write(utf8.decode(data, allowMalformed: true));
    }, onError: (e) => debugPrint('stdout: $e'));

    _stderrSub = session.stderr.listen((data) {
      term.write(utf8.decode(data, allowMalformed: true));
    }, onError: (e) => debugPrint('stderr: $e'));
  }

  @override
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
      _entries = list
          .where((e) => e.filename != '.' && e.filename != '..')
          .toList();
    } catch (e) {
      _setError('SFTP: $e');
    } finally {
      _loadingDir = false;
      notifyListeners();
    }
  }

  @override
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
  @override
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

  @override
  Future<void> deleteRemote(String name) async {
    final client = _sftp;
    if (client == null) return;
    final path = remoteJoin(_remoteCwd, name);
    try {
      await sftp_transfer.removeRemotePathRecursive(
        sftp: client,
        remotePath: path,
      );
      await refreshDirectory();
    } catch (e) {
      _setError(e.toString());
      notifyListeners();
    }
  }

  @override
  Future<void> createRemoteDirectory(String name) async {
    final client = _sftp;
    if (client == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.contains('/') || trimmed.contains('\\')) {
      throw ArgumentError('invalid directory name');
    }
    final path = remoteJoin(_remoteCwd, trimmed);
    try {
      await client.mkdir(path);
      await refreshDirectory();
    } catch (e) {
      _setError(e.toString());
      notifyListeners();
      rethrow;
    }
  }

  @override
  Future<void> createRemoteFile(String name) async {
    final client = _sftp;
    if (client == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.contains('/') || trimmed.contains('\\')) {
      throw ArgumentError('invalid file name');
    }
    final path = remoteJoin(_remoteCwd, trimmed);
    try {
      final file = await client.open(
        path,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.exclusive,
      );
      await file.close();
      await refreshDirectory();
    } catch (e) {
      _setError(e.toString());
      notifyListeners();
      rethrow;
    }
  }

  @override
  Future<void> renameRemote(String oldName, String newName) async {
    final client = _sftp;
    if (client == null) return;
    final next = newName.trim();
    if (next.isEmpty || next.contains('/') || next.contains('\\')) {
      throw ArgumentError('invalid name');
    }
    if (next == oldName) return;
    final from = remoteJoin(_remoteCwd, oldName);
    final to = remoteJoin(_remoteCwd, next);
    try {
      await client.rename(from, to);
      await refreshDirectory();
    } catch (e) {
      _setError(e.toString());
      notifyListeners();
      rethrow;
    }
  }

  @override
  Future<List<String>> copyRemoteNamesFrom({
    required String fromCwd,
    required List<String> names,
    String? toCwd,
  }) async {
    final client = _sftp;
    if (client == null) return const [];
    final dest = toCwd ?? _remoteCwd;
    try {
      final pasted = await sftp_copy.sftpCopyRemoteNames(
        client: client,
        fromCwd: fromCwd,
        toCwd: dest,
        names: names,
      );
      notifyRemoteFsChanged();
      await refreshDirectory();
      return pasted;
    } on sftp_copy.SftpRemotePastePartialFailure catch (e) {
      notifyRemoteFsChanged();
      await refreshDirectory();
      _setError(e.toString());
      notifyListeners();
      rethrow;
    } catch (e) {
      _setError(e.toString());
      notifyListeners();
      rethrow;
    }
  }

  @override
  Future<List<String>> moveRemoteNamesFrom({
    required String fromCwd,
    required List<String> names,
    String? toCwd,
  }) async {
    final client = _sftp;
    if (client == null) return const [];
    final dest = toCwd ?? _remoteCwd;
    try {
      final pasted = await sftp_copy.sftpMoveRemoteNames(
        client: client,
        fromCwd: fromCwd,
        toCwd: dest,
        names: names,
      );
      clearRemoteClipboardAfterMove(fromCwd: fromCwd, names: names);
      notifyRemoteFsChanged();
      await refreshDirectory();
      return pasted;
    } on sftp_copy.SftpRemotePastePartialFailure catch (e) {
      if (e.pasted.isNotEmpty) {
        clearRemoteClipboardAfterMove(fromCwd: fromCwd, names: e.pasted);
      }
      notifyRemoteFsChanged();
      await refreshDirectory();
      _setError(e.toString());
      notifyListeners();
      rethrow;
    } catch (e) {
      _setError(e.toString());
      notifyListeners();
      rethrow;
    }
  }

  /// 从本机路径上传文件或整个目录到当前远程工作目录。
  /// 追加到现有队列而不清空，以便多文件拖入不丢失已有任务进度。
  Future<void> uploadLocalFsPath(String localPath) async {
    final client = _sftp;
    if (client == null) return;
    final plan = await sftp_transfer.planLocalUpload(
      remoteCwd: _remoteCwd,
      localPath: localPath,
    );
    final uploadTaskIds = plan.map((e) => e.localPath).toSet();
    if (plan.isNotEmpty) {
      uploadTasks.appendTasks(
        plan
            .map(
              (e) => SftpUploadTaskView(
                id: e.localPath,
                label: e.displayLabel,
                totalBytes: e.sizeBytes,
                direction: SftpTransferDirection.upload,
              ),
            )
            .toList(),
      );
    }
    try {
      await sftp_transfer.uploadPlannedFiles(
        sftp: client,
        remoteCwd: _remoteCwd,
        localPath: localPath,
        plan: plan,
        hooks: _uploadHooks(uploadTaskIds),
      );
    } catch (e) {
      _failRemainingTasks(uploadTaskIds, e);
    }
    await refreshDirectory();
  }

  /// 批量上传多个本机路径（拖入多个文件/目录时一次性处理）。
  @override
  Future<void> uploadMultipleLocalPaths(List<String> localPaths) async {
    final client = _sftp;
    if (client == null) return;
    // 1) 先规划所有文件，一次性填入队列。
    final allPlans = <(String localPath, List<SftpPlannedUploadFile> plan)>[];
    final allTaskIds = <String>{};
    for (final lp in localPaths) {
      final plan = await sftp_transfer.planLocalUpload(
        remoteCwd: _remoteCwd,
        localPath: lp,
      );
      allPlans.add((lp, plan));
      allTaskIds.addAll(plan.map((e) => e.localPath));
    }
    final taskViews = <SftpUploadTaskView>[];
    for (final (_, plan) in allPlans) {
      for (final e in plan) {
        taskViews.add(
          SftpUploadTaskView(
            id: e.localPath,
            label: e.displayLabel,
            totalBytes: e.sizeBytes,
            direction: SftpTransferDirection.upload,
          ),
        );
      }
    }
    if (taskViews.isNotEmpty) {
      uploadTasks.appendTasks(taskViews);
    }
    // 2) 逐条路径上传。
    for (final (localPath, plan) in allPlans) {
      try {
        await sftp_transfer.uploadPlannedFiles(
          sftp: client,
          remoteCwd: _remoteCwd,
          localPath: localPath,
          plan: plan,
          hooks: _uploadHooks(allTaskIds),
        );
      } catch (e) {
        _failRemainingTasks(allTaskIds, e);
      }
    }
    await refreshDirectory();
  }

  SftpUploadProgressHooks _uploadHooks(Set<String> taskIds) {
    return SftpUploadProgressHooks(
      shouldCancelUpload: uploadTasks.isCancellationRequested,
      onFileStart: (path, String displayLabel, int totalBytes) =>
          uploadTasks.setUploading(path),
      onFileProgress: (path, up, _) => uploadTasks.progress(path, up),
      onFileEnd: (path, err) {
        if (err is SftpUserCancelled) {
          uploadTasks.removeCancelled(path);
          return;
        }
        if (err != null) {
          uploadTasks.fail(path, err);
        } else {
          uploadTasks.succeed(path);
        }
      },
    );
  }

  void _failRemainingTasks(Set<String> taskIds, Object error) {
    for (final row in List<SftpUploadTaskView>.of(uploadTasks.items)) {
      if (taskIds.contains(row.id) && row.state != SftpUploadRowState.failed) {
        uploadTasks.fail(row.id, error);
      }
    }
  }

  /// 检测当前远程目录下是否已有与 [localPath] 最后一级同名的项。
  @override
  Future<SftpRemoteUploadConflict> inspectLocalUploadConflict(
    String localPath,
  ) async {
    final client = _sftp;
    if (client == null) return SftpRemoteUploadConflict.none;
    return sftp_transfer.inspectUploadConflict(
      sftp: client,
      remoteCwd: _remoteCwd,
      localPath: localPath,
    );
  }

  /// 删除当前远程目录下名为 [relativeName] 的文件或整棵子目录（用于覆盖上传前）。
  @override
  Future<void> removeRemoteSubtreeForOverwrite(String relativeName) async {
    final client = _sftp;
    if (client == null) return;
    final path = remoteJoin(_remoteCwd, relativeName);
    await sftp_transfer.removeRemotePathRecursive(
      sftp: client,
      remotePath: path,
    );
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
    await refreshDirectory();
  }

  /// 将当前目录下的远程文件流式保存到本机绝对路径（无编辑器体积上限）。
  @override
  Future<void> downloadRemoteFileToLocalPath(
    String relativeName,
    String localFilePath,
  ) async {
    final client = _sftp;
    if (client == null) return;
    final remotePath = resolveRemotePath(relativeName);
    final plan = await sftp_transfer.planDownloadSingleFile(
      sftp: client,
      remotePath: remotePath,
      localPath: localFilePath,
      displayLabel: remoteBasename(relativeName),
    );
    final taskIds = plan.map((e) => e.taskId).toSet();
    uploadTasks.appendTasks(
      plan
          .map(
            (e) => SftpUploadTaskView(
              id: e.taskId,
              label: e.displayLabel,
              totalBytes: e.sizeBytes,
              direction: SftpTransferDirection.download,
            ),
          )
          .toList(),
    );
    try {
      await sftp_transfer.executeDownloadPlan(
        sftp: client,
        plan: plan,
        hooks: _downloadHooks(taskIds),
      );
    } catch (e) {
      _failRemainingTasks(taskIds, e);
    }
  }

  /// 将远程文件下载到临时文件，用于不支持虚拟拖出文件的平台（如 Linux）。
  /// 下载完成后会注册到 [registerDragTempPath]，以避免拖回时再次自上传。
  ///
  /// 若用户在物化过程中通过队列上的 × 取消了下载，[downloadRemoteFileToLocalPath]
  /// 会把本地半成品文件删掉但函数本身仍然返回。这里再多做一道存在性检查并抛出
  /// [SftpUserCancelled]，避免把一个指向「已被删除路径」的 DragItem 交给原生层
  /// 导致 Finder / Explorer 卡在「读取源文件」的状态。
  Future<String> materializeRemoteFileToTempForDrag(String relativeName) async {
    final client = _sftp;
    if (client == null) {
      throw StateError('SFTP not connected');
    }
    final dir = await getTemporaryDirectory();
    final base = remoteBasename(relativeName);
    final path = p.join(
      dir.path,
      'easyterm_drag_${DateTime.now().microsecondsSinceEpoch}_$base',
    );
    await downloadRemoteFileToLocalPath(relativeName, path);
    if (!sftp_transfer.localFileExistsSync(path)) {
      throw const SftpUserCancelled();
    }
    registerDragTempPath(path);
    return path;
  }

  /// 当前正在被原生拖放使用的临时本地路径集合（拖出的文件 / 目录）。
  ///
  /// 用于在拖回到 SFTP 面板时识别并跳过自上传：[isPathFromRecentDragOut] 既检查
  /// 集合中的精确路径，也判断目标是否落在已注册的拖出根目录内（拖出目录 + 子文件）。
  ///
  /// 静态字段使得跨标签页的多 SshWorkspaceController 也能共享一份集合，
  /// 避免在 A 标签页拖出后到 B 标签页 SFTP 面板再次上传同一份临时文件。
  static final Set<String> _activeDragTempPaths = <String>{};

  /// 临时本地路径 → 远端绝对路径（跨窗口拖到终端/编辑器时还原远端路径）。
  static final Map<String, String> _dragTempToRemote = <String, String>{};

  /// 最近一次内部拖出的远端路径（虚拟文件流无 temp 时的兜底）。
  static String? lastDragRemotePath;

  /// 当前内部拖出的远端绝对路径列表（支持多选拖到另一文件管理器窗口）。
  static List<String> activeDragRemotePaths = const [];

  /// 远端树变更世代：桌面多文件管理器窗口据此刷新源目录。
  int _remoteFsEpoch = 0;
  int get remoteFsEpoch => _remoteFsEpoch;

  void notifyRemoteFsChanged() {
    _remoteFsEpoch++;
    notifyListeners();
  }

  /// 会话级远程复制/剪切剪贴板（跨文件管理器窗口共享）。
  SftpRemoteClipboard? _remoteFileClipboard;
  SftpRemoteClipboard? get remoteFileClipboard => _remoteFileClipboard;

  void setRemoteFileClipboard(SftpRemoteClipboard? value) {
    _remoteFileClipboard = value;
    notifyListeners();
  }

  void clearRemoteClipboardAfterMove({
    required String fromCwd,
    required List<String> names,
  }) {
    final clip = _remoteFileClipboard;
    if (clip == null || !clip.isCut) return;
    if (normalizeRemotePathForCompare(clip.sourceCwd) !=
        normalizeRemotePathForCompare(fromCwd)) {
      return;
    }
    final moved = names.toSet();
    final left = clip.names.where((n) => !moved.contains(n)).toList();
    setRemoteFileClipboard(
      left.isEmpty
          ? null
          : SftpRemoteClipboard(
              sourceCwd: clip.sourceCwd,
              names: left,
              isCut: true,
            ),
    );
  }

  static void registerDragTempPath(String path, {String? remotePath}) {
    if (path.isEmpty) return;
    final norm = p.normalize(path);
    _activeDragTempPaths.add(norm);
    if (remotePath != null && remotePath.isNotEmpty) {
      _dragTempToRemote[norm] = remotePath;
      lastDragRemotePath = remotePath;
    }
  }

  static void unregisterDragTempPath(String path) {
    if (path.isEmpty) return;
    final norm = p.normalize(path);
    _activeDragTempPaths.remove(norm);
    _dragTempToRemote.remove(norm);
  }

  /// 若 [absolutePath] 是近期拖出的临时副本，返回对应远端绝对路径。
  static String? remotePathForDragTemp(String absolutePath) {
    if (absolutePath.isEmpty) return null;
    final norm = p.normalize(absolutePath);
    final direct = _dragTempToRemote[norm];
    if (direct != null) return direct;
    for (final e in _dragTempToRemote.entries) {
      if (p.isWithin(e.key, norm) || p.equals(e.key, norm)) {
        return e.value;
      }
    }
    return null;
  }

  /// 判断 [absolutePath] 是否为本应用近期拖出的临时副本（精确匹配或位于其下）。
  static bool isPathFromRecentDragOut(String absolutePath) {
    if (absolutePath.isEmpty) return false;
    final norm = p.normalize(absolutePath);
    if (_activeDragTempPaths.contains(norm)) return true;
    for (final root in _activeDragTempPaths) {
      if (p.isWithin(root, norm) || p.equals(root, norm)) return true;
    }
    final base = p.basename(norm);
    return base.startsWith('easyterm_drag_') ||
        base.startsWith('easyterm_dragdir_') ||
        base.startsWith('easyterm_clip_') ||
        norm.contains('${p.separator}easyterm_drag_') ||
        norm.contains('${p.separator}easyterm_dragdir_') ||
        norm.contains('${p.separator}easyterm_clip_');
  }

  /// 「拖动立即开始 + 后台逐文件下载」模式的目录拖出。
  ///
  /// 流程：
  /// 1. 同步创建一个空的临时目录并立刻返回路径，让原生层立即用它启动原生拖动，
  ///    避免「点击后等几秒拖影才动」的卡顿感。
  /// 2. 在后台异步规划远程树 + 接队列下载，进度可在底部任务列表里看到。
  /// 3. Finder/Explorer 会在用户 drop 的瞬间递归拷贝**当时**临时目录里已经
  ///    存在的内容；drop 之后再到达的文件不会被它补抓。所以建议用户在队列
  ///    清空后再松手，才能拿到完整目录；只要不主动按 × 取消，后台下载就会
  ///    一直跑到结束。
  ///
  /// [shouldAbortBeforeStart] 仅控制「同步阶段」是否提前放弃（例如在拖动 token
  /// 还没真正启动前用户就抬手了）。一旦同步阶段把目录交给原生层，后台下载只能
  /// 通过队列上的 × 取消，因为 OS 端的拖放完成事件无法区分「成功 drop」与
  /// 「中途放弃」。
  Future<String> startBackgroundDirectoryDragOut(
    String relativeName, {
    bool Function()? shouldAbortBeforeStart,
  }) async {
    final client = _sftp;
    if (client == null) {
      throw StateError('SFTP not connected');
    }

    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final tempParent = p.join(dir.path, 'easyterm_dragdir_$stamp');
    final baseName = remoteBasename(relativeName);
    final localDest = p.join(tempParent, baseName);

    if (shouldAbortBeforeStart?.call() == true) {
      throw const SftpUserCancelled();
    }

    await sftp_transfer.ensureLocalDirectoryExists(localDest);
    registerDragTempPath(localDest);

    // 后台扫树 + 下载。任何阶段抛错都会被 _runBackgroundDirectoryDragDownload
    // 内部消化（队列 fail + 临时目录清理），不会让 unawaited future 留下未处理的异常。
    unawaited(
      _runBackgroundDirectoryDragDownload(
        relativeName: relativeName,
        localDest: localDest,
        tempParent: tempParent,
        stamp: stamp,
      ),
    );

    return localDest;
  }

  Future<void> _runBackgroundDirectoryDragDownload({
    required String relativeName,
    required String localDest,
    required String tempParent,
    required int stamp,
  }) async {
    final client = _sftp;
    if (client == null) return;
    final remotePath = resolveRemotePath(relativeName);
    final baseName = remoteBasename(relativeName);

    // 边规划边把发现的文件追加到 UI 队列，让用户在拖出瞬间就能看到任务一条条
    // 涌入（而不是「拖出后队列空很久，突然出现一大堆」）。原来的实现会先把整棵
    // 远端树扫描完才填队列，对一个含几十个文件的目录而言这段静默期可能长达
    // 几秒；如果用户在这段时间内松手，Finder/Explorer 拷到的就是一个仍然几乎
    // 空白的临时目录 —— 也就是「目录内容完全不全」的现象。
    final taskIds = <String>{};
    final List<sftp_transfer.SftpPlannedDownloadFile> plan;
    try {
      plan = await sftp_transfer.planRemoteDirectoryDownload(
        sftp: client,
        remoteTreeRoot: remotePath,
        localTreeRoot: localDest,
        displayRootLabel: baseName,
        taskIdPrefix: 'dragdir_${stamp}_${relativeName.hashCode}',
        onEntryDiscovered: (entry) {
          taskIds.add(entry.taskId);
          uploadTasks.appendTasks([
            SftpUploadTaskView(
              id: entry.taskId,
              label: entry.displayLabel,
              totalBytes: entry.sizeBytes,
              direction: SftpTransferDirection.download,
            ),
          ]);
        },
      );
    } on SftpUserCancelled {
      return;
    } catch (e, st) {
      debugPrint('plan dir for drag-out: $e\n$st');
      return;
    }

    if (plan.isEmpty) return;

    // 此处的 wasAborted **只看队列上的 ×**：因为原生拖放完成事件不区分「成功
    // drop」和「用户放弃」，把会话结束当作取消会出现「drop 成功但目录只剩半个
    // 文件」的情况。
    //
    // 用 latch 锁定批次级别的取消状态：一旦在队列里点过任意一个 ×，整个目录
    // 拖出批次永久作废。否则 [SftpUploadTaskList.removeCancelled] 会在取消生效
    // 后立刻把 id 从 `_cancelledIds` 移除，下一文件的 `isCancellationRequested`
    // 又变回 false，导致后续待下载文件继续被打开，用户只能逐个手动 × ——
    // 也正是「取消一个，新的又开始下，必须挨个点 × 才能停」这一现象的根因。
    var batchAborted = false;
    bool wasAborted() {
      if (batchAborted) return true;
      for (final id in taskIds) {
        if (uploadTasks.isCancellationRequested(id)) {
          batchAborted = true;
          return true;
        }
      }
      return false;
    }

    try {
      await sftp_transfer.executeDownloadPlan(
        sftp: client,
        plan: plan,
        hooks: SftpUploadProgressHooks(
          shouldCancelUpload: (_) => wasAborted(),
          onFileStart: (taskId, label, total) =>
              uploadTasks.setUploading(taskId),
          onFileProgress: (taskId, up, _) => uploadTasks.progress(taskId, up),
          onFileEnd: (taskId, err) {
            if (err is SftpUserCancelled) {
              uploadTasks.removeCancelled(taskId);
              return;
            }
            if (err != null) {
              uploadTasks.fail(taskId, err);
            } else {
              uploadTasks.succeed(taskId);
            }
          },
        ),
      );
    } catch (e, st) {
      debugPrint('background dir drag-out: $e\n$st');
      _failRemainingTasks(taskIds, e);
    }

    if (wasAborted()) {
      for (final id in taskIds) {
        if (uploadTasks.items.any((t) => t.id == id)) {
          uploadTasks.removeCancelled(id);
        }
      }
      // 用户主动取消了：把整个临时目录抹掉，也从活跃拖出集合里反注册。
      sftp_transfer.deleteLocalDirectoryQuiet(tempParent);
      unregisterDragTempPath(localDest);
    }
  }

  /// 将远程文件按字节流写入系统拖放提供的 [sink]（虚拟文件导出）。
  ///
  /// 流式拷贝过程中会同步更新 [uploadTasks] 队列（含进度、失败、取消三种终态）。
  /// 完成方式：
  ///   * 成功：写入完成 → `succeed` → 任务从队列移除。
  ///   * 取消：用户在队列点 × 或拖放层 `onCancel` 触发 → `removeCancelled`。
  ///   * 失败：远端异常 → `fail`，同时把错误反馈给 sink 让原生层结束等待。
  Future<void> streamRemoteFileIntoDragSink({
    required String relativeName,
    required int fileSizeBytes,
    required dynamic sink,
    required sne.WriteProgress progress,
  }) async {
    final client = _sftp;
    if (client == null) return;

    final safeName = relativeName.replaceAll(RegExp(r'[/\\]'), '_');
    final taskId = 'drag_${DateTime.now().microsecondsSinceEpoch}_$safeName';

    uploadTasks.appendTasks([
      SftpUploadTaskView(
        id: taskId,
        label: relativeName,
        totalBytes: fileSizeBytes < 0 ? 0 : fileSizeBytes,
        direction: SftpTransferDirection.download,
      ),
    ]);
    uploadTasks.setUploading(taskId);

    final session = _SftpDragVirtualFileSession(
      taskId: taskId,
      taskList: uploadTasks,
      sink: sink,
      onCancelChannel: progress.onCancel,
    );

    try {
      final remotePath = resolveRemotePath(relativeName);
      final opened = await client.open(remotePath, mode: SftpFileOpenMode.read);
      try {
        if (fileSizeBytes <= 0) {
          uploadTasks.progress(taskId, 0);
          if (session.cancelled) {
            session.finishCancelled();
          } else {
            session.finishSuccess();
          }
          return;
        }
        var offset = 0;
        while (offset < fileSizeBytes && !session.cancelled) {
          final take = math.min(_kDragChunkBytes, fileSizeBytes - offset);
          final chunk = await opened.readBytes(length: take, offset: offset);
          if (chunk.isEmpty) break;
          sink.add(chunk);
          offset += chunk.length;
          progress.updateProgress(offset / fileSizeBytes);
          uploadTasks.progress(taskId, offset);
        }
        if (session.cancelled) {
          session.finishCancelled();
        } else {
          session.finishSuccess();
        }
      } finally {
        try {
          await opened.close();
        } catch (_) {}
      }
    } catch (e, st) {
      debugPrint('streamRemoteFileIntoDragSink: $e\n$st');
      session.finishFailed(e, st);
    } finally {
      session.dispose();
    }
  }

  /// 将远程子目录下载到本机 [localParentPath] 下，生成 `localParentPath/relativeDirName/`。
  @override
  Future<void> downloadRemoteDirectoryToLocal(
    String relativeDirName,
    String localParentPath,
  ) async {
    final client = _sftp;
    if (client == null) return;
    final remotePath = remoteJoin(_remoteCwd, relativeDirName);
    final localDest = p.join(localParentPath, relativeDirName);
    final plan = await sftp_transfer.planRemoteDirectoryDownload(
      sftp: client,
      remoteTreeRoot: remotePath,
      localTreeRoot: localDest,
      displayRootLabel: relativeDirName,
    );
    final taskIds = plan.map((e) => e.taskId).toSet();
    uploadTasks.appendTasks(
      plan
          .map(
            (e) => SftpUploadTaskView(
              id: e.taskId,
              label: e.displayLabel,
              totalBytes: e.sizeBytes,
              direction: SftpTransferDirection.download,
            ),
          )
          .toList(),
    );
    try {
      await sftp_transfer.executeDownloadPlan(
        sftp: client,
        plan: plan,
        hooks: _downloadHooks(taskIds),
      );
    } catch (e) {
      _failRemainingTasks(taskIds, e);
    }
  }

  SftpUploadProgressHooks _downloadHooks(Set<String> taskIds) {
    return SftpUploadProgressHooks(
      shouldCancelUpload: uploadTasks.isCancellationRequested,
      onFileStart: (path, String displayLabel, int totalBytes) =>
          uploadTasks.setUploading(path),
      onFileProgress: (path, up, _) => uploadTasks.progress(path, up),
      onFileEnd: (path, err) {
        if (err is SftpUserCancelled) {
          uploadTasks.removeCancelled(path);
          return;
        }
        if (err != null) {
          uploadTasks.fail(path, err);
        } else {
          uploadTasks.succeed(path);
        }
      },
    );
  }

  @override
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

  @override
  Future<void> writeRemoteFile(String relativeName, Uint8List bytes) async {
    final client = _sftp;
    if (client == null) return;
    final path = remoteJoin(_remoteCwd, relativeName);
    final file = await client.open(
      path,
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
    await refreshDirectory();
  }

  @override
  Future<int?> remoteMtime(String relativeName) async {
    final client = _sftp;
    if (client == null) return null;
    final path = remoteJoin(_remoteCwd, relativeName);
    final attrs = await client.stat(path);
    return attrs.modifyTime;
  }

  RemoteCommandQueue? _commandQueue;
  final Set<RemoteStream> _activeStreams = {};
  RemoteHostSnapshot? _lastSnapshot;
  DateTime? _lastSnapshotAt;

  RemoteCommandQueue get _cmdQueue {
    return _commandQueue ??= RemoteCommandQueue(
      () => (_connected && !dropped) ? _client : null,
      maxConcurrent: 2,
    );
  }

  /// 排队执行一次性命令（多窗口轮询共享，限制并发）。
  Future<String?> runQueued(
    String command, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    if (!_connected || dropped) return Future.value(null);
    return _cmdQueue.run(command, timeout: timeout);
  }

  /// 最近一次排队命令失败原因（供托盘 / UI 展示）。
  String? get lastRemoteCommandError => _cmdQueue.lastError;
  DateTime? get lastRemoteCommandErrorAt => _cmdQueue.lastErrorAt;

  /// 当前登记的本地端口转发（桌面转发管理器）。
  List<LocalPortForwarder> get desktopForwards =>
      List.unmodifiable(_desktopForwards);

  int get debugActiveStreamCount => _activeStreams.length;

  /// 与交互 shell 并行执行的非交互命令（用于底部状态栏等）。
  /// 内部走 [runQueued]，保留旧签名零回归。
  Future<String?> runRemoteForStatus(String command) => runQueued(command);

  /// 共享主机采样：短时间内复用缓存，降低监控/任务/托盘重复 exec。
  Future<RemoteHostSnapshot?> snapshot({
    Duration maxAge = const Duration(seconds: 3),
  }) async {
    final now = DateTime.now();
    final cached = _lastSnapshot;
    final at = _lastSnapshotAt;
    if (cached != null &&
        at != null &&
        now.difference(at) <= maxAge) {
      return cached;
    }
    final snap = await fetchRemoteHostSnapshot(this);
    if (snap != null) {
      _lastSnapshot = snap;
      _lastSnapshotAt = DateTime.now();
    }
    return snap;
  }

  /// 注册流式通道；掉线 teardown 时统一 [RemoteStream.stop]。
  void registerRemoteStream(RemoteStream stream) {
    _activeStreams.add(stream);
  }

  void unregisterRemoteStream(RemoteStream stream) {
    _activeStreams.remove(stream);
  }

  Future<RemoteStream> startRemoteStream(
    String command, {
    int maxLines = 5000,
  }) async {
    final stream = await RemoteStream.start(
      clientForDesktop,
      command: command,
      maxLines: maxLines,
    );
    registerRemoteStream(stream);
    return stream;
  }

  /// 取消订阅、关闭 shell / 桌面资源 / 传输会话。
  ///
  /// [keepTerminal] 为 `true` 时保留 [_terminal] 与 [_entries]，用于「掉线后保留
  /// 历史缓冲以供重连」的场景；为 `false`（[disconnect] 的对外语义）时彻底清空。
  Future<void> _teardownConnection({bool keepTerminal = false}) async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;

    try {
      _shell?.close();
    } catch (_) {}
    _shell = null;

    await _stopActiveStreams();
    _commandQueue?.clearPending();
    _lastSnapshot = null;
    _lastSnapshotAt = null;

    final gw = _browserGateway;
    _browserGateway = null;
    try {
      await gw?.stop();
    } catch (_) {}

    final forwards = List<LocalPortForwarder>.from(_desktopForwards);
    _desktopForwards.clear();
    for (final f in forwards) {
      try {
        await f.stop();
      } catch (_) {}
    }

    await _remoteSession.detach(keepNotify: false);

    _connected = false;
    if (!keepTerminal) {
      _terminal = null;
      _entries = [];
    }
  }

  Future<void> _stopActiveStreams() async {
    final streams = List<RemoteStream>.from(_activeStreams);
    _activeStreams.clear();
    for (final s in streams) {
      try {
        await s.stop();
      } catch (_) {}
    }
  }

  Future<void> disconnect() async {
    await _teardownConnection(keepTerminal: false);
    if (_sessionDisposed) return;
    uploadTasks.clear();
    notifyListeners();
  }

  /// 凭据错误后更新口令/密钥并在当前标签重连（不关闭标签）。
  Future<void> reconnectWithCredentials({
    required String password,
    String? privateKeyPem,
  }) async {
    if (_sessionDisposed || _connecting) return;
    _password = password;
    _privateKeyPem = privateKeyPem;
    _suggestCredentialSheetAfterFailure = false;
    await _teardownConnection(keepTerminal: false);
    if (_sessionDisposed) return;
    uploadTasks.clear();
    notifyListeners();
    await connect();
  }

  /// 主动重连（掉线后用户点击「重新连接」）。
  ///
  /// 在 dropped 态 [_connected]==false 且 [_connecting]==false，直接复用 [connect]：
  /// 后者会保留 [_terminal]、重建 shell/sftp 并重新挂上掉线监听。
  Future<void> reconnect() async {
    if (_connecting || _connected) return;
    if (_sessionDisposed) return;
    await connect();
  }

  /// [RemoteSession] 传输关闭后回调：client/sftp 已 detach，此处收尾 shell / 桌面资源。
  void _onRemoteTransportClosed(Object? error) {
    unawaited(_handleRemoteTransportClosed(error));
  }

  Future<void> _handleRemoteTransportClosed(Object? error) async {
    if (_sessionDisposed) return;
    debugPrint('SSH transport closed unexpectedly: $error');

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;

    try {
      _shell?.close();
    } catch (_) {}
    _shell = null;

    await _stopActiveStreams();
    _commandQueue?.clearPending();
    _lastSnapshot = null;
    _lastSnapshotAt = null;

    final gw = _browserGateway;
    _browserGateway = null;
    try {
      await gw?.stop();
    } catch (_) {}

    final forwards = List<LocalPortForwarder>.from(_desktopForwards);
    _desktopForwards.clear();
    for (final f in forwards) {
      try {
        await f.stop();
      } catch (_) {}
    }

    if (_sessionDisposed) return;
    _connected = false;
    _dropped = true;

    String message;
    try {
      final l10n = lookupAppLocalizations(Locale(settings.appLocaleCode));
      message = l10n.terminalDisconnected;
      if (error != null) {
        final detail = error.toString();
        if (detail.isNotEmpty) {
          message = '$message\n$detail';
        }
      }
    } catch (e, st) {
      debugPrint('build disconnect message failed: $e\n$st');
      message = error?.toString() ?? '';
    }
    _setError(message.isEmpty ? null : message);
    notifyListeners();
  }

  @override
  void dispose() {
    if (_sessionDisposed) return;
    _sessionDisposed = true;
    _remoteSession.onTransportClosed = null;
    _commandQueue?.dispose();
    _commandQueue = null;
    uploadTasks.dispose();
    unawaited(() async {
      await disconnect();
      _remoteSession.dispose();
    }());
    super.dispose();
  }
}

Future<String?> loadPrivateKeyFromPath(String? path) async {
  if (path == null || path.trim().isEmpty) return null;
  var pem = await readTextFile(path.trim());
  if (pem == null) return null;
  // UTF-8 BOM (common on Windows / Notepad) breaks dartssh2 PEM parsing.
  if (pem.isNotEmpty && pem.codeUnitAt(0) == 0xFEFF) {
    pem = pem.substring(1);
  }
  return pem;
}

bool looksLikeTextBytes(Uint8List data, {int sample = 4096}) {
  final n = data.length < sample ? data.length : sample;
  for (var i = 0; i < n; i++) {
    if (data[i] == 0) return false;
  }
  return true;
}
