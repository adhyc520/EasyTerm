import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
        const SnackBar(content: Text('请填写有效的数字（见各项取值范围）')),
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
      fillColor: WorkbenchPalette.panel,
      border: const UnderlineInputBorder(borderSide: BorderSide(color: WorkbenchPalette.border)),
      enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: WorkbenchPalette.border)),
      focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: WorkbenchPalette.accentBlue)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: WorkbenchPalette.panelElevated,
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
                  const Icon(Icons.tune_rounded, color: WorkbenchPalette.accentBlue),
                  const SizedBox(width: 10),
                  Text(
                    '终端与连接',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: WorkbenchPalette.textMuted),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: WorkbenchPalette.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '连接',
                      style: TextStyle(color: WorkbenchPalette.textMuted.withValues(alpha: 0.9), fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    _row(
                      '超时（秒）',
                      TextField(
                        controller: _timeoutCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: _decoration('5–600，默认 30'),
                      ),
                    ),
                    _row(
                      '重试次数',
                      TextField(
                        controller: _retryCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: _decoration('失败后的额外重试，0–20'),
                      ),
                    ),
                    _row(
                      '重试间隔（秒）',
                      TextField(
                        controller: _intervalCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: _decoration('1–300'),
                      ),
                    ),
                    _row(
                      'Keep-alive（秒）',
                      TextField(
                        controller: _keepAliveCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: _decoration('0–3600，0 为关闭'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '终端',
                      style: TextStyle(color: WorkbenchPalette.textMuted.withValues(alpha: 0.9), fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    _row(
                      'PTY 列数',
                      TextField(
                        controller: _ptyColsCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: _decoration('40–512，新连接生效'),
                      ),
                    ),
                    _row(
                      'PTY 行数',
                      TextField(
                        controller: _ptyRowsCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: _decoration('8–256，新连接生效'),
                      ),
                    ),
                    _row(
                      '终端类型',
                      Theme(
                        data: Theme.of(context).copyWith(canvasColor: WorkbenchPalette.panelElevated),
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _termType,
                          dropdownColor: WorkbenchPalette.panelElevated,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          underline: const SizedBox(),
                          items: WorkbenchSettingsStore.terminalTypeChoices
                              .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                              .toList(),
                          onChanged: (v) => setState(() => _termType = v ?? _termType),
                        ),
                      ),
                    ),
                    _row(
                      '缓冲区大小',
                      TextField(
                        controller: _bufferCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: _decoration('行数 100–100000，新连接生效'),
                      ),
                    ),
                    _row(
                      '字体大小',
                      TextField(
                        controller: _fontSizeCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(color: Colors.white),
                        decoration: _decoration('6–48'),
                      ),
                    ),
                    _row(
                      '字体',
                      Theme(
                        data: Theme.of(context).copyWith(canvasColor: WorkbenchPalette.panelElevated),
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _fontFamily,
                          dropdownColor: WorkbenchPalette.panelElevated,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          underline: const SizedBox(),
                          items: WorkbenchSettingsStore.fontFamilyChoices
                              .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                              .toList(),
                          onChanged: (v) => setState(() => _fontFamily = v ?? _fontFamily),
                        ),
                      ),
                    ),
                    _row(
                      '选择复制',
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
                        '选中后自动复制到剪贴板（有短暂防抖）',
                        style: TextStyle(fontSize: 11, color: WorkbenchPalette.textMuted.withValues(alpha: 0.85)),
                      ),
                    ),
                    _row(
                      '右键粘贴',
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
                        '在终端区域使用鼠标右键粘贴剪贴板文本',
                        style: TextStyle(fontSize: 11, color: WorkbenchPalette.textMuted.withValues(alpha: 0.85)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: WorkbenchPalette.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(backgroundColor: WorkbenchPalette.accentBlue),
                    child: const Text('保存'),
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
