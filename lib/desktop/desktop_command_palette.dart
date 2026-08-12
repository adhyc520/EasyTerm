import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';

import '../services/terminal_session_controller.dart';
import '../services/remote_exec_capable.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_desktop_shortcuts.dart';
import '../theme/workbench_theme.dart';
import '../widgets/desktop_settings_dialog.dart';
import '../widgets/desktop_shortcuts_cheatsheet.dart';
import 'desktop_window_manager.dart';
import 'widgets/desktop_ui.dart';

/// 桌面命令面板：⌘/Ctrl+Shift+P 唤起，模糊搜索执行动作。
class DesktopCommandPalette extends StatefulWidget {
  const DesktopCommandPalette({
    super.key,
    required this.wm,
    required this.controller,
    required this.onClose,
  });

  final DesktopWindowManager wm;
  final TerminalSessionController controller;
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

  String get _mod => workbenchUsesMetaPrimaryModifier() ? '⌘' : 'Ctrl';

  List<_Cmd> _buildCommands() {
    final wm = widget.wm;
    final mod = _mod;
    final focusedId = wm.focusedWindow?.id;

    final items = <_Cmd>[
      _Cmd(
        title: '终端',
        subtitle: '打开新终端',
        category: '应用',
        icon: Icons.terminal_rounded,
        keywords: 'terminal tm',
        shortcut: '$mod+N',
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
        shortcut: '$mod+R',
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
        title: '键盘快捷键',
        category: '设置',
        icon: Icons.keyboard_rounded,
        keywords: 'shortcuts cheatsheet keys keymap help',
        invoke: () => showDesktopShortcutsCheatsheet(context),
      ),
      _Cmd(
        title: '显示桌面',
        category: '窗口',
        icon: Icons.desktop_windows_rounded,
        keywords: 'show desktop',
        invoke: () => wm.toggleShowDesktop(),
      ),
      _Cmd(
        title: '最小化当前窗口',
        category: '窗口',
        icon: Icons.remove_rounded,
        keywords: 'minimize',
        shortcut: '$mod+M',
        invoke: () {
          if (focusedId != null) wm.minimize(focusedId);
        },
      ),
      _Cmd(
        title: '最大化 / 还原当前窗口',
        category: '窗口',
        icon: Icons.crop_square_rounded,
        keywords: 'maximize restore',
        shortcut: '$mod+Alt+↑',
        invoke: () {
          if (focusedId != null) wm.toggleMaximize(focusedId);
        },
      ),
      _Cmd(
        title: '当前窗口左半屏',
        category: '窗口',
        icon: Icons.vertical_split_rounded,
        keywords: 'tile left snap',
        shortcut: '$mod+Alt+←',
        invoke: () {
          if (focusedId != null) wm.tile(focusedId, TileZone.left);
        },
      ),
      _Cmd(
        title: '当前窗口右半屏',
        category: '窗口',
        icon: Icons.vertical_split_rounded,
        keywords: 'tile right snap',
        shortcut: '$mod+Alt+→',
        invoke: () {
          if (focusedId != null) wm.tile(focusedId, TileZone.right);
        },
      ),
      _Cmd(
        title: '循环切换窗口',
        category: '窗口',
        icon: Icons.flip_to_front_rounded,
        keywords: 'cycle windows focus',
        shortcut: '$mod+`',
        invoke: () => wm.cycleFocus(),
      ),
      _Cmd(
        title: '反向循环窗口',
        category: '窗口',
        icon: Icons.flip_to_back_rounded,
        keywords: 'cycle windows reverse',
        shortcut: '$mod+Shift+`',
        invoke: () => wm.cycleFocus(reverse: true),
      ),
      _Cmd(
        title: '关闭当前窗口',
        category: '窗口',
        icon: Icons.close_rounded,
        keywords: 'close',
        shortcut: '$mod+W',
        invoke: () {
          if (focusedId != null) wm.requestClose(focusedId);
        },
      ),
      _Cmd(
        title: '置顶 / 取消置顶当前窗口',
        category: '窗口',
        icon: Icons.push_pin_rounded,
        keywords: 'pin always on top',
        shortcut: '$mod+T',
        invoke: () {
          if (focusedId != null) wm.toggleAlwaysOnTop(focusedId);
        },
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
          shortcut: i < 9 ? '$mod+${i + 1}' : null,
          invoke: () => wm.switchWorkspace(idx),
        ),
      );
    }

    if (focusedId != null && wm.workspaces.length > 1) {
      for (var i = 0; i < wm.workspaces.length; i++) {
        final idx = i;
        final current = wm.workspaceIndexOfWindow(focusedId);
        if (current == idx) continue;
        items.add(
          _Cmd(
            title: '移到桌面 ${i + 1}',
            subtitle: wm.workspaces[i].name,
            category: '工作区',
            icon: Icons.open_with_rounded,
            keywords: 'move workspace ws ${i + 1} 移到',
            shortcut: null,
            invoke: () {
              final id = wm.focusedWindow?.id;
              if (id == null) return;
              wm.moveWindowToWorkspace(id, idx);
              wm.switchWorkspace(idx);
            },
          ),
        );
      }
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
    const appGate = <String, DesktopAppType>{
      '文件': DesktopAppType.files,
      '浏览器': DesktopAppType.browser,
      '监控': DesktopAppType.monitor,
      '任务管理器': DesktopAppType.tasks,
      '日志': DesktopAppType.logs,
      '容器': DesktopAppType.containers,
      '磁盘占用': DesktopAppType.diskUsage,
      '传输': DesktopAppType.transfers,
      '端口转发': DesktopAppType.forwards,
      '运行命令': DesktopAppType.runCommand,
      '计划任务': DesktopAppType.cron,
      '用户与组': DesktopAppType.users,
      '包管理器': DesktopAppType.packages,
      '防火墙': DesktopAppType.firewall,
    };
    return [
      for (final c in items)
        if (appGate[c.title] == null || wm.canOpen(appGate[c.title]!)) c,
    ];
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
      color: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
              ),
            ),
          ),
          Center(
            child: GestureDetector(
              onTap: () {},
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: 560, maxHeight: 460),
                child: DesktopGlass(
                  elevated: true,
                  opacity: 0.88,
                  sigma: 36,
                  borderRadius: DesktopUi.rLg,
                  child: Focus(
                    focusNode: _focus,
                    onKeyEvent: _onKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                          child: TextField(
                            controller: _query,
                            autofocus: true,
                            style: TextStyle(
                              color: wb.primaryText,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                            decoration: InputDecoration(
                              hintText: '搜索命令…',
                              hintStyle: TextStyle(color: wb.textMuted),
                              prefixIcon: Icon(
                                Icons.search_rounded,
                                color: wb.textMuted,
                              ),
                              filled: true,
                              fillColor:
                                  wb.bg.withValues(alpha: 0.45),
                              border: OutlineInputBorder(
                                borderRadius: DesktopUi.rSm,
                                borderSide: BorderSide.none,
                              ),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                            ),
                          ),
                        ),
                        Flexible(
                          child: ListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            itemCount: _filtered.length,
                            itemBuilder: (context, i) {
                              final c = _filtered[i];
                              final sel = i == _selected;
                              return DesktopListRow(
                                selected: sel,
                                leading: Icon(
                                  c.icon,
                                  size: 18,
                                  color: sel ? wb.accentBlue : wb.textMuted,
                                ),
                                title: Text(c.title),
                                subtitle: Text(
                                  c.category +
                                      (c.subtitle == null
                                          ? ''
                                          : ' · ${c.subtitle}'),
                                ),
                                trailing: c.shortcut == null
                                    ? null
                                    : Text(
                                        c.shortcut!,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                          color: wb.textMuted,
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
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
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
        ],
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
    this.shortcut,
  });

  final String title;
  final String? subtitle;
  final String category;
  final IconData icon;
  final String keywords;
  final String? shortcut;
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
