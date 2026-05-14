import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';

/// 终端与连接相关偏好设置（与常见 SSH 客户端项对齐）。
class WorkbenchTerminalSettingsDialog extends StatefulWidget {
  const WorkbenchTerminalSettingsDialog({super.key, required this.settings});

  final WorkbenchSettingsStore settings;

  @override
  State<WorkbenchTerminalSettingsDialog> createState() => _WorkbenchTerminalSettingsDialogState();
}

class _WorkbenchTerminalSettingsDialogState extends State<WorkbenchTerminalSettingsDialog> {
  late final TextEditingController _timeoutCtrl;
  late final TextEditingController _retryCtrl;
  late final TextEditingController _intervalCtrl;
  late final TextEditingController _keepAliveCtrl;
  late final TextEditingController _ptyColsCtrl;
  late final TextEditingController _ptyRowsCtrl;
  late final TextEditingController _bufferCtrl;
  late final TextEditingController _fontSizeCtrl;

  late String _termType;
  late String _fontFamily;
  late bool _selectCopy;
  late bool _rightPaste;

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _timeoutCtrl = TextEditingController(text: '${s.connectTimeoutSec}');
    _retryCtrl = TextEditingController(text: '${s.connectRetryCount}');
    _intervalCtrl = TextEditingController(text: '${s.retryIntervalSec}');
    _keepAliveCtrl = TextEditingController(text: '${s.sshKeepAliveSec}');
    _ptyColsCtrl = TextEditingController(text: '${s.ptyDefaultColumns}');
    _ptyRowsCtrl = TextEditingController(text: '${s.ptyDefaultRows}');
    _bufferCtrl = TextEditingController(text: '${s.terminalMaxLines}');
    _fontSizeCtrl = TextEditingController(text: '${s.terminalFontSize}');
    _termType = s.terminalTermType;
    _fontFamily = s.terminalFontFamily;
    _selectCopy = s.selectToCopy;
    _rightPaste = s.rightClickPaste;
  }

  @override
  void dispose() {
    _timeoutCtrl.dispose();
    _retryCtrl.dispose();
    _intervalCtrl.dispose();
    _keepAliveCtrl.dispose();
    _ptyColsCtrl.dispose();
    _ptyRowsCtrl.dispose();
    _bufferCtrl.dispose();
    _fontSizeCtrl.dispose();
    super.dispose();
  }

  int? _parseInt(TextEditingController c, {required int min, required int max}) {
    final v = int.tryParse(c.text.trim());
    if (v == null) return null;
    return v.clamp(min, max);
  }

  double? _parseDouble(TextEditingController c, {required double min, required double max}) {
    final v = double.tryParse(c.text.trim());
    if (v == null) return null;
    if (v < min || v > max) return null;
    return v;
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context)!;
    final timeout = _parseInt(_timeoutCtrl, min: 5, max: 600);
    final retries = _parseInt(_retryCtrl, min: 0, max: 20);
    final interval = _parseInt(_intervalCtrl, min: 1, max: 300);
    final keepAlive = _parseInt(_keepAliveCtrl, min: 0, max: 3600);
    final ptyCols = _parseInt(_ptyColsCtrl, min: 40, max: 512);
    final ptyRows = _parseInt(_ptyRowsCtrl, min: 8, max: 256);
    final buffer = _parseInt(_bufferCtrl, min: 100, max: 100000);
    final fontSize = _parseDouble(_fontSizeCtrl, min: 6, max: 48);
    if (timeout == null ||
        retries == null ||
        interval == null ||
        keepAlive == null ||
        ptyCols == null ||
        ptyRows == null ||
        buffer == null ||
        fontSize == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.settingsInvalidNumbers)),
      );
      return;
    }
    final s = widget.settings;
    s.connectTimeoutSec = timeout;
    s.connectRetryCount = retries;
    s.retryIntervalSec = interval;
    s.sshKeepAliveSec = keepAlive;
    s.ptyDefaultColumns = ptyCols;
    s.ptyDefaultRows = ptyRows;
    s.terminalMaxLines = buffer;
    s.terminalFontSize = fontSize;
    s.terminalTermType = _termType;
    s.terminalFontFamily = _fontFamily;
    s.selectToCopy = _selectCopy;
    s.rightClickPaste = _rightPaste;
    await s.persist();
    if (mounted) Navigator.of(context).pop();
  }

  Widget _row(String label, Widget field) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 150,
            child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ),
          Expanded(child: field),
        ],
      ),
    );
  }

  InputDecoration _decoration(String hint) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: context.wb.panel,
      border: UnderlineInputBorder(borderSide: BorderSide(color: context.wb.border)),
      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.wb.border)),
      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.wb.accentBlue)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: context.wb.panelElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.tune_rounded, color: context.wb.accentBlue),
                  const SizedBox(width: 10),
                  Text(
                    l.settingsDialogTitle,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: context.wb.primaryText,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, color: context.wb.textMuted),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: context.wb.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l.settingsSectionConnection,
                      style: TextStyle(color: context.wb.textMuted.withValues(alpha: 0.9), fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    _row(
                      l.settingsTimeoutLabel,
                      TextField(
                        controller: _timeoutCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: TextStyle(color: context.wb.primaryText),
                        decoration: _decoration(l.settingsTimeoutHint),
                      ),
                    ),
                    _row(
                      l.settingsRetryLabel,
                      TextField(
                        controller: _retryCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: TextStyle(color: context.wb.primaryText),
                        decoration: _decoration(l.settingsRetryHint),
                      ),
                    ),
                    _row(
                      l.settingsRetryIntervalLabel,
                      TextField(
                        controller: _intervalCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: TextStyle(color: context.wb.primaryText),
                        decoration: _decoration(l.settingsRetryIntervalHint),
                      ),
                    ),
                    _row(
                      l.settingsKeepAliveLabel,
                      TextField(
                        controller: _keepAliveCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: TextStyle(color: context.wb.primaryText),
                        decoration: _decoration(l.settingsKeepAliveHint),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l.settingsSectionTerminal,
                      style: TextStyle(color: context.wb.textMuted.withValues(alpha: 0.9), fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    _row(
                      l.settingsPtyColsLabel,
                      TextField(
                        controller: _ptyColsCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: TextStyle(color: context.wb.primaryText),
                        decoration: _decoration(l.settingsPtyColsHint),
                      ),
                    ),
                    _row(
                      l.settingsPtyRowsLabel,
                      TextField(
                        controller: _ptyRowsCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: TextStyle(color: context.wb.primaryText),
                        decoration: _decoration(l.settingsPtyRowsHint),
                      ),
                    ),
                    _row(
                      l.settingsTermTypeLabel,
                      Theme(
                        data: Theme.of(context).copyWith(canvasColor: context.wb.panelElevated),
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _termType,
                          dropdownColor: context.wb.panelElevated,
                          style: TextStyle(color: context.wb.primaryText, fontSize: 14),
                          underline: const SizedBox(),
                          items: WorkbenchSettingsStore.terminalTypeChoices
                              .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                              .toList(),
                          onChanged: (v) => setState(() => _termType = v ?? _termType),
                        ),
                      ),
                    ),
                    _row(
                      l.settingsBufferLabel,
                      TextField(
                        controller: _bufferCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: TextStyle(color: context.wb.primaryText),
                        decoration: _decoration(l.settingsBufferHint),
                      ),
                    ),
                    _row(
                      l.settingsFontSizeLabel,
                      TextField(
                        controller: _fontSizeCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: TextStyle(color: context.wb.primaryText),
                        decoration: _decoration(l.settingsFontSizeHint),
                      ),
                    ),
                    _row(
                      l.settingsFontFamilyLabel,
                      Theme(
                        data: Theme.of(context).copyWith(canvasColor: context.wb.panelElevated),
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _fontFamily,
                          dropdownColor: context.wb.panelElevated,
                          style: TextStyle(color: context.wb.primaryText, fontSize: 14),
                          underline: const SizedBox(),
                          items: WorkbenchSettingsStore.fontFamilyChoices
                              .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                              .toList(),
                          onChanged: (v) => setState(() => _fontFamily = v ?? _fontFamily),
                        ),
                      ),
                    ),
                    _row(
                      l.settingsSelectCopyLabel,
                      Align(
                        alignment: Alignment.centerRight,
                        child: Switch(
                          value: _selectCopy,
                          onChanged: (v) => setState(() => _selectCopy = v),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 150, bottom: 4),
                      child: Text(
                        l.settingsSelectCopyDescription,
                        style: TextStyle(fontSize: 11, color: context.wb.textMuted.withValues(alpha: 0.85)),
                      ),
                    ),
                    _row(
                      l.settingsRightClickPasteLabel,
                      Align(
                        alignment: Alignment.centerRight,
                        child: Switch(
                          value: _rightPaste,
                          onChanged: (v) => setState(() => _rightPaste = v),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 150),
                      child: Text(
                        l.settingsRightClickPasteDescription,
                        style: TextStyle(fontSize: 11, color: context.wb.textMuted.withValues(alpha: 0.85)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: context.wb.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l.settingsCancel),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(backgroundColor: context.wb.accentBlue),
                    child: Text(l.settingsSave),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
