import 'package:flutter/material.dart';

import '../services/sftp_browser_host.dart';
import 'sftp_browser.dart';

/// 终端工作台侧栏文件浏览器：薄封装，委托 [SftpBrowser]。
///
/// [onOpenInEditor] 为 null 时，[SftpBrowser] 内部走 [RemoteEditorScreen] 路由；
/// 桌面文件管理器窗口传入回调以打开编辑器窗口。
class SftpSidePanel extends StatelessWidget {
  const SftpSidePanel({
    super.key,
    required this.controller,
    this.onOpenInEditor,
  });

  final SftpBrowserHost controller;

  /// 桌面模式：双击 / 菜单「打开」时回调；为 null 时走全屏编辑器路由。
  final void Function(String fileName)? onOpenInEditor;

  /// 内部拖出标志（委托 [SftpBrowser]）。
  static bool get isDraggingInternalItem => SftpBrowser.isDraggingInternalItem;
  static set isDraggingInternalItem(bool v) =>
      SftpBrowser.isDraggingInternalItem = v;

  @override
  Widget build(BuildContext context) {
    return SftpBrowser(
      controller: controller,
      onOpenInEditor: onOpenInEditor,
    );
  }
}
