import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote_disk_usage.dart';
import '../../services/remote_process_list.dart';
import '../../services/remote_sudo.dart';
import '../../services/terminal_session_controller.dart';
import '../../services/remote_exec_capable.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../widgets/remote_state_view.dart';
import '../../widgets/sudo_password_dialog.dart';
import '../desktop_window_manager.dart';
import '../widgets/desktop_monitor_widgets.dart';
import '../widgets/desktop_scrollable_actions.dart';

enum _DiskSort { size, name }

/// 目录磁盘占用分析（du）。
class DiskUsageApp extends StatefulWidget {
  const DiskUsageApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final TerminalSessionController controller;

  @override
  State<DiskUsageApp> createState() => _DiskUsageAppState();
}

class _DiskUsageAppState extends State<DiskUsageApp> {
  RemoteExecCapable get _exec => widget.controller as RemoteExecCapable;
static const _maxEntries = 60;

  RemoteDiskUsageSnapshot? _snap;
  bool _loading = false;
  String? _error;
  RemoteDiskUsageErrorKind? _errorKind;
  RemoteOsKind? _os;
  late String _path;
  final _filterCtrl = TextEditingController();
  final _filterFocus = FocusNode();
  final _listFocus = FocusNode();
  String _filter = '';
  _DiskSort _sort = _DiskSort.size;
  bool _sortAsc = false;
  bool _oneFilesystem = true;
  int _loadGen = 0;
  int? _selectedIndex;
  bool _sudoRetry = false;

  @override
  void initState() {
    super.initState();
    final arg = widget.window.args['path']?.toString();
    final cwdArg = widget.window.args['cwd']?.toString();
    if (arg != null && arg.isNotEmpty) {
      _path = arg;
    } else if (cwdArg != null && cwdArg.isNotEmpty) {
      _path = cwdArg;
    } else {
      _path = _exec.remoteCwd;
    }
    widget.controller.addListener(_onController);
    widget.window.onConnectionRestored = _onRestored;
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.window.onConnectionRestored = null;
    widget.controller.removeListener(_onController);
    _filterCtrl.dispose();
    _filterFocus.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  void _toggleSort(_DiskSort col) {
    setState(() {
      if (_sort == col) {
        _sortAsc = !_sortAsc;
      } else {
        _sort = col;
        _sortAsc = col == _DiskSort.name;
      }
      _selectedIndex = null;
    });
  }

  void _onRestored() {
    if (!mounted) return;
    setState(() {
      _error = null;
      _errorKind = null;
    });
    unawaited(_load());
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  bool get _isWindowsPath =>
      _path.contains('\\') && !_path.startsWith('/');

  bool get _connected =>
      widget.controller.connected && !widget.controller.dropped;

  String get _sep => _isWindowsPath ? '\\' : '/';

  String _joinPath(String base, String name) {
    final trimmed = base.replaceAll(RegExp(r'[/\\]+$'), '');
    if (trimmed.isEmpty) {
      return _isWindowsPath ? name : '/$name';
    }
    return '$trimmed$_sep$name';
  }

  String? _parentOf(String path) {
    if (path.isEmpty) return null;
    if (!_isWindowsPath && path == '/') return null;
    final trimmed = path.replaceAll(RegExp(r'[/\\]+$'), '');
    if (trimmed.isEmpty) return null;
    final parts =
        trimmed.split(RegExp(r'[/\\]')).where((e) => e.isNotEmpty).toList();
    if (_isWindowsPath) {
      if (parts.length <= 1) return null; // C: or C:\
      final parentParts = parts.sublist(0, parts.length - 1);
      if (parentParts.length == 1) return '${parentParts.first}\\';
      return parentParts.join('\\');
    }
    if (parts.isEmpty) return null;
    if (parts.length == 1) return '/';
    return '/${parts.sublist(0, parts.length - 1).join('/')}';
  }

  List<({String label, String path})> _breadcrumbSegments(String path) {
    if (!_isWindowsPath) {
      if (path == '/' || path.isEmpty) {
        return const [(label: '/', path: '/')];
      }
      final parts =
          path.split('/').where((e) => e.isNotEmpty).toList();
      final segs = <({String label, String path})>[
        (label: '/', path: '/'),
      ];
      var acc = '';
      for (final p in parts) {
        acc = '$acc/$p';
        segs.add((label: p, path: acc));
      }
      return segs;
    }
    final trimmed = path.replaceAll(RegExp(r'\\+$'), '');
    final parts =
        trimmed.split('\\').where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return [(label: path, path: path)];
    final segs = <({String label, String path})>[];
    var acc = parts.first;
    segs.add((label: '$acc\\', path: '$acc\\'));
    for (var i = 1; i < parts.length; i++) {
      acc = '$acc\\${parts[i]}';
      segs.add((label: parts[i], path: acc));
    }
    return segs;
  }

  String _titleForPath(String path) {
    const maxLen = 48;
    final full = '占用 · $path';
    if (full.length <= maxLen) return full;
    final budget = maxLen - 6; // "占用 · …"
    if (path.length <= budget) return full;
    return '占用 · …${path.substring(path.length - budget)}';
  }

  void _syncTitle(String path) {
    final next = _titleForPath(path);
    if (widget.window.title != next) {
      widget.window.title = next;
      widget.wm.requestRebuild();
    }
  }

  void _navigateTo(String path) {
    if (path.isEmpty || path == _path) return;
    setState(() {
      _path = path;
      widget.window.args['path'] = path;
      _selectedIndex = null;
      _sudoRetry = false;
    });
    _syncTitle(path);
    unawaited(_load());
  }

  void _goParent() {
    final parent = _parentOf(_path);
    if (parent != null) _navigateTo(parent);
  }

  Future<void> _load({bool useSudo = false}) async {
    if (!mounted) return;
    if (!_connected) {
      setState(() {
        _error = '连接已断开';
        _errorKind = null;
        _loading = false;
      });
      return;
    }
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _error = null;
      _errorKind = null;
      _sudoRetry = useSudo;
    });
    try {
      if (useSudo && !_isWindowsPath) {
        await _loadWithSudo(gen);
        return;
      }
      final snap = await fetchRemoteDiskUsage(
        _exec,
        path: _path,
        osHint: _os,
        maxEntries: _maxEntries,
        oneFilesystem: _oneFilesystem,
      );
      if (!mounted || gen != _loadGen) return;
      _applySnap(snap);
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _error = '$e';
        _errorKind = RemoteDiskUsageErrorKind.other;
        _loading = false;
      });
    }
  }

  Future<void> _loadWithSudo(int gen) async {
    final err = await runWithSudoPasswordPrompt(
      context,
      _exec,
      attempt: (sudoPassword) async {
        final snap = await fetchRemoteDiskUsage(
          _exec,
          path: _path,
          osHint: _os,
          maxEntries: _maxEntries,
          oneFilesystem: _oneFilesystem,
          useSudo: true,
          sudoPassword: sudoPassword,
        );
        if (!mounted || gen != _loadGen) return RemoteSudo.cancelled;
        if (snap == null) return '命令失败或已断开';
        if (RemoteSudo.isPasswordRequired(snap.error) ||
            RemoteSudo.isAuthFailed(snap.error)) {
          return snap.error;
        }
        _applySnap(snap);
        // 仍权限不足时返回错误文案（非哨兵），结束密码循环。
        if (snap.errorKind == RemoteDiskUsageErrorKind.permission) {
          return snap.error ?? '权限不足';
        }
        return null;
      },
    );
    if (!mounted || gen != _loadGen) return;
    if (RemoteSudo.isCancelled(err)) {
      setState(() => _loading = false);
      return;
    }
    if (err != null && (_snap == null || _snap!.entries.isEmpty)) {
      setState(() {
        _error = err;
        _errorKind = classifyDiskUsageError(err) ??
            RemoteDiskUsageErrorKind.permission;
        _loading = false;
      });
    } else if (_loading) {
      setState(() => _loading = false);
    }
  }

  void _applySnap(RemoteDiskUsageSnapshot? snap) {
    if (snap == null) {
      setState(() {
        _error = '无法获取占用';
        _errorKind = RemoteDiskUsageErrorKind.other;
        _loading = false;
      });
      return;
    }
    if (snap.os != RemoteOsKind.unknown) _os = snap.os;
    if (snap.path.isNotEmpty && snap.path != _path) {
      _path = snap.path;
      widget.window.args['path'] = _path;
    }
    _syncTitle(_path);
    setState(() {
      _snap = snap;
      _loading = false;
      _error = snap.error;
      _errorKind = snap.errorKind ?? classifyDiskUsageError(snap.error);
      _selectedIndex = null;
    });
  }

  void _cancelLoad() {
    _loadGen++;
    if (mounted) setState(() => _loading = false);
  }

  void _openChild(RemoteDiskUsageEntry e) {
    if (e.isTotal) return;
    _navigateTo(_joinPath(_path, e.name));
  }

  String _entryPath(RemoteDiskUsageEntry e) => _joinPath(_path, e.name);

  void _openInFiles(String path) {
    widget.wm.open(DesktopAppType.files, args: {'cwd': path});
  }

  void _openInTerminal(String path, {String? inject}) {
    widget.wm.open(
      DesktopAppType.terminal,
      args: {
        'cwd': path,
        if (inject != null && inject.isNotEmpty) 'inject': inject,
      },
    );
  }

  void _moveSelection(int delta, int length) {
    if (length == 0) return;
    final cur = _selectedIndex ?? (delta > 0 ? -1 : length);
    var next = cur + delta;
    if (next < 0) next = 0;
    if (next >= length) next = length - 1;
    setState(() => _selectedIndex = next);
    _listFocus.requestFocus();
  }

  void _activateSelected(List<RemoteDiskUsageEntry> children) {
    final i = _selectedIndex;
    if (i == null || i < 0 || i >= children.length) return;
    _openChild(children[i]);
  }

  void _focusFilter() => _filterFocus.requestFocus();

  void _clearSelection() {
    if (_selectedIndex == null) return;
    setState(() => _selectedIndex = null);
  }

  Future<void> _showPathMenu(
    Offset globalPosition,
    String path, {
    bool allowCopy = true,
  }) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: [
        if (allowCopy)
          const PopupMenuItem(value: 'copy', child: Text('复制路径')),
        const PopupMenuItem(value: 'files', child: Text('在文件管理器打开')),
        const PopupMenuItem(value: 'terminal', child: Text('在终端打开')),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'copy':
        Clipboard.setData(ClipboardData(text: path));
      case 'files':
        _openInFiles(path);
      case 'terminal':
        _openInTerminal(path);
    }
  }

  Color _barColor(double ofTotal) {
    final t = ofTotal.clamp(0.0, 1.0);
    if (t < 0.5) {
      return Color.lerp(
        const Color(0xFF22C55E),
        const Color(0xFFEAB308),
        t * 2,
      )!;
    }
    return Color.lerp(
      const Color(0xFFEAB308),
      const Color(0xFFEF4444),
      (t - 0.5) * 2,
    )!;
  }

  List<RemoteDiskUsageEntry> _visibleChildren() {
    final snap = _snap;
    final allChildren = [
      for (final e in snap?.entries ?? const <RemoteDiskUsageEntry>[])
        if (!e.isTotal) e,
    ];
    final q = _filter.trim().toLowerCase();
    final filtered = q.isEmpty
        ? allChildren
        : [
            for (final e in allChildren)
              if (e.name.toLowerCase().contains(q)) e,
          ];
    return [...filtered]..sort((a, b) {
        final cmp = switch (_sort) {
          _DiskSort.name =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          _DiskSort.size => a.bytes.compareTo(b.bytes),
        };
        return _sortAsc ? cmp : -cmp;
      });
  }

  RemoteState _remoteState({
    required List<RemoteDiskUsageEntry> children,
    required bool filterActive,
  }) {
    if (!_connected) return RemoteState.disconnected;
    final hasData = (_snap?.entries.isNotEmpty ?? false);
    if (_loading && !hasData) return RemoteState.loading;
    if (!hasData &&
        _errorKind == RemoteDiskUsageErrorKind.permission &&
        !_isWindowsPath) {
      return RemoteState.denied;
    }
    if (!hasData && _error != null && !_loading) return RemoteState.error;
    if (!hasData && !_loading) {
      return RemoteState.empty;
    }
    if (hasData && children.isEmpty && filterActive && !_loading) {
      return RemoteState.empty;
    }
    return RemoteState.data;
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final snap = _snap;
    final allChildren = [
      for (final e in snap?.entries ?? const <RemoteDiskUsageEntry>[])
        if (!e.isTotal) e,
    ];
    final q = _filter.trim();
    final children = _visibleChildren();
    final total = snap?.totalBytes;
    final maxBytes = children.isEmpty
        ? 1
        : children.map((e) => e.bytes).reduce((a, b) => a > b ? a : b);
    final parent = _parentOf(_path);
    final crumbs = _breadcrumbSegments(_path);
    final state = _remoteState(
      children: children,
      filterActive: q.isNotEmpty,
    );
    final selectedPath = _selectedIndex != null &&
            _selectedIndex! >= 0 &&
            _selectedIndex! < children.length
        ? _entryPath(children[_selectedIndex!])
        : null;

    return ColoredBox(
      color: wb.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上级',
                  iconSize: 18,
                  onPressed: parent == null ? null : _goParent,
                  icon: Icon(
                    Icons.arrow_upward_rounded,
                    color: parent == null ? wb.border : wb.textMuted,
                  ),
                ),
                Icon(Icons.pie_chart_rounded, size: 18, color: wb.accentBlue),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      children: [
                        for (var i = 0; i < crumbs.length; i++) ...[
                          if (i > 0 &&
                              !(!_isWindowsPath && crumbs[i - 1].path == '/'))
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 2),
                              child: Text(
                                _isWindowsPath ? '\\' : '/',
                                style: TextStyle(
                                  color: wb.textMuted,
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          InkWell(
                            onTap: crumbs[i].path == _path
                                ? null
                                : () => _navigateTo(crumbs[i].path),
                            onSecondaryTapDown: (d) => unawaited(
                              _showPathMenu(d.globalPosition, crumbs[i].path),
                            ),
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              child: Text(
                                crumbs[i].label == '/'
                                    ? '/'
                                    : crumbs[i].label.replaceAll(
                                        RegExp(r'\\+$'),
                                        '',
                                      ),
                                style: TextStyle(
                                  color: crumbs[i].path == _path
                                      ? wb.primaryText
                                      : wb.accentBlue,
                                  fontWeight: crumbs[i].path == _path
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '打开',
                  icon: Icon(Icons.more_horiz_rounded, color: wb.textMuted),
                  iconSize: 18,
                  onSelected: (v) {
                    switch (v) {
                      case 'copy':
                        final p = selectedPath ?? _path;
                        Clipboard.setData(ClipboardData(text: p));
                      case 'files':
                        _openInFiles(selectedPath ?? _path);
                      case 'terminal':
                        _openInTerminal(selectedPath ?? _path);
                    }
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'copy',
                      child: Text(
                        selectedPath != null ? '复制选中路径' : '复制当前路径',
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'files',
                      child: Text('在文件管理器打开'),
                    ),
                    const PopupMenuItem(
                      value: 'terminal',
                      child: Text('在终端打开'),
                    ),
                  ],
                ),
                if (_loading) ...[
                  TextButton(
                    onPressed: _cancelLoad,
                    child: const Text('取消'),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ] else
                  IconButton(
                    tooltip: '刷新',
                    iconSize: 18,
                    onPressed: () => unawaited(_load()),
                    icon: Icon(Icons.refresh_rounded, color: wb.textMuted),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: FilterField(
                    controller: _filterCtrl,
                    focusNode: _filterFocus,
                    hintText: '筛选名称…',
                    onChanged: (v) => setState(() {
                      _filter = v;
                      _selectedIndex = null;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: DesktopScrollableActions(
                    children: [
                      FilterChip(
                        label: const Text(
                          '仅本文件系统',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: _oneFilesystem,
                        tooltip: _oneFilesystem
                            ? '已排除其它文件系统（du -x）'
                            : null,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        onSelected: (v) {
                          setState(() => _oneFilesystem = v);
                          unawaited(_load());
                        },
                      ),
                      if (_oneFilesystem) ...[
                        const SizedBox(width: 6),
                        Text(
                          '已排除其它文件系统（du -x）',
                          style: TextStyle(
                            fontSize: 10,
                            color: wb.textMuted,
                          ),
                        ),
                      ],
                      const SizedBox(width: 4),
                      TextButton(
                        onPressed: () => _toggleSort(_DiskSort.name),
                        child: Text(
                          _sort == _DiskSort.name
                              ? (_sortAsc ? '名称 ↑' : '名称 ↓')
                              : '名称',
                        ),
                      ),
                      TextButton(
                        onPressed: () => _toggleSort(_DiskSort.size),
                        child: Text(
                          _sort == _DiskSort.size
                              ? (_sortAsc ? '大小 ↑' : '大小 ↓')
                              : '大小',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (allChildren.length >= _maxEntries ||
              (snap?.entries.length ?? 0) >= _maxEntries)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '显示前 $_maxEntries 项（可能截断）',
                  style: TextStyle(fontSize: 11, color: wb.textMuted),
                ),
              ),
            ),
          if (total != null && state == RemoteState.data)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                '合计 ${formatUsageBytes(total)} · '
                '${q.isEmpty ? '${children.length}' : '${children.length}/${allChildren.length}'} 项',
                style: TextStyle(fontSize: 12, color: wb.textMuted),
              ),
            ),
          if (_error != null &&
              state == RemoteState.data &&
              !RemoteSudo.isPasswordRequired(_error) &&
              !RemoteSudo.isAuthFailed(_error))
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                _error!,
                style: TextStyle(color: wb.offline, fontSize: 12),
              ),
            ),
          Divider(height: 1, color: wb.border),
          Expanded(
            child: Focus(
              focusNode: _listFocus,
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _moveSelection(1, children.length),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      _moveSelection(-1, children.length),
                  const SingleActivator(LogicalKeyboardKey.enter): () =>
                      _activateSelected(children),
                  const SingleActivator(LogicalKeyboardKey.slash): _focusFilter,
                  const SingleActivator(
                    LogicalKeyboardKey.keyF,
                    control: true,
                  ): _focusFilter,
                  const SingleActivator(
                    LogicalKeyboardKey.keyF,
                    meta: true,
                  ): _focusFilter,
                  const SingleActivator(LogicalKeyboardKey.escape):
                      _clearSelection,
                },
                child: RemoteStateView(
                  state: state,
                  message: switch (state) {
                    RemoteState.disconnected => '未连接',
                    RemoteState.loading => null,
                    RemoteState.denied => _error ?? '权限不足',
                    RemoteState.error => _error ?? '加载失败',
                    RemoteState.empty => q.isNotEmpty ? '无匹配项' : '无子项数据',
                    _ => null,
                  },
                  detail: state == RemoteState.loading
                      ? '分析中…（大目录可能较慢）'
                      : (state == RemoteState.denied && _sudoRetry
                          ? 'sudo 后仍无法读取'
                          : null),
                  onRetry: switch (state) {
                    RemoteState.disconnected =>
                      () => unawaited(widget.controller.reconnect()),
                    RemoteState.denied => () => unawaited(_load(useSudo: true)),
                    RemoteState.error => () => unawaited(_load()),
                    RemoteState.empty =>
                      q.isNotEmpty ? null : () => unawaited(_load()),
                    _ => null,
                  },
                  retryLabel: state == RemoteState.denied ? '以 sudo 重试' : null,
                  data: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    itemCount: children.length,
                    itemBuilder: (context, i) {
                      final e = children[i];
                      final selected = _selectedIndex == i;
                      final ofTotal = total != null && total > 0
                          ? e.bytes / total
                          : null;
                      final frac = (ofTotal ?? (e.bytes / maxBytes))
                          .clamp(0.0, 1.0);
                      final barFrac = ofTotal ?? frac;
                      return Material(
                        color: selected
                            ? wb.accentBlue.withValues(alpha: 0.16)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        child: InkWell(
                          onTap: () {
                            setState(() => _selectedIndex = i);
                            _listFocus.requestFocus();
                            _openChild(e);
                          },
                          onSecondaryTapDown: (d) {
                            setState(() => _selectedIndex = i);
                            unawaited(
                              _showPathMenu(
                                d.globalPosition,
                                _entryPath(e),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 4,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        e.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: wb.primaryText,
                                          fontSize: 13,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ),
                                    Text(
                                      formatUsageBytes(e.bytes),
                                      style: TextStyle(
                                        color: wb.secondaryText,
                                        fontSize: 12,
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (ofTotal != null) ...[
                                      const SizedBox(width: 8),
                                      SizedBox(
                                        width: 40,
                                        child: Text(
                                          '${(ofTotal * 100).toStringAsFixed(0)}%',
                                          textAlign: TextAlign.right,
                                          style: TextStyle(
                                            color: wb.textMuted,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: frac,
                                    minHeight: 6,
                                    backgroundColor: wb.border,
                                    color: _barColor(barFrac),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
