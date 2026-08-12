import 'package:flutter/material.dart';

import '../services/workbench_desktop_shortcuts.dart';
import '../theme/workbench_theme.dart';

/// 远程桌面键盘快捷键速查表。
Future<void> showDesktopShortcutsCheatsheet(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => const _DesktopShortcutsCheatsheetDialog(),
  );
}

class _DesktopShortcutsCheatsheetDialog extends StatelessWidget {
  const _DesktopShortcutsCheatsheetDialog();

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final mod = workbenchUsesMetaPrimaryModifier() ? '⌘' : 'Ctrl';
    final groups = _shortcutGroups(mod);

    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      backgroundColor: wb.panelElevated,
      title: Text(
        '键盘快捷键',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: wb.primaryText),
      ),
      content: SizedBox(
        width: (size.width - 48).clamp(280.0, 480.0),
        height: (size.height * 0.7).clamp(280.0, 420.0),
        child: ListView.builder(
          itemCount: groups.length,
          itemBuilder: (context, i) {
            final g = groups[i];
            return Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    g.title,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: wb.accentBlue,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final row in g.rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              row.label,
                              style: TextStyle(
                                fontSize: 13,
                                color: wb.primaryText,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              row.keys,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                color: wb.secondaryText,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('关闭', style: TextStyle(color: wb.accentBlue)),
        ),
      ],
    );
  }
}

class _Group {
  const _Group(this.title, this.rows);
  final String title;
  final List<_Row> rows;
}

class _Row {
  const _Row(this.label, this.keys);
  final String label;
  final String keys;
}

List<_Group> _shortcutGroups(String mod) {
  return [
    _Group('窗口管理', [
      _Row('关闭窗口', '$mod+W'),
      _Row('最小化', '$mod+M'),
      _Row('置顶 / 取消置顶', '$mod+T'),
      _Row('循环切换窗口', '$mod+`'),
      _Row('反向循环窗口', '$mod+Shift+`'),
      _Row('左半屏', '$mod+Alt+←'),
      _Row('右半屏', '$mod+Alt+→'),
      _Row('最大化', '$mod+Alt+↑'),
      _Row('还原 / 最小化', '$mod+Alt+↓'),
    ]),
    _Group('工作区', [
      _Row('切换到工作区 1–9', '$mod+1 … $mod+9'),
      _Row('下一个工作区', 'Ctrl+→'),
      _Row('上一个工作区', 'Ctrl+←'),
      _Row('窗口移到下一工作区', 'Ctrl+Shift+→'),
      _Row('窗口移到上一工作区', 'Ctrl+Shift+←'),
    ]),
    _Group('启动与面板', [
      _Row('新终端', '$mod+N'),
      _Row('运行命令', '$mod+R'),
      _Row('命令面板', '$mod+Shift+P'),
    ]),
    _Group('浏览器', [
      _Row('新标签', '$mod+T'),
      _Row('关闭标签', '$mod+W'),
      _Row('刷新', '$mod+R'),
      _Row('聚焦地址栏', '$mod+L'),
      _Row('下一标签', 'Ctrl+Tab / $mod+Tab'),
      _Row('跳到标签 1–8', '$mod+1 … $mod+8'),
    ]),
    _Group('编辑器', [
      _Row('保存', '$mod+S'),
      _Row('查找', '$mod+F'),
      _Row('查找替换', '$mod+H'),
      _Row('查找下一个', '$mod+G'),
      _Row('查找上一个', '$mod+Shift+G'),
      _Row('跳行', '$mod+L'),
    ]),
    _Group('终端字号', [
      _Row('放大', '$mod+= / $mod++'),
      _Row('缩小', '$mod+-'),
      _Row('重置字号', '$mod+0'),
    ]),
  ];
}
