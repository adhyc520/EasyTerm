import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import '../util/remote_paths.dart';
import 'sftp_planned_download.dart';
import 'sftp_planned_upload.dart';
import 'sftp_upload_progress_hooks.dart';

const int _kSftpChunkBytes = 256 * 1024;

/// 单文件下载时同时在飞的 SFTP 读请求上限。
///
/// dartssh2 默认为 64，叠加 [_kSftpChunkBytes] 256 KB 时最多有 16 MB 数据“躺在
/// SSH 通道与服务端读队列里”。一旦用户在传输队列里 × 取消，OpenSSH-style
/// 的 sftp-server 仍会按收到顺序把这堆 read 全部处理完才轮到新到的 `stat` /
/// `open`（即「切换目录」「再次拖出」依赖的请求），导致取消后明显的卡顿。
///
/// 把上限收紧到 8 → 至多 ~2 MB 在飞，足够在常见网络下保持下载吞吐，又把取消
/// 后让出 SFTP 通道的延迟压到可忽略的量级。
const int _kSftpDownloadMaxPendingRequests = 8;

/// `executeDownloadPlan` 默认并发下载的文件数。
///
/// 对「目录里有几十上百个小文件」的拖出场景而言，每个文件 `open` + `close` 都是
/// 至少 2 个 RTT；逐个串行下载即使每文件只要 100 ms，攒到 50 个就要 5 s ——
/// 远超用户能耐心等的「拖动手势保持时间」，Finder/Explorer 在用户松手那一刻就
/// 只能拷到一个仍然几乎空白的临时目录，也就是「拖出目录有时不完整」的根因。
///
/// 把 4 个文件同时在飞，能让小文件主导场景的连接开销摊薄 4 倍；与上面的
/// [_kSftpDownloadMaxPendingRequests] 叠加后单通道在飞数据最多 4 × 2 MB = 8 MB，
/// 仍在 dartssh2 内置 `downloadTo` 8 MB 缺省值的同一档位，不会让 SSH 通道窗口
/// 真正吃紧。
const int _kSftpDownloadDefaultConcurrency = 4;

// ─── 通用工具 ────────────────────────────────────────────────────────────────

String _labelAnchor(String localPath) {
  final t = FileSystemEntity.typeSync(localPath, followLinks: false);
  if (t == FileSystemEntityType.file) {
    return p.normalize(p.dirname(localPath));
  }
  return p.normalize(localPath);
}

String _displayLabelForFile(String localFilePath, String anchor) {
  final rel = p.relative(p.normalize(localFilePath), from: anchor);
  if (rel == '.') return p.basename(localFilePath);
  return rel;
}

/// 先关闭再删，否则 Windows/macOS 上句柄未释放时无法删除。
Future<void> _closeIosinkQuiet(IOSink? sink) async {
  if (sink == null) return;
  try {
    await sink.flush();
  } catch (_) {}
  try {
    await sink.close();
  } catch (_) {}
}

void deleteLocalFileQuiet(String localFilePath) {
  try {
    File(localFilePath).deleteSync();
  } catch (_) {}
}

/// 删除整棵本地目录（用于取消目录拖出后清理临时副本）。
void deleteLocalDirectoryQuiet(String localDirPath) {
  try {
    final dir = Directory(localDirPath);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  } catch (_) {}
}

/// 创建本地目录（包含中间目录），用于空远端目录的拖出占位。
Future<void> ensureLocalDirectoryExists(String localDirPath) async {
  await Directory(localDirPath).create(recursive: true);
}

/// 文件是否存在（用于物化拖出后侦测「下载被取消」状态）。
bool localFileExistsSync(String path) {
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}

// ─── 远端冲突探测与覆盖删除 ───────────────────────────────────────────────────

/// 探测当前远程目录下是否已有与本地 [localPath] 最后一级同名的项。
Future<SftpRemoteUploadConflict> inspectUploadConflict({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
}) async {
  final name = p.basename(localPath);
  final remotePath = remoteJoin(remoteCwd, name);
  final localType = FileSystemEntity.typeSync(localPath, followLinks: false);
  final localIsDir = localType == FileSystemEntityType.directory;
  try {
    final attrs = await sftp.stat(remotePath);
    if (attrs.isDirectory != localIsDir) {
      return SftpRemoteUploadConflict.typeMismatch;
    }
    return SftpRemoteUploadConflict.existsReplaceable;
  } on SftpStatusError catch (e) {
    if (e.code == SftpStatusCode.noSuchFile) {
      return SftpRemoteUploadConflict.none;
    }
    rethrow;
  }
}

/// 递归删除远程文件或目录（用于覆盖上传前清空）。
Future<void> removeRemotePathRecursive({
  required SftpClient sftp,
  required String remotePath,
}) async {
  final attrs = await sftp.stat(remotePath);
  if (attrs.isDirectory) {
    final names = await sftp.listdir(remotePath);
    for (final n in names) {
      if (n.filename == '.' || n.filename == '..') continue;
      await removeRemotePathRecursive(
        sftp: sftp,
        remotePath: remoteJoin(remotePath, n.filename),
      );
    }
    await sftp.rmdir(remotePath);
  } else {
    await sftp.remove(remotePath);
  }
}

Future<void> _ensureRemoteParentChainExists(
  SftpClient sftp,
  String remoteDirAbs,
) async {
  if (remoteDirAbs.isEmpty || remoteDirAbs == '/') return;
  try {
    final st = await sftp.stat(remoteDirAbs);
    if (!st.isDirectory) {
      throw StateError('远程路径不是目录: $remoteDirAbs');
    }
    return;
  } on SftpStatusError catch (e) {
    if (e.code != SftpStatusCode.noSuchFile) rethrow;
  }
  final parent = remoteDirname(remoteDirAbs);
  await _ensureRemoteParentChainExists(sftp, parent);
  try {
    await sftp.mkdir(remoteDirAbs);
  } catch (_) {}
}

// ─── 本地→远端：扫描与执行 ────────────────────────────────────────────────────

Future<List<SftpPlannedUploadFile>> planLocalUpload({
  required String remoteCwd,
  required String localPath,
}) async {
  final anchor = _labelAnchor(localPath);
  final t = FileSystemEntity.typeSync(localPath, followLinks: false);
  if (t == FileSystemEntityType.notFound) {
    throw StateError('本地路径不存在: $localPath');
  }
  if (t == FileSystemEntityType.file) {
    final file = File(localPath);
    final size = await file.length();
    return [
      SftpPlannedUploadFile(
        localPath: p.normalize(localPath),
        displayLabel: _displayLabelForFile(localPath, anchor),
        remoteParentDir: remoteCwd,
        sizeBytes: size,
      ),
    ];
  }
  if (t == FileSystemEntityType.directory) {
    final out = <SftpPlannedUploadFile>[];
    final name = p.basename(localPath);
    final remoteRoot = remoteJoin(remoteCwd, name);
    await _planDirectoryRecursive(
      localDir: p.normalize(localPath),
      remoteDir: remoteRoot,
      labelAnchor: anchor,
      out: out,
    );
    return out;
  }
  throw StateError('不支持的本地类型: $localPath');
}

Future<void> _planDirectoryRecursive({
  required String localDir,
  required String remoteDir,
  required String labelAnchor,
  required List<SftpPlannedUploadFile> out,
}) async {
  await for (final entity in Directory(localDir).list(followLinks: false)) {
    final base = p.basename(entity.path);
    if (base == '.' || base == '..') continue;
    if (entity is File) {
      final size = await entity.length();
      out.add(
        SftpPlannedUploadFile(
          localPath: entity.path,
          displayLabel: _displayLabelForFile(entity.path, labelAnchor),
          remoteParentDir: remoteDir,
          sizeBytes: size,
        ),
      );
    } else if (entity is Directory) {
      final remoteChild = remoteJoin(remoteDir, base);
      await _planDirectoryRecursive(
        localDir: entity.path,
        remoteDir: remoteChild,
        labelAnchor: labelAnchor,
        out: out,
      );
    }
  }
}

Future<void> uploadLocalPathToRemote({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
  SftpUploadProgressHooks? hooks,
}) async {
  final plan = await planLocalUpload(remoteCwd: remoteCwd, localPath: localPath);
  await uploadPlannedFiles(
    sftp: sftp,
    remoteCwd: remoteCwd,
    localPath: localPath,
    plan: plan,
    hooks: hooks,
  );
}

/// 执行 [planLocalUpload] 生成的计划（用于先填充 UI 队列再上传，避免重复扫描）。
Future<void> uploadPlannedFiles({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
  required List<SftpPlannedUploadFile> plan,
  SftpUploadProgressHooks? hooks,
}) async {
  if (plan.isEmpty) {
    // 空目录也要在远端建立同名目录，否则用户看不到任何东西。
    final t = FileSystemEntity.typeSync(localPath, followLinks: false);
    if (t == FileSystemEntityType.directory) {
      final name = p.basename(localPath);
      final targetRemote = remoteJoin(remoteCwd, name);
      try {
        await sftp.mkdir(targetRemote);
      } catch (_) {}
    }
    return;
  }
  for (final entry in plan) {
    if (hooks?.shouldCancelUpload?.call(entry.localPath) == true) {
      // 必须主动 emit onFileEnd(SftpUserCancelled)，否则 `_cancelledIds` 里
      // 「全部取消」时为 pending 行写入的 id 会变成孤儿（`removeCancelled` 没人
      // 调），下次若拼出同名 id 的 entry 还会被错误地视作已取消。
      hooks?.onFileEnd?.call(entry.localPath, const SftpUserCancelled());
      continue;
    }
    await _ensureRemoteParentChainExists(sftp, entry.remoteParentDir);
    await _uploadOneFile(
      sftp,
      entry.remoteParentDir,
      entry.localPath,
      displayLabel: entry.displayLabel,
      hooks: hooks,
    );
  }
}

Future<void> _uploadOneFile(
  SftpClient sftp,
  String remoteParentDir,
  String localFilePath, {
  required String displayLabel,
  SftpUploadProgressHooks? hooks,
}) async {
  if (hooks?.shouldCancelUpload?.call(localFilePath) == true) {
    hooks?.onFileEnd?.call(localFilePath, const SftpUserCancelled());
    return;
  }

  final name = p.basename(localFilePath);
  final remotePath = remoteJoin(remoteParentDir, name);
  final file = File(localFilePath);
  final total = await file.length();
  hooks?.onFileStart?.call(localFilePath, displayLabel, total);

  if (hooks?.shouldCancelUpload?.call(localFilePath) == true) {
    hooks?.onFileEnd?.call(localFilePath, const SftpUserCancelled());
    return;
  }

  late final SftpFile out;
  try {
    out = await sftp.open(
      remotePath,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
  } catch (e, st) {
    hooks?.onFileEnd?.call(localFilePath, e);
    Error.throwWithStackTrace(e, st);
  }

  var stripRemoteIncomplete = false;
  try {
    if (total == 0) {
      hooks?.onFileProgress?.call(localFilePath, 0, 0);
      if (hooks?.shouldCancelUpload?.call(localFilePath) == true) {
        stripRemoteIncomplete = true;
        hooks?.onFileEnd?.call(localFilePath, const SftpUserCancelled());
        return;
      }
    } else {
      var uploaded = 0;
      await for (final chunk in file.openRead(0, total)) {
        if (hooks?.shouldCancelUpload?.call(localFilePath) == true) {
          stripRemoteIncomplete = true;
          hooks?.onFileEnd?.call(localFilePath, const SftpUserCancelled());
          return;
        }
        final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        await out.writeBytes(data, offset: uploaded);
        uploaded += data.length;
        hooks?.onFileProgress?.call(localFilePath, uploaded, total);
      }
    }
    if (hooks?.shouldCancelUpload?.call(localFilePath) == true) {
      stripRemoteIncomplete = true;
      hooks?.onFileEnd?.call(localFilePath, const SftpUserCancelled());
      return;
    }
    hooks?.onFileEnd?.call(localFilePath, null);
  } catch (e, st) {
    hooks?.onFileEnd?.call(localFilePath, e);
    Error.throwWithStackTrace(e, st);
  } finally {
    try {
      await out.close();
    } catch (_) {}
    if (stripRemoteIncomplete) {
      try {
        await sftp.remove(remotePath);
      } catch (_) {}
    }
  }
}

// ─── 远端→本地：扫描与执行 ────────────────────────────────────────────────────

Future<List<SftpPlannedDownloadFile>> planDownloadSingleFile({
  required SftpClient sftp,
  required String remotePath,
  required String localPath,
  required String displayLabel,
}) async {
  final stat = await sftp.stat(remotePath);
  if (!stat.isFile) {
    throw StateError('远程路径不是文件: $remotePath');
  }
  final size = stat.size ?? 0;
  return [
    SftpPlannedDownloadFile(
      taskId: 'dl_${DateTime.now().microsecondsSinceEpoch}_${p.basename(displayLabel)}',
      displayLabel: displayLabel,
      remotePath: remotePath,
      localPath: localPath,
      sizeBytes: size,
    ),
  ];
}

Future<List<SftpPlannedDownloadFile>> planRemoteDirectoryDownload({
  required SftpClient sftp,
  required String remoteTreeRoot,
  required String localTreeRoot,
  required String displayRootLabel,
  String? taskIdPrefix,
  bool Function()? shouldAbort,
  void Function(SftpPlannedDownloadFile entry)? onEntryDiscovered,
}) async {
  final out = <SftpPlannedDownloadFile>[];
  final idPrefix = taskIdPrefix ??
      'dl_${DateTime.now().microsecondsSinceEpoch}_${displayRootLabel.hashCode}';
  await _planRemoteDownloadRecursive(
    sftp: sftp,
    remoteDir: remoteTreeRoot,
    localDir: localTreeRoot,
    displayPrefix: displayRootLabel,
    taskIdPrefix: idPrefix,
    shouldAbort: shouldAbort,
    out: out,
    onEntryDiscovered: onEntryDiscovered,
  );
  return out;
}

Future<void> _planRemoteDownloadRecursive({
  required SftpClient sftp,
  required String remoteDir,
  required String localDir,
  required String displayPrefix,
  required String taskIdPrefix,
  required bool Function()? shouldAbort,
  required List<SftpPlannedDownloadFile> out,
  void Function(SftpPlannedDownloadFile entry)? onEntryDiscovered,
}) async {
  if (shouldAbort?.call() == true) throw const SftpUserCancelled();
  await Directory(localDir).create(recursive: true);
  final names = await sftp.listdir(remoteDir);
  for (final n in names) {
    if (shouldAbort?.call() == true) throw const SftpUserCancelled();
    if (n.filename == '.' || n.filename == '..') continue;
    final rChild = remoteJoin(remoteDir, n.filename);
    final lChild = p.join(localDir, n.filename);
    if (n.attr.isDirectory) {
      final childDisplay = '$displayPrefix/${n.filename}';
      await _planRemoteDownloadRecursive(
        sftp: sftp,
        remoteDir: rChild,
        localDir: lChild,
        displayPrefix: childDisplay,
        taskIdPrefix: taskIdPrefix,
        shouldAbort: shouldAbort,
        out: out,
        onEntryDiscovered: onEntryDiscovered,
      );
    } else {
      // SFTP v3 的 READDIR 响应已经带回每个条目的 attrs（含 size），再单独发一次
      // SSH_FXP_STAT 等价于 N 次额外往返。`_downloadOneFileWithHooks` 在打开文件
      // 后会再用 `inFile.stat()` 校准实际大小，所以这里的 size 偏差不影响下载
      // 字节数本身，只影响进度条总长度。这一步是「拖出目录后用户能多快开始看到
      // 文件流入」的最大瓶颈，必须省掉。
      final size = n.attr.size ?? 0;
      final entry = SftpPlannedDownloadFile(
        taskId: '${taskIdPrefix}_${out.length}',
        displayLabel: '$displayPrefix/${n.filename}',
        remotePath: rChild,
        localPath: lChild,
        sizeBytes: size,
      );
      out.add(entry);
      onEntryDiscovered?.call(entry);
    }
  }
}

Future<void> executeDownloadPlan({
  required SftpClient sftp,
  required List<SftpPlannedDownloadFile> plan,
  SftpUploadProgressHooks? hooks,
  int concurrency = _kSftpDownloadDefaultConcurrency,
}) async {
  if (plan.isEmpty) return;
  final workers = concurrency < 1
      ? 1
      : (concurrency > plan.length ? plan.length : concurrency);

  // 共享游标：Dart 单线程模型下 `nextIndex++` 在两个 await 之间是原子的，
  // 因此多个 worker 可以安全地并发抢任务。
  var nextIndex = 0;

  Future<void> worker() async {
    while (true) {
      final i = nextIndex++;
      if (i >= plan.length) return;
      final entry = plan[i];
      if (hooks?.shouldCancelUpload?.call(entry.taskId) == true) {
        hooks?.onFileEnd?.call(entry.taskId, const SftpUserCancelled());
        continue;
      }
      try {
        await Directory(p.dirname(entry.localPath)).create(recursive: true);
        await _downloadOneFileWithHooks(
          sftp: sftp,
          remotePath: entry.remotePath,
          localPath: entry.localPath,
          taskId: entry.taskId,
          displayLabel: entry.displayLabel,
          plannedSize: entry.sizeBytes,
          hooks: hooks,
        );
      } catch (_) {
        // `_downloadOneFileWithHooks` 已经把错误通过 hooks.onFileEnd 标到了对应
        // 任务行；这里吞掉异常是为了让兄弟 worker 继续处理后续文件，避免一个文件
        // 失败把整个目录的剩余文件都连坐 `_failRemainingTasks` 标成失败。
      }
    }
  }

  await Future.wait(List.generate(workers, (_) => worker()));
}

Future<void> _downloadOneFileWithHooks({
  required SftpClient sftp,
  required String remotePath,
  required String localPath,
  required String taskId,
  required String displayLabel,
  required int plannedSize,
  SftpUploadProgressHooks? hooks,
}) async {
  if (hooks?.shouldCancelUpload?.call(taskId) == true) {
    hooks?.onFileEnd?.call(taskId, const SftpUserCancelled());
    return;
  }

  late final SftpFile inFile;
  try {
    inFile = await sftp.open(remotePath, mode: SftpFileOpenMode.read);
  } catch (e, st) {
    hooks?.onFileEnd?.call(taskId, e);
    Error.throwWithStackTrace(e, st);
  }

  // 规划阶段已经从 listdir 的 attrs 拿到 size，再发一次 SSH_FXP_FSTAT 等于每个
  // 文件多一个 RTT —— 对「目录里全是小文件」的场景就是 N 个白白的往返。这里
  // 仅在 plannedSize <= 0 时回退到 fstat（兼容某些 SFTP 服务在 readdir 响应里
  // 不带 size 的实现）。
  int total = plannedSize;
  if (total <= 0) {
    try {
      final st = await inFile.stat();
      total = st.size ?? 0;
    } catch (e, st) {
      await inFile.close();
      hooks?.onFileEnd?.call(taskId, e);
      Error.throwWithStackTrace(e, st);
    }
  }

  try {
    hooks?.onFileStart?.call(taskId, displayLabel, total);
    if (hooks?.shouldCancelUpload?.call(taskId) == true) {
      hooks?.onFileEnd?.call(taskId, const SftpUserCancelled());
      return;
    }

    IOSink? outSink;
    var userCancelled = false;
    try {
      outSink = File(localPath).openWrite();
      if (total <= 0) {
        hooks?.onFileProgress?.call(taskId, 0, 0);
        if (hooks?.shouldCancelUpload?.call(taskId) == true) {
          userCancelled = true;
          hooks?.onFileEnd?.call(taskId, const SftpUserCancelled());
        }
      } else {
        var done = 0;
        await for (final chunk in inFile.read(
          length: total,
          offset: 0,
          chunkSize: _kSftpChunkBytes,
          maxPendingRequests: _kSftpDownloadMaxPendingRequests,
        )) {
          if (hooks?.shouldCancelUpload?.call(taskId) == true) {
            userCancelled = true;
            hooks?.onFileEnd?.call(taskId, const SftpUserCancelled());
            break;
          }
          outSink.add(chunk);
          done += chunk.length;
          hooks?.onFileProgress?.call(taskId, done, total);
        }
        if (!userCancelled &&
            hooks?.shouldCancelUpload?.call(taskId) == true) {
          userCancelled = true;
          hooks?.onFileEnd?.call(taskId, const SftpUserCancelled());
        }
      }
    } finally {
      await _closeIosinkQuiet(outSink);
    }
    if (userCancelled) {
      deleteLocalFileQuiet(localPath);
      return;
    }
    hooks?.onFileEnd?.call(taskId, null);
  } catch (e, st) {
    deleteLocalFileQuiet(localPath);
    hooks?.onFileEnd?.call(taskId, e);
    Error.throwWithStackTrace(e, st);
  } finally {
    try {
      await inFile.close();
    } catch (_) {}
  }
}

Future<void> saveRemoteFileToLocalPath({
  required SftpClient sftp,
  required String remoteCwd,
  required String relativeName,
  required String localFilePath,
}) async {
  final remotePath = remoteJoin(remoteCwd, relativeName);
  final sink = File(localFilePath).openWrite();
  await sftp.download(remotePath, sink, closeDestination: true);
}
