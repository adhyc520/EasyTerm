import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/llm_openai_chat_service.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';

/// OpenAI 兼容 Chat Completions：基础 URL、模型与 API Key。
class WorkbenchLlmSettingsDialog extends StatefulWidget {
  const WorkbenchLlmSettingsDialog({super.key, required this.settings});

  final WorkbenchSettingsStore settings;

  @override
  State<WorkbenchLlmSettingsDialog> createState() =>
      _WorkbenchLlmSettingsDialogState();
}

class _WorkbenchLlmSettingsDialogState
    extends State<WorkbenchLlmSettingsDialog> {
  late final TextEditingController _base = TextEditingController(
    text: widget.settings.llmBaseUrl,
  );
  late final TextEditingController _model = TextEditingController(
    text: widget.settings.llmModel,
  );
  late final TextEditingController _key = TextEditingController(
    text: widget.settings.llmApiKey,
  );
  bool _obscureKey = true;
  bool _testingConnection = false;

  @override
  void dispose() {
    _base.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    widget.settings.llmBaseUrl = _base.text.trim();
    widget.settings.llmModel = _model.text.trim();
    widget.settings.llmApiKey = _key.text;
    await widget.settings.persist();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _testConnection() async {
    final l = AppLocalizations.of(context)!;
    final base = _base.text.trim();
    final model = _model.text.trim();
    if (base.isEmpty || model.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.llmMissingConfig)));
      return;
    }
    setState(() => _testingConnection = true);
    try {
      await LlmOpenAiChatService(
        baseUrl: base,
        model: model,
        apiKey: _key.text,
      ).testConnection();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.llmTestSuccess)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.llmTestFailed('$e'))));
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: context.wb.panelElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.smart_toy_outlined, color: context.wb.accentBlue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l.llmSettingsTitle,
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
                l.llmSettingsHint,
                style: TextStyle(
                  color: context.wb.textMuted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _base,
                style: TextStyle(color: context.wb.primaryText, fontSize: 13),
                decoration: InputDecoration(
                  labelText: l.llmBaseUrlLabel,
                  hintText: l.llmBaseUrlHint,
                  filled: true,
                  fillColor: context.wb.panel,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _model,
                style: TextStyle(color: context.wb.primaryText, fontSize: 13),
                decoration: InputDecoration(
                  labelText: l.llmModelLabel,
                  hintText: l.llmModelHint,
                  filled: true,
                  fillColor: context.wb.panel,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _key,
                obscureText: _obscureKey,
                style: TextStyle(
                  color: context.wb.primaryText,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  labelText: l.llmApiKeyLabel,
                  hintText: l.llmApiKeyHint,
                  filled: true,
                  fillColor: context.wb.panel,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  suffixIcon: IconButton(
                    tooltip: l.llmToggleKeyVisibility,
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                    icon: Icon(
                      _obscureKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Tooltip(
                    message: l.llmTestConnectionTooltip,
                    child: OutlinedButton.icon(
                      onPressed: _testingConnection
                          ? null
                          : () => unawaited(_testConnection()),
                      icon: _testingConnection
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: context.wb.accentBlue,
                              ),
                            )
                          : Icon(
                              Icons.wifi_tethering_outlined,
                              size: 20,
                              color: context.wb.accentBlue,
                            ),
                      label: Text(l.llmTestConnection),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _testingConnection
                        ? null
                        : () => Navigator.pop(context),
                    child: Text(l.settingsCancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _testingConnection ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: context.wb.accentBlue,
                    ),
                    child: Text(l.settingsSave),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
