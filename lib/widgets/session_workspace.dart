import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../l10n/app_localizations.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';

/// 仅终端区域（右侧大面板），连接状态与 [SshWorkspaceController] 同步。
class SessionTerminalPane extends StatefulWidget {
  const SessionTerminalPane({
    super.key,
    required this.controller,
    required this.workbenchSettings,
    required this.autofocusTerminal,
  });

  final SshWorkspaceController controller;
  final WorkbenchSettingsStore workbenchSettings;
  final bool autofocusTerminal;

  @override
  State<SessionTerminalPane> createState() => _SessionTerminalPaneState();
}

class _SessionTerminalPaneState extends State<SessionTerminalPane> {
  late final TerminalController _viewController = TerminalController();
  Terminal? _terminalBound;
  Timer? _selectCopyDebounce;

  @override
  void initState() {
    super.initState();
    widget.workbenchSettings.addListener(_onWorkbenchSettingsChanged);
    widget.controller.addListener(_onControllerChanged);
    _syncTerminalBufferListener();
  }

  @override
  void dispose() {
    _selectCopyDebounce?.cancel();
    _terminalBound?.removeListener(_onTerminalBufferChanged);
    widget.workbenchSettings.removeListener(_onWorkbenchSettingsChanged);
    widget.controller.removeListener(_onControllerChanged);
    _viewController.dispose();
    super.dispose();
  }

  void _onWorkbenchSettingsChanged() {
    if (mounted) setState(() {});
  }

  void _onControllerChanged() {
    _syncTerminalBufferListener();
    if (mounted) setState(() {});
  }

  void _syncTerminalBufferListener() {
    final t = widget.controller.terminal;
    if (identical(t, _terminalBound)) return;
    _terminalBound?.removeListener(_onTerminalBufferChanged);
    _terminalBound = t;
    _terminalBound?.addListener(_onTerminalBufferChanged);
  }

  void _onTerminalBufferChanged() {
    if (!widget.workbenchSettings.selectToCopy) return;
    final term = widget.controller.terminal;
    if (term == null) return;
    if (_viewController.selection == null) return;
    _selectCopyDebounce?.cancel();
    _selectCopyDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      final sel = _viewController.selection;
      if (sel == null) return;
      final text = term.buffer.getText(sel);
      if (text.isEmpty) return;
      unawaited(Clipboard.setData(ClipboardData(text: text)));
    });
  }

  Future<void> _onSecondaryTapPaste(TapUpDetails details, CellOffset offset) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    widget.controller.terminal?.paste(text);
    _viewController.clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          final ws = widget.workbenchSettings;
          final l = AppLocalizations.of(context)!;

          if (c.connecting && !c.connected) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: context.wb.accentBlue),
                  const SizedBox(height: 16),
                  Text(
                    l.terminalConnecting,
                    style: TextStyle(color: context.wb.textMuted),
                  ),
                ],
              ),
            );
          }
          if (!c.connected && (c.error != null && c.error!.isNotEmpty)) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.error_outline_rounded, size: 40, color: Color(0xFFEF4444)),
                      const SizedBox(height: 12),
                      Text(l.terminalConnectionFailed, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: context.wb.primaryText)),
                      const SizedBox(height: 8),
                      SelectableText(
                        c.error!,
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: context.wb.textMuted),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: context.wb.accentBlue),
                        onPressed: () async {
                          await c.disconnect();
                          await c.connect();
                        },
                        child: Text(l.terminalRetry),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          if (!c.connected) {
            return Center(
              child: Text(
                l.terminalWaiting,
                style: TextStyle(color: context.wb.textMuted),
              ),
            );
          }

          final term = c.terminal;
          if (term == null) {
            return Center(child: CircularProgressIndicator(color: context.wb.accentBlue));
          }

          final textStyle = TerminalStyle(
            fontSize: ws.terminalFontSize,
            fontFamily: ws.terminalFontFamily,
          );

          return DecoratedBox(
            decoration: BoxDecoration(
              color: context.wb.terminalBg,
              border: Border(left: BorderSide(color: context.wb.border)),
            ),
            child: TerminalView(
              term,
              controller: _viewController,
              theme: TerminalThemes.defaultTheme,
              textStyle: textStyle,
              autofocus: widget.autofocusTerminal,
              // macOS/desktop: TextInput + hardware keys can duplicate KeyDown and
              // trip HardwareKeyboard assertions; IME path is for mobile keyboards.
              hardwareKeyboardOnly: !kIsWeb,
              readOnly: false,
              autoResize: true,
              onSecondaryTapDown: ws.rightClickPaste ? (details, offset) {} : null,
              onSecondaryTapUp: ws.rightClickPaste ? _onSecondaryTapPaste : null,
            ),
          );
        },
      ),
    );
  }
}

/// 兼容旧引用：与 [SessionTerminalPane] 相同。
typedef SessionWorkspace = SessionTerminalPane;
