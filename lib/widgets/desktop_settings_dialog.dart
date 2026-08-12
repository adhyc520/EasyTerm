import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../desktop/desktop_window_manager.dart';
import '../desktop/widgets/desktop_ui.dart';
import '../services/desktop_settings_store.dart';
import '../theme/workbench_theme.dart';

/// 内置壁纸预设（渐变）。值写入 [DesktopSettingsStore.wallpaper]。
const kDesktopWallpaperPresets = <({String id, String label, List<Color> colors})>[
  (
    id: '',
    label: '默认',
    colors: [
      Color(0xFF0B1220),
      Color(0xFF152238),
      Color(0xFF1A3350),
      Color(0xFF0E1A2A),
    ],
  ),
  (
    id: 'preset:dusk',
    label: '暮色',
    colors: [
      Color(0xFF1A1028),
      Color(0xFF3D1F4A),
      Color(0xFF6B2D5C),
      Color(0xFF1E1530),
    ],
  ),
  (
    id: 'preset:forest',
    label: '森林',
    colors: [
      Color(0xFF0C1A14),
      Color(0xFF163528),
      Color(0xFF1E4A35),
      Color(0xFF0A1610),
    ],
  ),
  (
    id: 'preset:slate',
    label: '岩灰',
    colors: [
      Color(0xFF14161A),
      Color(0xFF22262E),
      Color(0xFF2C323C),
      Color(0xFF121418),
    ],
  ),
  (
    id: 'preset:ocean',
    label: '深海',
    colors: [
      Color(0xFF061820),
      Color(0xFF0C3A4A),
      Color(0xFF0E5A68),
      Color(0xFF052028),
    ],
  ),
];

List<Color>? desktopWallpaperPresetColors(String wallpaper) {
  for (final p in kDesktopWallpaperPresets) {
    if (p.id == wallpaper) return p.colors;
  }
  return null;
}

bool desktopWallpaperIsImage(String wallpaper) {
  if (wallpaper.isEmpty || wallpaper.startsWith('preset:')) return false;
  return wallpaper.startsWith('file:') || wallpaper.startsWith('/');
}

String? desktopWallpaperImagePath(String wallpaper) {
  if (!desktopWallpaperIsImage(wallpaper)) return null;
  if (wallpaper.startsWith('file:')) {
    return Uri.parse(wallpaper).toFilePath();
  }
  return wallpaper;
}

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
  late String _wallpaper = _s.wallpaper;

  Future<void> _save() async {
    _s.wallpaper = _wallpaper;
    await _s.persist();
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

  Future<void> _pickWallpaper() async {
    try {
      final r = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        lockParentWindow:
            !kIsWeb && defaultTargetPlatform == TargetPlatform.windows,
      );
      if (!mounted) return;
      if (r == null || r.files.isEmpty) return;
      final path = r.files.single.path;
      if (path == null || path.isEmpty) return;
      setState(() => _wallpaper = path);
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择壁纸失败：${e.message ?? e.code}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择壁纸失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final imagePath = desktopWallpaperImagePath(_wallpaper);
    return AlertDialog(
      backgroundColor: wb.panelElevated,
      title: Text('桌面设置', style: TextStyle(color: wb.primaryText)),
      content: SizedBox(
        width: 440,
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
                title: Text('任务栏自动隐藏', style: TextStyle(color: wb.primaryText)),
                value: _s.taskbarAutohide,
                onChanged: (v) => setState(() => _s.taskbarAutohide = v),
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
              Text(
                '吸附边缘阈值 (${_s.snapEdgePx.round()}px)',
                style: TextStyle(color: wb.secondaryText, fontSize: 12),
              ),
              Slider(
                value: _s.snapEdgePx,
                min: 8,
                max: 80,
                onChanged: (v) => setState(() => _s.snapEdgePx = v),
              ),
              Text(
                '默认窗口宽度 ${(_s.defaultWindowWFrac * 100).round()}%',
                style: TextStyle(color: wb.secondaryText, fontSize: 12),
              ),
              Slider(
                value: _s.defaultWindowWFrac,
                min: 0.25,
                max: 1,
                onChanged: (v) => setState(() => _s.defaultWindowWFrac = v),
              ),
              Text(
                '默认窗口高度 ${(_s.defaultWindowHFrac * 100).round()}%',
                style: TextStyle(color: wb.secondaryText, fontSize: 12),
              ),
              Slider(
                value: _s.defaultWindowHFrac,
                min: 0.25,
                max: 1,
                onChanged: (v) => setState(() => _s.defaultWindowHFrac = v),
              ),
              const SizedBox(height: 12),
              Text(
                '壁纸',
                style: TextStyle(
                  color: wb.primaryText,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: DesktopUi.rSm,
                child: SizedBox(
                  height: 88,
                  width: double.infinity,
                  child: _WallpaperPreview(
                    wallpaper: _wallpaper,
                    imagePath: imagePath,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in kDesktopWallpaperPresets)
                    _PresetChip(
                      label: p.label,
                      colors: p.colors,
                      selected: _wallpaper == p.id,
                      onTap: () => setState(() => _wallpaper = p.id),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => unawaited(_pickWallpaper()),
                    icon: const Icon(Icons.image_outlined, size: 18),
                    label: const Text('选择图片…'),
                  ),
                  const SizedBox(width: 8),
                  if (desktopWallpaperIsImage(_wallpaper))
                    TextButton(
                      onPressed: () => setState(() => _wallpaper = ''),
                      child: const Text('清除图片'),
                    ),
                ],
              ),
              if (imagePath != null) ...[
                const SizedBox(height: 6),
                Text(
                  imagePath.split(Platform.pathSeparator).last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: wb.textMuted),
                ),
              ],
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
          onPressed: () => unawaited(_save()),
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

class _WallpaperPreview extends StatelessWidget {
  const _WallpaperPreview({
    required this.wallpaper,
    required this.imagePath,
  });

  final String wallpaper;
  final String? imagePath;

  @override
  Widget build(BuildContext context) {
    if (imagePath != null) {
      final file = File(imagePath!);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => _gradientFallback(context),
        );
      }
    }
    return _gradientFallback(context);
  }

  Widget _gradientFallback(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final preset = desktopWallpaperPresetColors(wallpaper);
    final colors = preset ??
        (isDark
            ? kDesktopWallpaperPresets.first.colors
            : const [
                Color(0xFFDCE6F5),
                Color(0xFFC5D5EC),
                Color(0xFFB8C8E0),
                Color(0xFFE8EEF7),
              ]);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.colors,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final List<Color> colors;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          width: 72,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? wb.accentBlue : wb.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  height: 28,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: colors,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? wb.accentBlue : wb.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
