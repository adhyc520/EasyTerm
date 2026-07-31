import 'ssh_workspace_controller.dart';

/// 终端分屏方向：水平 = 左右，垂直 = 上下。
enum SessionPaneAxis { horizontal, vertical }

/// 分屏树节点：叶子为独立 SSH 终端，中间节点为可拖拽比例的二分布局。
sealed class SessionPaneNode {
  const SessionPaneNode();

  Iterable<SessionPaneLeaf> get leaves;

  bool containsPaneId(int paneId);

  SessionPaneLeaf? findLeaf(int paneId);

  /// 用 [replacement] 替换树中 [paneId] 对应的叶子；找不到则返回 null。
  SessionPaneNode? replaceLeaf(int paneId, SessionPaneNode replacement);

  /// 移除 [paneId] 叶子；若移除后只剩一侧则折叠为该侧。整树删空返回 null。
  SessionPaneNode? removeLeaf(int paneId);
}

final class SessionPaneLeaf extends SessionPaneNode {
  SessionPaneLeaf({required this.paneId, required this.controller});

  final int paneId;
  final SshWorkspaceController controller;

  @override
  Iterable<SessionPaneLeaf> get leaves sync* {
    yield this;
  }

  @override
  bool containsPaneId(int paneId) => this.paneId == paneId;

  @override
  SessionPaneLeaf? findLeaf(int paneId) => this.paneId == paneId ? this : null;

  @override
  SessionPaneNode? replaceLeaf(int paneId, SessionPaneNode replacement) {
    if (this.paneId != paneId) return null;
    return replacement;
  }

  @override
  SessionPaneNode? removeLeaf(int paneId) {
    if (this.paneId != paneId) return null;
    return null;
  }
}

final class SessionPaneSplit extends SessionPaneNode {
  SessionPaneSplit({
    required this.axis,
    required this.first,
    required this.second,
    this.ratio = 0.5,
  });

  SessionPaneAxis axis;

  /// 第一格占比（0.15–0.85）。
  double ratio;
  SessionPaneNode first;
  SessionPaneNode second;

  @override
  Iterable<SessionPaneLeaf> get leaves sync* {
    yield* first.leaves;
    yield* second.leaves;
  }

  @override
  bool containsPaneId(int paneId) =>
      first.containsPaneId(paneId) || second.containsPaneId(paneId);

  @override
  SessionPaneLeaf? findLeaf(int paneId) =>
      first.findLeaf(paneId) ?? second.findLeaf(paneId);

  @override
  SessionPaneNode? replaceLeaf(int paneId, SessionPaneNode replacement) {
    final a = first.replaceLeaf(paneId, replacement);
    if (a != null) {
      return SessionPaneSplit(
        axis: axis,
        first: a,
        second: second,
        ratio: ratio,
      );
    }
    final b = second.replaceLeaf(paneId, replacement);
    if (b != null) {
      return SessionPaneSplit(
        axis: axis,
        first: first,
        second: b,
        ratio: ratio,
      );
    }
    return null;
  }

  @override
  SessionPaneNode? removeLeaf(int paneId) {
    if (first.containsPaneId(paneId)) {
      final next = first.removeLeaf(paneId);
      if (next == null) return second;
      return SessionPaneSplit(
        axis: axis,
        first: next,
        second: second,
        ratio: ratio,
      );
    }
    if (second.containsPaneId(paneId)) {
      final next = second.removeLeaf(paneId);
      if (next == null) return first;
      return SessionPaneSplit(
        axis: axis,
        first: first,
        second: next,
        ratio: ratio,
      );
    }
    return null;
  }
}

/// 将新叶子插到目标叶子旁，形成二分。
enum SessionSplitPlacement {
  /// 新窗格在左 / 上。
  before,

  /// 新窗格在右 / 下。
  after,
}

SessionPaneNode splitLeaf({
  required SessionPaneNode root,
  required int targetPaneId,
  required SessionPaneLeaf newLeaf,
  required SessionPaneAxis axis,
  required SessionSplitPlacement placement,
}) {
  final target = root.findLeaf(targetPaneId);
  if (target == null) return root;
  final split = placement == SessionSplitPlacement.before
      ? SessionPaneSplit(axis: axis, first: newLeaf, second: target)
      : SessionPaneSplit(axis: axis, first: target, second: newLeaf);
  return root.replaceLeaf(targetPaneId, split) ?? root;
}
