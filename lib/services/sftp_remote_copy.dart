import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import '../util/remote_paths.dart';

/// 批量复制/移动时部分成功：已粘贴的名字 + 失败项说明。
class SftpRemotePastePartialFailure implements Exception {
  SftpRemotePastePartialFailure({
    required this.pasted,
    required this.failures,
  });

  final List<String> pasted;
  final List<String> failures;

  @override
  String toString() {
    final head = pasted.isEmpty
        ? '全部失败'
        : '部分成功（${pasted.length}），失败 ${failures.length} 项';
    return '$head：${failures.join('；')}';
  }
}

/// 在 [parentDir] 下为 [desiredName] 生成不冲突的名字（同目录粘贴复制用）。
Future<String> sftpUniqueChildName(
  SftpClient client,
  String parentDir,
  String desiredName,
) async {
  final base = desiredName.trim();
  if (base.isEmpty) return base;
  Future<bool> exists(String name) async {
    try {
      await client.stat(remoteJoin(parentDir, name));
      return true;
    } catch (_) {
      return false;
    }
  }

  if (!await exists(base)) return base;

  final ext = p.extension(base);
  final stem = ext.isEmpty ? base : base.substring(0, base.length - ext.length);
  for (var i = 1; i < 10000; i++) {
    final candidate = ext.isEmpty
        ? '$stem copy${i == 1 ? '' : ' $i'}'
        : '$stem copy${i == 1 ? '' : ' $i'}$ext';
    if (!await exists(candidate)) return candidate;
  }
  return '$stem copy ${DateTime.now().millisecondsSinceEpoch}$ext';
}

/// 目标落在源路径自身或其子树时抛出（避免递归复制/移动死循环）。
void assertRemoteCopyDestinationAllowed(String fromAbs, String toAbs) {
  if (isRemotePathUnderOrEqual(fromAbs, toAbs)) {
    throw StateError('不能复制或移动到自身或其子目录下');
  }
}

/// 递归复制远端路径 [fromAbs] → [toAbs]（[toAbs] 不得已存在）。
Future<void> sftpCopyRemotePath(
  SftpClient client,
  String fromAbs,
  String toAbs,
) async {
  assertRemoteCopyDestinationAllowed(fromAbs, toAbs);
  final st = await client.stat(fromAbs);
  if (st.isDirectory) {
    await client.mkdir(toAbs);
    final kids = await client.listdir(fromAbs);
    for (final k in kids) {
      if (k.filename == '.' || k.filename == '..') continue;
      await sftpCopyRemotePath(
        client,
        remoteJoin(fromAbs, k.filename),
        remoteJoin(toAbs, k.filename),
      );
    }
    return;
  }

  final src = await client.open(fromAbs, mode: SftpFileOpenMode.read);
  final dst = await client.open(
    toAbs,
    mode:
        SftpFileOpenMode.create |
        SftpFileOpenMode.write |
        SftpFileOpenMode.truncate,
  );
  try {
    const chunk = 64 * 1024;
    var offset = 0;
    while (true) {
      final data = await src.readBytes(length: chunk, offset: offset);
      if (data.isEmpty) break;
      await dst.writeBytes(data, offset: offset);
      offset += data.length;
      if (data.length < chunk) break;
    }
  } finally {
    await src.close();
    await dst.close();
  }
}

void _throwIfBatchFailed(List<String> pasted, List<String> failures) {
  if (failures.isEmpty) return;
  throw SftpRemotePastePartialFailure(pasted: pasted, failures: failures);
}

/// 将 [fromCwd] 下的 [names] 复制到 [toCwd]；重名自动加 “copy” 后缀。
///
/// 逐项执行：单项失败不中断后续项；若有失败则抛 [SftpRemotePastePartialFailure]
///（其中 [SftpRemotePastePartialFailure.pasted] 为已成功项）。
Future<List<String>> sftpCopyRemoteNames({
  required SftpClient client,
  required String fromCwd,
  required String toCwd,
  required List<String> names,
}) async {
  final pasted = <String>[];
  final failures = <String>[];
  for (final name in names) {
    try {
      final from = remoteJoin(fromCwd, name);
      final unique = await sftpUniqueChildName(client, toCwd, name);
      final to = remoteJoin(toCwd, unique);
      if (from == to) continue;
      assertRemoteCopyDestinationAllowed(from, to);
      await sftpCopyRemotePath(client, from, to);
      pasted.add(unique);
    } catch (e) {
      failures.add('$name：$e');
    }
  }
  _throwIfBatchFailed(pasted, failures);
  return pasted;
}

/// 将 [fromCwd] 下的 [names] 移动到 [toCwd]；同路径跳过，重名自动换名。
///
/// 语义同 [sftpCopyRemoteNames]：单项失败不阻断其余项。
Future<List<String>> sftpMoveRemoteNames({
  required SftpClient client,
  required String fromCwd,
  required String toCwd,
  required List<String> names,
}) async {
  final pasted = <String>[];
  final failures = <String>[];
  for (final name in names) {
    try {
      final from = remoteJoin(fromCwd, name);
      final unique = fromCwd == toCwd
          ? name
          : await sftpUniqueChildName(client, toCwd, name);
      final to = remoteJoin(toCwd, unique);
      if (from == to) {
        pasted.add(unique);
        continue;
      }
      assertRemoteCopyDestinationAllowed(from, to);
      await client.rename(from, to);
      pasted.add(unique);
    } catch (e) {
      failures.add('$name：$e');
    }
  }
  _throwIfBatchFailed(pasted, failures);
  return pasted;
}
