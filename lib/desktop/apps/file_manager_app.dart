import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/desktop_sftp_controller.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../util/remote_paths.dart';
import '../../widgets/sftp_browser.dart';
import '../desktop_window_manager.dart';

/// 桌面文件管理器：独立 [DesktopSftpController] cwd，共享会话 SFTP。
class FileManagerApp extends StatefulWidget {
  const FileManagerApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<FileManagerApp> createState() => _FileManagerAppState();
}

class _FileManagerAppState extends State<FileManagerApp> {
  final GlobalKey<SftpBrowserState> _browserKey = GlobalKey<SftpBrowserState>();
  late final DesktopSftpController _host;
  bool _wasFocused = false;
  int _seenFocusGeneration = -1;

  @override
  void initState() {
    super.initState();
    final cwd = widget.window.args['cwd']?.toString();
    _host = DesktopSftpController(
      widget.controller,
      initialCwd: (cwd != null && cwd.isNotEmpty) ? cwd : null,
    );
    unawaited(_host.bindInitial());
    _host.addListener(_syncTitle);
    widget.wm.addListener(_onWm);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncKeyboardFocus());
  }

  @override
  void dispose() {
    widget.wm.removeListener(_onWm);
    _host.removeListener(_syncTitle);
    _host.dispose();
    super.dispose();
  }

  void _onWm() {
    if (!mounted) return;
    _syncKeyboardFocus();
  }

  void _syncKeyboardFocus() {
    final focused = widget.window.focused;
    final gen = widget.wm.focusGeneration;
    final gained = focused && !_wasFocused;
    final reclaimed = focused && gen != _seenFocusGeneration;
    _wasFocused = focused;
    if (!gained && !reclaimed) return;
    _seenFocusGeneration = gen;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.window.focused) return;
      _browserKey.currentState?.requestKeyboardFocus();
    });
  }

  void _syncTitle() {
    final path = _host.remoteCwd;
    widget.window.args['cwd'] = path;
    final next = path == '/' ? '文件' : remoteBasename(path);
    if (widget.window.title != next) {
      widget.window.title = next.isEmpty ? '文件' : next;
      widget.wm.requestRebuild();
    }
  }

  void _openInEditor(String name) {
    final path = remoteJoin(_host.remoteCwd, name);
    widget.wm.open(
      DesktopAppType.editor,
      args: {
        'path': path,
        'hostId':
            '${widget.controller.username}@${widget.controller.host}:${widget.controller.port}',
      },
    );
  }

  void _analyzeDiskUsage(String? relativeName) {
    final path = relativeName == null || relativeName.isEmpty
        ? _host.remoteCwd
        : remoteJoin(_host.remoteCwd, relativeName);
    widget.wm.open(DesktopAppType.diskUsage, args: {'path': path});
  }

  void _openTerminal(String? relativeName) {
    final path = relativeName == null || relativeName.isEmpty
        ? _host.remoteCwd
        : remoteJoin(_host.remoteCwd, relativeName);
    widget.wm.open(DesktopAppType.terminal, args: {'cwd': path});
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.wb.panel,
      child: SftpBrowser(
        key: _browserKey,
        controller: _host,
        autofocus: widget.window.focused,
        tapRegionGroupId: widget.window.id,
        onActivate: () =>
            widget.wm.focus(widget.window.id, reclaimKeyboard: false),
        onOpenInEditor: _openInEditor,
        onAnalyzeDiskUsage: _analyzeDiskUsage,
        onOpenTerminal: _openTerminal,
      ),
    );
  }
}
