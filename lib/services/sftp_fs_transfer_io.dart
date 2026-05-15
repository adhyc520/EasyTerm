import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import '../util/remote_paths.dart';
import 'sftp_planned_download.dart';
import 'sftp_planned_upload.dart';
import 'sftp_upload_progress_hooks.dart';

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

Future<void> _ensureRemoteParentChainExists(SftpClient sftp, String remoteDirAbs) async {
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
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
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
}) async {
  final out = <SftpPlannedDownloadFile>[];
  await _planRemoteDownloadRecursive(
    sftp: sftp,
    remoteDir: remoteTreeRoot,
    localDir: localTreeRoot,
    displayPrefix: displayRootLabel,
    out: out,
  );
  return out;
}

Future<void> _planRemoteDownloadRecursive({
  required SftpClient sftp,
  required String remoteDir,
  required String localDir,
  required String displayPrefix,
  required List<SftpPlannedDownloadFile> out,
}) async {
  await Directory(localDir).create(recursive: true);
  final names = await sftp.listdir(remoteDir);
  for (final n in names) {
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
        out: out,
      );
    } else {
      final st = await sftp.stat(rChild);
      final size = st.size ?? 0;
      out.add(
        SftpPlannedDownloadFile(
          taskId: 'dl_${out.length}_${DateTime.now().microsecondsSinceEpoch}',
          displayLabel: '$displayPrefix/${n.filename}',
          remotePath: rChild,
          localPath: lChild,
          sizeBytes: size,
        ),
      );
    }
  }
}

Future<void> executeDownloadPlan({
  required SftpClient sftp,
  required List<SftpPlannedDownloadFile> plan,
  SftpUploadProgressHooks? hooks,
}) async {
  for (final entry in plan) {
    if (hooks?.shouldCancelUpload?.call(entry.taskId) == true) {
      continue;
    }
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
  }
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

  final int total;
  try {
    final st = await inFile.stat();
    total = plannedSize > 0 ? plannedSize : (st.size ?? 0);
  } catch (e, st) {
    await inFile.close();
    hooks?.onFileEnd?.call(taskId, e);
    Error.throwWithStackTrace(e, st);
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
        await for (final chunk in inFile.read(length: total, offset: 0, chunkSize: 256 * 1024)) {
          if (hooks?.shouldCancelUpload?.call(taskId) == true) {
            userCancelled = true;
            hooks?.onFileEnd?.call(taskId, const SftpUserCancelled());
            break;
          }
          outSink.add(chunk);
          done += chunk.length;
          hooks?.onFileProgress?.call(taskId, done, total);
        }
        if (!userCancelled && hooks?.shouldCancelUpload?.call(taskId) == true) {
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

Future<void> downloadRemoteTreeToLocalPath({
  required SftpClient sftp,
  required String remotePath,
  required String localDirPath,
  bool Function()? shouldAbort,
}) async {
  final label = p.basename(remotePath.replaceAll('\\', '/'));
  final plan = await planRemoteDirectoryDownload(
    sftp: sftp,
    remoteTreeRoot: remotePath,
    localTreeRoot: localDirPath,
    displayRootLabel: label,
  );
  await executeDownloadPlan(
    sftp: sftp,
    plan: plan,
    hooks: shouldAbort == null
        ? null
        : SftpUploadProgressHooks(
            shouldCancelUpload: (_) => shouldAbort(),
          ),
  );
  if (shouldAbort?.call() == true) {
    throw const SftpUserCancelled();
  }
}

void deleteLocalFileQuiet(String localFilePath) {
  try {
    File(localFilePath).deleteSync();
  } catch (_) {}
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
