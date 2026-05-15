import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import '../util/remote_paths.dart';
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

Future<void> uploadLocalPathToRemote({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
  SftpUploadProgressHooks? hooks,
}) async {
  final anchor = _labelAnchor(localPath);
  final t = FileSystemEntity.typeSync(localPath, followLinks: false);
  if (t == FileSystemEntityType.notFound) {
    throw StateError('本地路径不存在: $localPath');
  }
  if (t == FileSystemEntityType.file) {
    await _uploadOneFile(
      sftp,
      remoteCwd,
      localPath,
      displayLabel: _displayLabelForFile(localPath, anchor),
      hooks: hooks,
    );
    return;
  }
  if (t == FileSystemEntityType.directory) {
    final name = p.basename(localPath);
    final targetRemote = remoteJoin(remoteCwd, name);
    try {
      await sftp.mkdir(targetRemote);
    } catch (_) {
      // 目录已存在时继续写入内容
    }
    await _uploadDirectoryRecursive(
      sftp,
      targetRemote,
      localPath,
      labelAnchor: anchor,
      hooks: hooks,
    );
    return;
  }
  throw StateError('不支持的本地类型: $localPath');
}

Future<void> _uploadDirectoryRecursive(
  SftpClient sftp,
  String remoteDir,
  String localDir, {
  required String labelAnchor,
  SftpUploadProgressHooks? hooks,
}) async {
  await for (final entity in Directory(localDir).list(followLinks: false)) {
    final base = p.basename(entity.path);
    if (base == '.' || base == '..') continue;
    final remoteChild = remoteJoin(remoteDir, base);
    if (entity is File) {
      await _uploadOneFile(
        sftp,
        remoteDir,
        entity.path,
        displayLabel: _displayLabelForFile(entity.path, labelAnchor),
        hooks: hooks,
      );
    } else if (entity is Directory) {
      try {
        await sftp.mkdir(remoteChild);
      } catch (_) {}
      await _uploadDirectoryRecursive(
        sftp,
        remoteChild,
        entity.path,
        labelAnchor: labelAnchor,
        hooks: hooks,
      );
    }
  }
}

Future<void> _uploadOneFile(
  SftpClient sftp,
  String remoteParentDir,
  String localFilePath, {
  required String displayLabel,
  SftpUploadProgressHooks? hooks,
}) async {
  final name = p.basename(localFilePath);
  final remotePath = remoteJoin(remoteParentDir, name);
  final file = File(localFilePath);
  final total = await file.length();
  hooks?.onFileStart?.call(localFilePath, displayLabel, total);

  late final SftpFile remoteFile;
  try {
    remoteFile = await sftp.open(
      remotePath,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
  } catch (e, st) {
    hooks?.onFileEnd?.call(localFilePath, e);
    Error.throwWithStackTrace(e, st);
  }

  try {
    if (total == 0) {
      hooks?.onFileProgress?.call(localFilePath, 0, 0);
    } else {
      var uploaded = 0;
      await for (final chunk in file.openRead(0, total)) {
        final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        await remoteFile.writeBytes(data, offset: uploaded);
        uploaded += data.length;
        hooks?.onFileProgress?.call(localFilePath, uploaded, total);
      }
    }
    hooks?.onFileEnd?.call(localFilePath, null);
  } catch (e, st) {
    hooks?.onFileEnd?.call(localFilePath, e);
    Error.throwWithStackTrace(e, st);
  } finally {
    await remoteFile.close();
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
}) async {
  await Directory(localDirPath).create(recursive: true);
  final names = await sftp.listdir(remotePath);
  for (final n in names) {
    if (n.filename == '.' || n.filename == '..') continue;
    final rChild = remoteJoin(remotePath, n.filename);
    final lChild = p.join(localDirPath, n.filename);
    if (n.attr.isDirectory) {
      await downloadRemoteTreeToLocalPath(sftp: sftp, remotePath: rChild, localDirPath: lChild);
    } else {
      final sink = File(lChild).openWrite();
      await sftp.download(rChild, sink, closeDestination: true);
    }
  }
}
