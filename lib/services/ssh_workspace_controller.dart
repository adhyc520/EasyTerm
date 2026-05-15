import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart'
    show
        ChangeNotifier,
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
import 'sftp_fs_transfer.dart' as sftp_transfer;
import 'sftp_planned_upload.dart';
import 'sftp_upload_progress_hooks.dart';
import 'sftp_upload_task_list.dart';
import 'workbench_settings_store.dart';

const int kMaxEditorBytes = 512 * 1024;

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

  String get remoteCwd => _remoteCwd;
  List<SftpName> get entries => List.unmodifiable(_entries);
  String? get error => _error;
  bool get loadingDir => _loadingDir;
  bool get connecting => _connecting;
  bool get connected => _connected;

  SftpClient? get sftp => _sftp;

  /// 拖曳上传任务列表（仅监听本对象可避免整页文件树随字节进度重建）。
  final SftpUploadTaskList uploadTasks = SftpUploadTaskList();

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
          identities = SSHKeyPair.fromPem(
            privateKeyPem!,
            password.isEmpty ? null : password,
          );
        }

        // 公钥失败时仍应尝试密码；部分服务端只开启 keyboard-interactive（未开启 password 方法）。
        final hasPassword = password.isNotEmpty;
        _client = SSHClient(
          socket,
          username: username,
          identities: identities,
          onPasswordRequest: hasPassword ? () async => password : null,
          onUserInfoRequest: hasPassword
              ? (req) async => List<String>.filled(req.prompts.length, password)
              : null,
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
        debugPrint(
          'SSH connect attempt ${attempt + 1}/$totalAttempts: $e\n$st',
        );
        await disconnect();
        if (attempt < totalAttempts - 1) {
          await Future<void>.delayed(
            Duration(seconds: settings.retryIntervalSec),
          );
        }
      }
    }

    if (!_connected && lastError != null) {
      final hadPrivateKey =
          privateKeyPem != null && privateKeyPem!.trim().isNotEmpty;
      final l10n = lookupAppLocalizations(Locale(settings.appLocaleCode));
      _setError(
        formatSshConnectionError(
          lastError,
          l10n: l10n,
          hadPrivateKey: hadPrivateKey,
          passwordProvided: password.isNotEmpty,
        ),
      );
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

    _stdoutSub = session.stdout.listen((data) {
      term.write(utf8.decode(data, allowMalformed: true));
    }, onError: (e) => debugPrint('stdout: $e'));

    _stderrSub = session.stderr.listen((data) {
      term.write(utf8.decode(data, allowMalformed: true));
    }, onError: (e) => debugPrint('stderr: $e'));
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
        taskViews.add(SftpUploadTaskView(
          id: e.localPath,
          label: e.displayLabel,
          totalBytes: e.sizeBytes,
          direction: SftpTransferDirection.upload,
        ));
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
      if (taskIds.contains(row.id) &&
          row.state != SftpUploadRowState.failed) {
        uploadTasks.fail(row.id, error);
      }
    }
  }

  /// 检测当前远程目录下是否已有与 [localPath] 最后一级同名的项。
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
  Future<void> downloadRemoteFileToLocalPath(
    String relativeName,
    String localFilePath,
  ) async {
    final client = _sftp;
    if (client == null) return;
    final remotePath = remoteJoin(_remoteCwd, relativeName);
    final plan = await sftp_transfer.planDownloadSingleFile(
      sftp: client,
      remotePath: remotePath,
      localPath: localFilePath,
      displayLabel: relativeName,
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
  Future<String> materializeRemoteFileToTempForDrag(String relativeName) async {
    final client = _sftp;
    if (client == null) {
      throw StateError('SFTP not connected');
    }
    final dir = await getTemporaryDirectory();
    final base = remoteBasename(relativeName);
    final path = p.join(
      dir.path,
      'terminall_drag_${DateTime.now().microsecondsSinceEpoch}_$base',
    );
    await downloadRemoteFileToLocalPath(relativeName, path);
    return path;
  }

  /// 将远程目录下载到临时目录，用于拖出目录到 Finder / 资源管理器。
  /// 使用低层 downloadRemoteTreeToLocalPath（不走任务队列），避免阻塞。
  Future<String> materializeRemoteDirectoryToTempForDrag(
    String relativeName, {
    bool Function()? shouldAbort,
  }) async {
    final client = _sftp;
    if (client == null) {
      throw StateError('SFTP not connected');
    }
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final tempParent = p.join(dir.path, 'terminall_dragdir_$stamp');
    final remotePath = remoteJoin(_remoteCwd, relativeName);
    final localDest = p.join(tempParent, remoteBasename(relativeName));
    await sftp_transfer.downloadRemoteTreeToLocalPath(
      sftp: client,
      remotePath: remotePath,
      localDirPath: localDest,
      shouldAbort: shouldAbort,
    );
    if (shouldAbort?.call() == true) {
      throw const SftpUserCancelled();
    }
    return localDest;
  }

  /// 将远程文件按字节流写入系统拖放提供的 [sink]（虚拟文件导出）。
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

    final remotePath = remoteJoin(_remoteCwd, relativeName);
    SftpFile? file;
    var cancelled = false;
    void onCancel() => cancelled = true;
    progress.onCancel.addListener(onCancel);
    var terminal = false;
    var sinkClosed = false;
    void closeDragSinkOnce() {
      if (sinkClosed) return;
      try {
        sink.close();
        sinkClosed = true;
      } catch (_) {}
    }

    try {
      final opened = await client.open(remotePath, mode: SftpFileOpenMode.read);
      file = opened;
      if (fileSizeBytes <= 0) {
        uploadTasks.progress(taskId, 0);
        if (cancelled || uploadTasks.isCancellationRequested(taskId)) {
          uploadTasks.removeCancelled(taskId);
        } else {
          closeDragSinkOnce();
          uploadTasks.succeed(taskId);
        }
        terminal = true;
        return;
      }
      var offset = 0;
      while (offset < fileSizeBytes) {
        if (cancelled || uploadTasks.isCancellationRequested(taskId)) {
          cancelled = true;
          break;
        }
        final take = math.min(256 * 1024, fileSizeBytes - offset);
        final chunk = await opened.readBytes(length: take, offset: offset);
        if (chunk.isEmpty) {
          break;
        }
        sink.add(chunk);
        offset += chunk.length;
        progress.updateProgress(offset / fileSizeBytes);
        uploadTasks.progress(taskId, offset);
      }
      if (cancelled || uploadTasks.isCancellationRequested(taskId)) {
        cancelled = true;
      } else {
        closeDragSinkOnce();
        uploadTasks.succeed(taskId);
        terminal = true;
      }
    } catch (e, st) {
      debugPrint('streamRemoteFileIntoDragSink: $e\n$st');
      uploadTasks.fail(taskId, e);
      terminal = true;
      try {
        final errResult = sink.addError(e, st);
        if (errResult is Future<void>) await errResult;
      } catch (_) {
        /* sink may already be torn down */
      }
    } finally {
      progress.onCancel.removeListener(onCancel);
      await file?.close();
      if (!sinkClosed) {
        closeDragSinkOnce();
      }
      if (!terminal) {
        if (cancelled || uploadTasks.isCancellationRequested(taskId)) {
          uploadTasks.removeCancelled(taskId);
        }
      }
    }
  }

  /// 将远程子目录下载到本机 [localParentPath] 下，生成 `localParentPath/relativeDirName/`。
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
    uploadTasks.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    uploadTasks.dispose();
    unawaited(disconnect());
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
