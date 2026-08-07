import 'package:flutter/material.dart';

import '../desktop/desktop_window_manager.dart';
import '../services/desktop_settings_store.dart';
import '../theme/workbench_theme.dart';

Future<void> showDesktopSettingsDialog(
  BuildContext context, {
  required DesktopWindowManager wm,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _DesktopSettingsDialog(wm: wm),
  );
}

class _DesktopSettingsDialog extends StatefulWidget {
  const _DesktopSettingsDialog({required this.wm});
  final DesktopWindowManager wm;

  @override
  State<_DesktopSettingsDialog> createState() => _DesktopSettingsDialogState();
}

class _DesktopSettingsDialogState extends State<_DesktopSettingsDialog> {
  late final DesktopSettingsStore _s = widget.wm.desktopSettings;
  late final TextEditingController _wallpaperCtrl =
      TextEditingController(text: _s.wallpaper);

  @override
  void dispose() {
    _wallpaperCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _s.wallpaper = _wallpaperCtrl.text.trim();
    await _s.persist();
    // 工作区数变更时同步
    final want = _s.workspaceCount.clamp(1, 9);
    while (widget.wm.workspaces.length < want) {
      widget.wm.addWorkspace();
    }
    while (widget.wm.workspaces.length > want) {
      widget.wm.removeWorkspace(widget.wm.workspaces.length - 1);
    }
    widget.wm.requestRebuild();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return AlertDialog(
      backgroundColor: wb.panelElevated,
      title: Text('桌面设置', style: TextStyle(color: wb.primaryText)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _row(
                '工作区数量',
                Row(
                  children: [
                    IconButton(
                      onPressed: _s.workspaceCount <= 1
                          ? null
                          : () => setState(() => _s.workspaceCount--),
                      icon: const Icon(Icons.remove_rounded, size: 18),
                    ),
                    Text(
                      '${_s.workspaceCount}',
                      style: TextStyle(color: wb.primaryText),
                    ),
                    IconButton(
                      onPressed: _s.workspaceCount >= 9
                          ? null
                          : () => setState(() => _s.workspaceCount++),
                      icon: const Icon(Icons.add_rounded, size: 18),
                    ),
                  ],
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('贴边吸附', style: TextStyle(color: wb.primaryText)),
                value: _s.snapEnabled,
                onChanged: (v) => setState(() => _s.snapEnabled = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('桌面网格', style: TextStyle(color: wb.primaryText)),
                value: _s.showGrid,
                onChanged: (v) => setState(() => _s.showGrid = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('托盘显示远端时钟', style: TextStyle(color: wb.primaryText)),
                value: _s.trayShowClock,
                onChanged: (v) => setState(() => _s.trayShowClock = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('托盘显示 CPU/内存', style: TextStyle(color: wb.primaryText)),
                value: _s.trayShowMetrics,
                onChanged: (v) => setState(() => _s.trayShowMetrics = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('日志默认实时跟随', style: TextStyle(color: wb.primaryText)),
                value: _s.liveLogsDefault,
                onChanged: (v) => setState(() => _s.liveLogsDefault = v),
              ),
              const SizedBox(height: 8),
              Text('吸附边缘阈值 (${_s.snapEdgePx.round()}px)',
                  style: TextStyle(color: wb.secondaryText, fontSize: 12)),
              Slider(
                value: _s.snapEdgePx,
                min: 8,
                max: 80,
                onChanged: (v) => setState(() => _s.snapEdgePx = v),
              ),
              Text(
                '默认窗口宽度 ${( _s.defaultWindowWFrac * 100).round()}%',
                style: TextStyle(color: wb.secondaryText, fontSize: 12),
              ),
              Slider(
                value: _s.defaultWindowWFrac,
                min: 0.25,
                max: 1,
                onChanged: (v) => setState(() => _s.defaultWindowWFrac = v),
              ),
              Text(
                '默认窗口高度 ${( _s.defaultWindowHFrac * 100).round()}%',
                style: TextStyle(color: wb.secondaryText, fontSize: 12),
              ),
              Slider(
                value: _s.defaultWindowHFrac,
                min: 0.25,
                max: 1,
                onChanged: (v) => setState(() => _s.defaultWindowHFrac = v),
              ),
              const SizedBox(height: 4),
              TextField(
                style: TextStyle(color: wb.primaryText, fontSize: 13),
                decoration: InputDecoration(
                  labelText: '壁纸路径（本地文件 URI，可空）',
                  labelStyle: TextStyle(color: wb.textMuted),
                  hintText: 'file:///… 或留空用默认渐变',
                  hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
                ),
                controller: _wallpaperCtrl,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _row(String label, Widget trailing) {
    final wb = context.wb;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: wb.primaryText)),
          ),
          trailing,
        ],
      ),
    );
  }
}
