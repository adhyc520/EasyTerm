import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';

/// 界面语言与浅色 / 深色外观（独立于终端与连接设置）。
class WorkbenchInterfaceSettingsDialog extends StatelessWidget {
  const WorkbenchInterfaceSettingsDialog({super.key, required this.settings});

  final WorkbenchSettingsStore settings;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: context.wb.panelElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.palette_outlined, color: context.wb.accentBlue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l.interfaceSettingsTitle,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: context.wb.primaryText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(
                      Icons.close_rounded,
                      color: context.wb.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Divider(height: 1, color: context.wb.border),
              const SizedBox(height: 12),
              Text(
                l.settingsSectionLanguage,
                style: TextStyle(
                  color: context.wb.textMuted.withValues(alpha: 0.9),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              ListenableBuilder(
                listenable: settings,
                builder: (context, _) {
                  return InputDecorator(
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: context.wb.panel,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 2,
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: settings.appLocaleCode,
                        dropdownColor: context.wb.panelElevated,
                        style: TextStyle(
                          color: context.wb.primaryText,
                          fontSize: 14,
                        ),
                        iconEnabledColor: context.wb.textMuted,
                        items: [
                          DropdownMenuItem(
                            value: 'zh',
                            child: Text(l.settingsLanguageChinese),
                          ),
                          DropdownMenuItem(
                            value: 'en',
                            child: Text(l.settingsLanguageEnglish),
                          ),
                        ],
                        onChanged: (v) async {
                          if (v == null) return;
                          settings.appLocaleCode = v;
                          await settings.persist();
                        },
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),
              Text(
                l.interfaceThemeLabel,
                style: TextStyle(
                  color: context.wb.textMuted.withValues(alpha: 0.9),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              ListenableBuilder(
                listenable: settings,
                builder: (context, _) {
                  return SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: 'dark',
                        label: Text(l.interfaceThemeDark),
                      ),
                      ButtonSegment(
                        value: 'light',
                        label: Text(l.interfaceThemeLight),
                      ),
                      ButtonSegment(
                        value: 'system',
                        label: Text(l.interfaceThemeSystem),
                      ),
                    ],
                    selected: {settings.appThemeMode},
                    onSelectionChanged: (s) async {
                      if (s.isEmpty) return;
                      settings.appThemeMode = s.first;
                      await settings.persist();
                    },
                  );
                },
              ),
              const SizedBox(height: 20),
              Text(
                l.settingsUiScaleLabel,
                style: TextStyle(
                  color: context.wb.textMuted.withValues(alpha: 0.9),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              ListenableBuilder(
                listenable: settings,
                builder: (context, _) {
                  final scale = settings.uiScaleFactor;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value: scale.clamp(0.75, 2.0),
                              min: 0.75,
                              max: 2.0,
                              divisions: 25,
                              label: scale.toStringAsFixed(2),
                              onChanged: (v) {
                                settings.setUiScaleFactor(v);
                              },
                              onChangeEnd: (v) async {
                                settings.setUiScaleFactor(v);
                                await settings.persist();
                              },
                            ),
                          ),
                          SizedBox(
                            width: 48,
                            child: Text(
                              '${(scale * 100).round()}%',
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                color: context.wb.primaryText,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        l.settingsUiScaleDescription,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.wb.textMuted.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  style: FilledButton.styleFrom(
                    backgroundColor: context.wb.accentBlue,
                  ),
                  child: Text(l.interfaceDone),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
