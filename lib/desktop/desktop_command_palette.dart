import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';
import '../widgets/desktop_settings_dialog.dart';
import 'desktop_window_manager.dart';

/// 桌面命令面板：⌘/Ctrl+Shift+P 唤起，模糊搜索执行动作。
class DesktopCommandPalette extends StatefulWidget {
  const DesktopCommandPalette({
    super.key,
    required this.wm,
    required this.controller,
    required this.onClose,
  });

  final DesktopWindowManager wm;
  final SshWorkspaceController controller;
  final VoidCallback onClose;

  @override
  State<DesktopCommandPalette> createState() => _DesktopCommandPaletteState();
}

class _DesktopCommandPaletteState extends State<DesktopCommandPalette> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  int _selected = 0;
  late List<_Cmd> _all;
  List<_Cmd> _filtered = [];

  @override
  void initState() {
    super.initState();
    _all = _buildCommands();
    _filtered = _all;
    _query.addListener(_refilter);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<_Cmd> _buildCommands() {
    final wm = widget.wm;
    final items = <_Cmd>[
      _Cmd(
        title: '终端',
        subtitle: '打开新终端',
        category: '应用',
        icon: Icons.terminal_rounded,
        keywords: 'terminal tm',
        invoke: () => wm.openTerminal(preferPrimary: false),
      ),
      _Cmd(
        title: '文件',
        category: '应用',
        icon: Icons.folder_rounded,
        keywords: 'files fm',
        invoke: () => wm.open(DesktopAppType.files),
      ),
      _Cmd(
        title: '浏览器',
        category: '应用',
        icon: Icons.language_rounded,
        keywords: 'browser',
        invoke: () => wm.open(DesktopAppType.browser),
      ),
      _Cmd(
        title: '监控',
        category: '应用',
        icon: Icons.monitor_heart_rounded,
        keywords: 'monitor',
        invoke: () => wm.open(DesktopAppType.monitor),
      ),
      _Cmd(
        title: '任务管理器',
        category: '应用',
        icon: Icons.memory_rounded,
        keywords: 'tm tasks task manager',
        invoke: () => wm.open(DesktopAppType.tasks),
      ),
      _Cmd(
        title: '日志',
        category: '应用',
        icon: Icons.article_rounded,
        keywords: 'logs',
        invoke: () => wm.open(DesktopAppType.logs),
      ),
      _Cmd(
        title: '容器',
        category: '应用',
        icon: Icons.view_in_ar_rounded,
        keywords: 'docker containers',
        invoke: () => wm.open(DesktopAppType.containers),
      ),
      _Cmd(
        title: '磁盘占用',
        category: '应用',
        icon: Icons.pie_chart_rounded,
        keywords: 'disk du',
        invoke: () => wm.open(DesktopAppType.diskUsage),
      ),
      _Cmd(
        title: '传输',
        category: '应用',
        icon: Icons.swap_vert_rounded,
        keywords: 'transfers',
        invoke: () => wm.open(DesktopAppType.transfers),
      ),
      _Cmd(
        title: '端口转发',
        category: '应用',
        icon: Icons.alt_route_rounded,
        keywords: 'forward port tunnel',
        invoke: () => wm.open(DesktopAppType.forwards),
      ),
      _Cmd(
        title: '运行命令',
        category: '应用',
        icon: Icons.play_circle_outline_rounded,
        keywords: 'run command exec',
        invoke: () => wm.open(DesktopAppType.runCommand),
      ),
      _Cmd(
        title: '计划任务',
        category: '应用',
        icon: Icons.schedule_rounded,
        keywords: 'cron crontab schedule',
        invoke: () => wm.open(DesktopAppType.cron),
      ),
      _Cmd(
        title: '用户与组',
        category: '应用',
        icon: Icons.groups_rounded,
        keywords: 'users who last passwd',
        invoke: () => wm.open(DesktopAppType.users),
      ),
      _Cmd(
        title: '包管理器',
        category: '应用',
        icon: Icons.inventory_2_rounded,
        keywords: 'apt dnf yum pacman brew package install',
        invoke: () => wm.open(DesktopAppType.packages),
      ),
      _Cmd(
        title: '防火墙',
        category: '应用',
        icon: Icons.security_rounded,
        keywords: 'firewall ufw iptables security',
        invoke: () => wm.open(DesktopAppType.firewall),
      ),
      _Cmd(
        title: '桌面设置',
        category: '设置',
        icon: Icons.settings_rounded,
        keywords: 'settings desktop',
        invoke: () => showDesktopSettingsDialog(context, wm: wm),
      ),
      _Cmd(
        title: '显示桌面',
        category: '窗口',
        icon: Icons.desktop_windows_rounded,
        keywords: 'show desktop',
        invoke: () => wm.toggleShowDesktop(),
      ),
      _Cmd(
        title: '重连',
        category: '设置',
        icon: Icons.refresh_rounded,
        keywords: 'reconnect',
        invoke: () {
          if (!widget.controller.connecting) {
            widget.controller.reconnect();
          }
        },
      ),
      _Cmd(
        title: '新建工作区',
        category: '工作区',
        icon: Icons.add_box_outlined,
        keywords: 'workspace new',
        invoke: () => wm.addWorkspace(),
      ),
    ];

    for (var i = 0; i < wm.workspaces.length; i++) {
      final idx = i;
      items.add(
        _Cmd(
          title: '切换到 ${wm.workspaces[i].name}',
          category: '工作区',
          icon: Icons.grid_view_rounded,
          keywords: 'ws ${i + 1}',
          invoke: () => wm.switchWorkspace(idx),
        ),
      );
    }

    for (final w in wm.windows) {
      items.add(
        _Cmd(
          title: '聚焦：${w.title}',
          category: '窗口',
          icon: Icons.filter_none_rounded,
          keywords: w.title,
          invoke: () => wm.focus(w.id),
        ),
      );
      items.add(
        _Cmd(
          title: '关闭：${w.title}',
          category: '窗口',
          icon: Icons.close_rounded,
          keywords: 'close ${w.title}',
          invoke: () => wm.requestClose(w.id),
        ),
      );
      items.add(
        _Cmd(
          title: '${w.alwaysOnTop ? '取消置顶' : '置顶'}：${w.title}',
          category: '窗口',
          icon: Icons.push_pin_rounded,
          keywords: 'pin top ${w.title}',
          invoke: () => wm.toggleAlwaysOnTop(w.id),
        ),
      );
    }
    return items;
  }

  void _refilter() {
    final q = _query.text.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filtered = _all;
      } else {
        _filtered = [
          for (final c in _all)
            if (c.matches(q)) c,
        ];
      }
      _selected = 0;
    });
  }

  void _runSelected() {
    if (_filtered.isEmpty) return;
    final cmd = _filtered[_selected.clamp(0, _filtered.length - 1)];
    widget.onClose();
    cmd.invoke();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_filtered.isEmpty) return KeyEventResult.handled;
      setState(() => _selected = (_selected + 1) % _filtered.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_filtered.isEmpty) return KeyEventResult.handled;
      setState(
        () => _selected =
            (_selected - 1 + _filtered.length) % _filtered.length,
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _runSelected();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
              child: Material(
                color: wb.panelElevated,
                elevation: 12,
                borderRadius: BorderRadius.circular(12),
                child: Focus(
                  focusNode: _focus,
                  onKeyEvent: _onKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                        child: TextField(
                          controller: _query,
                          autofocus: true,
                          style: TextStyle(color: wb.primaryText),
                          decoration: InputDecoration(
                            hintText: '搜索命令…',
                            hintStyle: TextStyle(color: wb.textMuted),
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              color: wb.textMuted,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            isDense: true,
                          ),
                        ),
                      ),
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _filtered.length,
                          itemBuilder: (context, i) {
                            final c = _filtered[i];
                            final sel = i == _selected;
                            return ListTile(
                              dense: true,
                              selected: sel,
                              selectedTileColor:
                                  wb.accentBlue.withValues(alpha: 0.18),
                              leading: Icon(c.icon, size: 18, color: wb.textMuted),
                              title: Text(
                                c.title,
                                style: TextStyle(color: wb.primaryText),
                              ),
                              subtitle: Text(
                                c.category +
                                    (c.subtitle == null
                                        ? ''
                                        : ' · ${c.subtitle}'),
                                style: TextStyle(
                                  color: wb.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                              onTap: () {
                                _selected = i;
                                _runSelected();
                              },
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '↑↓ 选择 · Enter 执行 · Esc 关闭',
                            style: TextStyle(
                              fontSize: 11,
                              color: wb.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Cmd {
  _Cmd({
    required this.title,
    required this.category,
    required this.icon,
    required this.invoke,
    this.subtitle,
    this.keywords = '',
  });

  final String title;
  final String? subtitle;
  final String category;
  final IconData icon;
  final String keywords;
  final void Function() invoke;

  bool matches(String q) {
    final hay = '$title $category ${subtitle ?? ''} $keywords'.toLowerCase();
    if (hay.contains(q)) return true;
    // 首字母缩写：任务管理器 → rwgl / tm already in keywords
    final initials = title
        .replaceAll(RegExp(r'\s+'), '')
        .split('')
        .where((c) => RegExp(r'[A-Za-z\u4e00-\u9fff]').hasMatch(c))
        .take(6)
        .join()
        .toLowerCase();
    return initials.contains(q);
  }
}
