import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';
import 'terminal_surface.dart';

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
  @override
  void initState() {
    super.initState();
    widget.workbenchSettings.addListener(_onChanged);
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.workbenchSettings.removeListener(_onChanged);
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: ListenableBuilder(
        listenable: Listenable.merge([
          widget.controller,
          widget.workbenchSettings,
        ]),
        builder: (context, _) {
          final c = widget.controller;
          final ws = widget.workbenchSettings;
          final l = AppLocalizations.of(context)!;
          final term = c.terminal;

          if (term == null) {
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
                        const Icon(
                          Icons.error_outline_rounded,
                          size: 40,
                          color: Color(0xFFEF4444),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l.terminalConnectionFailed,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: context.wb.primaryText),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          c.error!,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: context.wb.textMuted,
                          ),
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: context.wb.accentBlue,
                          ),
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
            return Center(
              child: Text(
                l.terminalWaiting,
                style: TextStyle(color: context.wb.textMuted),
              ),
            );
          }

          return TerminalSurface(
            terminal: term,
            connected: c.connected,
            connecting: c.connecting,
            autofocus: widget.autofocusTerminal,
            errorText: c.error,
            onReconnect: () => unawaited(c.reconnect()),
            themeBg: context.wb.terminalBg,
            fontSize: ws.terminalFontSize,
            fontFamily: ws.terminalFontFamily,
            uiScale: ws.uiScaleFactor,
            selectToCopy: ws.selectToCopy,
            mouseModeActive: c.mouseModeActive,
            smartRightClick: ws.smartRightClick,
            showLeftBorder: true,
          );
        },
      ),
    );
  }
}

/// 兼容旧引用：与 [SessionTerminalPane] 相同。
typedef SessionWorkspace = SessionTerminalPane;
