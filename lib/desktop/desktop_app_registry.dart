import 'package:flutter/material.dart';

import 'desktop_window_manager.dart' show DesktopAppType;

/// 桌面应用元数据：图标 / 标题 / 搜索关键词 / 默认窗口尺寸。
class AppMeta {
  const AppMeta(
    this.id,
    this.icon,
    this.label,
    this.keywords, {
    this.defaultSize,
  });

  final DesktopAppType id;
  final IconData icon;
  final String label;
  final List<String> keywords;
  final Size? defaultSize;
}

const kAllApps = <AppMeta>[
  AppMeta(
    DesktopAppType.terminal,
    Icons.terminal_rounded,
    '终端',
    ['terminal', 'shell', 'ssh'],
    defaultSize: Size(720, 460),
  ),
  AppMeta(
    DesktopAppType.files,
    Icons.folder_rounded,
    '文件管理器',
    ['files', 'sftp', 'file manager'],
    defaultSize: Size(820, 540),
  ),
  AppMeta(
    DesktopAppType.browser,
    Icons.language_rounded,
    '浏览器',
    ['browser', 'web'],
    defaultSize: Size(900, 600),
  ),
  AppMeta(
    DesktopAppType.monitor,
    Icons.monitor_heart_rounded,
    '监控',
    ['monitor', 'metrics', 'system'],
    defaultSize: Size(760, 560),
  ),
  AppMeta(
    DesktopAppType.tasks,
    Icons.memory_rounded,
    '任务管理器',
    ['tasks', 'task manager', 'process', 'top'],
    defaultSize: Size(820, 560),
  ),
  AppMeta(
    DesktopAppType.logs,
    Icons.article_rounded,
    '日志',
    ['logs', 'journal', 'tail'],
    defaultSize: Size(780, 520),
  ),
  AppMeta(
    DesktopAppType.containers,
    Icons.view_in_ar_rounded,
    '容器',
    ['containers', 'docker'],
    defaultSize: Size(820, 560),
  ),
  AppMeta(
    DesktopAppType.diskUsage,
    Icons.pie_chart_rounded,
    '磁盘占用',
    ['disk', 'du', 'usage'],
    defaultSize: Size(640, 520),
  ),
  AppMeta(
    DesktopAppType.transfers,
    Icons.swap_vert_rounded,
    '传输',
    ['transfers', 'upload', 'download'],
    defaultSize: Size(560, 420),
  ),
  AppMeta(
    DesktopAppType.editor,
    Icons.edit_note_rounded,
    '编辑器',
    ['editor', 'edit'],
    defaultSize: Size(780, 560),
  ),
  AppMeta(
    DesktopAppType.forwards,
    Icons.alt_route_rounded,
    '端口转发',
    ['forwards', 'tunnel', 'port forward'],
    defaultSize: Size(620, 460),
  ),
  AppMeta(
    DesktopAppType.runCommand,
    Icons.play_circle_outline_rounded,
    '运行命令',
    ['run', 'command'],
    defaultSize: Size(600, 420),
  ),
  AppMeta(
    DesktopAppType.cron,
    Icons.schedule_rounded,
    '计划任务',
    ['cron', 'crontab', 'schedule'],
    defaultSize: Size(640, 480),
  ),
  AppMeta(
    DesktopAppType.users,
    Icons.groups_rounded,
    '用户与组',
    ['users', 'who', 'last'],
    defaultSize: Size(640, 480),
  ),
  AppMeta(
    DesktopAppType.packages,
    Icons.inventory_2_rounded,
    '包管理器',
    ['packages', 'apt', 'dnf', 'pacman'],
    defaultSize: Size(760, 540),
  ),
  AppMeta(
    DesktopAppType.firewall,
    Icons.security_rounded,
    '防火墙',
    ['firewall', 'ufw', 'iptables'],
    defaultSize: Size(680, 520),
  ),
];

AppMeta metaFor(DesktopAppType t) => kAllApps.firstWhere((m) => m.id == t);

IconData iconForApp(DesktopAppType t) => metaFor(t).icon;
