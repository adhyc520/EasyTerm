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

  void _showTerminalContextMenu(BuildContext context, Offset globalPosition, Terminal term) {
    final l = AppLocalizations.of(context)!;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final topLeft = overlay.localToGlobal(Offset.zero);
    final rel = RelativeRect.fromLTRB(
      globalPosition.dx - topLeft.dx,
      globalPosition.dy - topLeft.dy,
      globalPosition.dx - topLeft.dx + 1,
      globalPosition.dy - topLeft.dy + 1,
    );
    final hasSelection = _viewController.selection != null;
    showMenu<String>(
      context: context,
      position: rel,
      color: context.wb.panelElevated,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: context.wb.border),
        borderRadius: BorderRadius.circular(8),
      ),
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: hasSelection,
          child: Text(l.terminalMenuCopy, style: TextStyle(color: context.wb.primaryText)),
        ),
        PopupMenuItem(
          value: 'paste',
          child: Text(l.terminalMenuPaste, style: TextStyle(color: context.wb.primaryText)),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'selectAll',
          child: Text(l.terminalMenuSelectAll, style: TextStyle(color: context.wb.primaryText)),
        ),
        PopupMenuItem(
          value: 'clearSelection',
          enabled: hasSelection,
          child: Text(l.terminalMenuClearSelection, style: TextStyle(color: context.wb.primaryText)),
        ),
      ],
    ).then((v) async {
      if (!mounted || v == null) return;
      if (v == 'copy') {
        final sel = _viewController.selection;
        if (sel == null) return;
        final text = term.buffer.getText(sel);
        if (text.isEmpty) return;
        await Clipboard.setData(ClipboardData(text: text));
      } else if (v == 'paste') {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text;
        if (text == null || text.isEmpty) return;
        term.paste(text);
        _viewController.clearSelection();
      } else if (v == 'selectAll') {
        _viewController.setSelection(
          term.buffer.createAnchor(0, term.buffer.height - term.viewHeight),
          term.buffer.createAnchor(term.viewWidth, term.buffer.height - 1),
          mode: SelectionMode.line,
        );
      } else if (v == 'clearSelection') {
        _viewController.clearSelection();
      }
      if (mounted) setState(() {});
    });
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
              onSecondaryTapDown: (_, _) {},
              onSecondaryTapUp: (details, _) =>
                  _showTerminalContextMenu(context, details.globalPosition, term),
            ),
          );
        },
      ),
    );
  }
}

/// 兼容旧引用：与 [SessionTerminalPane] 相同。
typedef SessionWorkspace = SessionTerminalPane;
