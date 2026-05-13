import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import '../util/remote_paths.dart';

Future<void> uploadLocalPathToRemote({
  required SftpClient sftp,
  required String remoteCwd,
  required String localPath,
}) async {
  final t = FileSystemEntity.typeSync(localPath, followLinks: false);
  if (t == FileSystemEntityType.notFound) {
    throw StateError('本地路径不存在: $localPath');
  }
  if (t == FileSystemEntityType.file) {
    await _uploadOneFile(sftp, remoteCwd, localPath);
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
    await _uploadDirectoryRecursive(sftp, targetRemote, localPath);
    return;
  }
  throw StateError('不支持的本地类型: $localPath');
}

Future<void> _uploadDirectoryRecursive(SftpClient sftp, String remoteDir, String localDir) async {
  await for (final entity in Directory(localDir).list(followLinks: false)) {
    final base = p.basename(entity.path);
    if (base == '.' || base == '..') continue;
    final remoteChild = remoteJoin(remoteDir, base);
    if (entity is File) {
      await _uploadOneFile(sftp, remoteDir, entity.path);
    } else if (entity is Directory) {
      try {
        await sftp.mkdir(remoteChild);
      } catch (_) {}
      await _uploadDirectoryRecursive(sftp, remoteChild, entity.path);
    }
  }
}

Future<void> _uploadOneFile(SftpClient sftp, String remoteParentDir, String localFilePath) async {
  final name = p.basename(localFilePath);
  final remotePath = remoteJoin(remoteParentDir, name);
  final bytes = await File(localFilePath).readAsBytes();
  final file = await sftp.open(
    remotePath,
    mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
  );
  try {
    await file.writeBytes(bytes);
  } finally {
    await file.close();
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
