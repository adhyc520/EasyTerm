import 'package:desktop_drop/desktop_drop.dart';

import '../services/ssh_workspace_controller.dart';
import 'remote_paths.dart';

/// 从桌面拖放结果解析「应粘贴/打开」的路径列表。
///
/// 优先还原内部远端拖出的绝对路径；否则回退为本地文件路径字符串。
List<String> resolveDesktopDropPaths(DropDoneDetails detail) {
  final remote = resolveDesktopDropRemotePaths(
    detail,
    allowLastPathFallback: true,
  );
  if (remote.isNotEmpty) return remote;

  final out = <String>[];
  for (final f in detail.files) {
    final path = f.path;
    if (path.isEmpty) continue;
    if (SshWorkspaceController.isPathFromRecentDragOut(path)) {
      final last = SshWorkspaceController.lastDragRemotePath;
      if (last != null && last.isNotEmpty) {
        out.add(last);
        continue;
      }
    }
    out.add(path);
  }
  if (out.isEmpty) {
    final last = SshWorkspaceController.lastDragRemotePath;
    if (last != null && last.isNotEmpty) out.add(last);
  }
  return out;
}

/// 仅解析内部远端拖出的绝对路径；本机文件拖入返回空列表。
///
/// [allowLastPathFallback]：虚拟文件拖出时 [detail.files] 可能为空，用
/// [SshWorkspaceController.lastDragRemotePath] 兜底。文件管理器远端粘贴应传
/// `true`，且仅在仍有内部拖出标记时采用兜底。
List<String> resolveDesktopDropRemotePaths(
  DropDoneDetails detail, {
  bool allowLastPathFallback = true,
  bool isInternalDrag = false,
}) {
  final batch = SshWorkspaceController.activeDragRemotePaths;
  if (batch.isNotEmpty) {
    return [
      for (final p in batch)
        if (p.isNotEmpty) p,
    ];
  }

  final out = <String>[];
  final seen = <String>{};
  for (final f in detail.files) {
    final path = f.path;
    if (path.isEmpty) continue;
    final remote = SshWorkspaceController.remotePathForDragTemp(path);
    if (remote == null || remote.isEmpty) continue;
    final key = normalizeRemotePathForCompare(remote);
    if (seen.add(key)) out.add(remote);
  }
  if (out.isEmpty &&
      allowLastPathFallback &&
      isInternalDrag &&
      SshWorkspaceController.lastDragRemotePath != null &&
      SshWorkspaceController.lastDragRemotePath!.isNotEmpty) {
    out.add(SshWorkspaceController.lastDragRemotePath!);
  }
  return out;
}
