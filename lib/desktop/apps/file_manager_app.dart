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
  late final DesktopSftpController _host;

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
  }

  @override
  void dispose() {
    _host.removeListener(_syncTitle);
    _host.dispose();
    super.dispose();
  }

  void _syncTitle() {
    final path = _host.remoteCwd;
    widget.window.args['cwd'] = path;
    final next = path == '/' ? '文件' : remoteBasename(path);
    if (widget.window.title != next) {
      widget.window.title = next.isEmpty ? '文件' : next;
      widget.wm.requestRebuild(persist: true);
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

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.wb.panel,
      child: SftpBrowser(
        controller: _host,
        onOpenInEditor: _openInEditor,
      ),
    );
  }
}
