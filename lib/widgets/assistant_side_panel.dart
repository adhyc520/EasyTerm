import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/assistant_chat_session.dart';
import '../services/llm_openai_chat_service.dart';
import '../services/session_tabs_controller.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';
import 'assistant_chat_messages.dart';
import 'assistant_chat_text.dart';

/// 终端区域右侧：可拖拽宽度、可收起的助手栏（大模型对话 + 终端工具调用）。
class TerminalWithAssistantSplit extends StatefulWidget {
  const TerminalWithAssistantSplit({
    super.key,
    required this.settings,
    required this.sessionTab,
    required this.terminalChild,
  });

  final WorkbenchSettingsStore settings;
  final SessionTab? sessionTab;
  final Widget terminalChild;

  @override
  State<TerminalWithAssistantSplit> createState() =>
      _TerminalWithAssistantSplitState();
}

class _TerminalWithAssistantSplitState
    extends State<TerminalWithAssistantSplit> {
  static const double _splitterW = 5;
  static const double _minTerminal = 200;
  static const double _minAssistant = 220;
  static const double _maxAssistant = 560;

  double? _lastTotalWidth;

  void _dragSplit(double dx) {
    if (widget.settings.assistantPanelCollapsed) return;
    final total = _lastTotalWidth;
    if (total == null) return;
    setState(() {
      final maxA = (total - _splitterW - _minTerminal).clamp(
        _minAssistant,
        _maxAssistant,
      );
      widget.settings.assistantPanelWidth =
          (widget.settings.assistantPanelWidth - dx).clamp(_minAssistant, maxA);
    });
  }

  void _persistWidth() {
    unawaited(widget.settings.persist());
  }

  Future<void> _setAssistantCollapsed(bool collapsed) async {
    widget.settings.assistantPanelCollapsed = collapsed;
    await widget.settings.persist();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;
        _lastTotalWidth = total;
        final collapsed = widget.settings.assistantPanelCollapsed;

        final maxA = (total - _splitterW - _minTerminal).clamp(
          _minAssistant,
          _maxAssistant,
        );
        var aw = widget.settings.assistantPanelWidth.clamp(_minAssistant, maxA);
        if (aw != widget.settings.assistantPanelWidth) {
          widget.settings.assistantPanelWidth = aw;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }

        final tab = widget.sessionTab;
        final assistant = AssistantChatPanel(
          key: ValueKey<int>(tab?.id ?? -1),
          settings: widget.settings,
          sessionTab: tab,
          onCollapse: () => unawaited(_setAssistantCollapsed(true)),
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: widget.terminalChild),
            if (!collapsed)
              _WorkbenchColumnSplitter(
                width: _splitterW,
                onDrag: _dragSplit,
                onDragEnd: _persistWidth,
              ),
            if (collapsed)
              SizedBox(
                width: 40,
                child: _AssistantCollapsedRail(
                  onExpand: () => unawaited(_setAssistantCollapsed(false)),
                ),
              )
            else
              SizedBox(width: aw, child: assistant),
          ],
        );
      },
    );
  }
}

class _AssistantCollapsedRail extends StatelessWidget {
  const _AssistantCollapsedRail({required this.onExpand});

  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Material(
      color: context.wb.panel,
      child: SizedBox(
        width: 40,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: context.wb.border)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 8),
              IconButton(
                tooltip: l.assistantExpandTooltip,
                onPressed: onExpand,
                icon: Icon(
                  Icons.chevron_left_rounded,
                  color: context.wb.accentBlue,
                ),
              ),
              RotatedBox(
                quarterTurns: 3,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    l.assistantPanelTitle,
                    style: TextStyle(
                      color: context.wb.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkbenchColumnSplitter extends StatelessWidget {
  const _WorkbenchColumnSplitter({
    required this.width,
    required this.onDrag,
    this.onDragEnd,
  });

  final double width;
  final ValueChanged<double> onDrag;
  final VoidCallback? onDragEnd;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd?.call(),
        child: SizedBox(
          width: width,
          child: Center(child: Container(width: 1, color: context.wb.border)),
        ),
      ),
    );
  }
}

class AssistantChatPanel extends StatefulWidget {
  const AssistantChatPanel({
    super.key,
    required this.settings,
    required this.sessionTab,
    required this.onCollapse,
  });

  final WorkbenchSettingsStore settings;
  final SessionTab? sessionTab;
  final VoidCallback onCollapse;

  SshWorkspaceController? get ssh => sessionTab?.controller;
  AssistantChatSession? get session => sessionTab?.assistant;

  @override
  State<AssistantChatPanel> createState() => _AssistantChatPanelState();
}

class _AssistantChatPanelState extends State<AssistantChatPanel> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _streamUiThrottle;
  int? _boundTabId;
  AssistantChatSession? _boundSession;

  AssistantChatSession? get _session => widget.session;
  List<Map<String, Object?>> get _apiMessages =>
      _session?.messages ?? const [];

  bool get _zh => widget.settings.appLocaleCode == 'zh';

  bool get _busy => _session?.busy ?? false;

  String get _streamReasoning => _session?.streamReasoning ?? '';

  String get _streamContent => _session?.streamContent ?? '';

  bool get _showGlobalThinking =>
      _busy &&
      normalizeChatText(_streamReasoning).isEmpty &&
      normalizeChatText(_streamContent).isEmpty;

  @override
  void initState() {
    super.initState();
    _bindSession(widget.sessionTab);
  }

  @override
  void didUpdateWidget(AssistantChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionTab?.id != widget.sessionTab?.id) {
      _saveDraft(oldWidget.session);
      _bindSession(widget.sessionTab);
    }
  }

  void _saveDraft(AssistantChatSession? session) {
    if (session == null || session.isDisposed) return;
    session.draftInput = _input.text;
  }

  void _unbindSession(AssistantChatSession? session) {
    if (session == null || session.isDisposed) return;
    session.removeListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (!mounted) return;
    if (widget.sessionTab?.id != _boundTabId) return;
    if (_boundSession?.isDisposed ?? true) return;
    setState(() {});
    _scrollBottom();
  }

  void _bindSession(SessionTab? tab) {
    _unbindSession(_boundSession);
    final session = tab?.assistant;
    _boundSession = session;
    session?.addListener(_onSessionChanged);
    if (session != null && !session.isDisposed) {
      session.ensureSystemMessage(zh: _zh);
    }
    _boundTabId = tab?.id;
    _input.text = session?.draftInput ?? '';
    _streamUiThrottle?.cancel();
    _streamUiThrottle = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollBottom(jump: true);
    });
  }

  @override
  void dispose() {
    _saveDraft(_boundSession);
    _unbindSession(_boundSession);
    _boundSession = null;
    _streamUiThrottle?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _scheduleStreamUi(AssistantChatSession session) {
    if (session.isDisposed) return;
    _streamUiThrottle?.cancel();
    _streamUiThrottle = Timer(const Duration(milliseconds: 45), () {
      _streamUiThrottle = null;
      if (!mounted) return;
      if (!identical(widget.session, session)) return;
      if (widget.sessionTab?.id != _boundTabId) return;
      setState(() {});
      _scrollBottom();
    });
  }

  Future<bool> _confirmTerminalCommand(String command) async {
    final l = AppLocalizations.of(context)!;
    final preview = command.length > 12000
        ? '${command.substring(0, 12000)}…'
        : command;
    final allow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _TerminalRunApprovalDialog(preview: preview, l10n: l),
    );
    if (!mounted) return false;
    return allow == true;
  }

  Future<void> _send() async {
    final session = _session;
    if (session == null || session.isDisposed) return;
    final text = _input.text.trim();
    if (text.isEmpty || session.busy) return;
    final l = AppLocalizations.of(context)!;
    final base = widget.settings.llmBaseUrl.trim();
    final model = widget.settings.llmModel.trim();
    if (base.isEmpty || model.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.llmMissingConfig)));
      return;
    }

    session.draftInput = '';
    final cancel = LlmStreamCancel();
    final tabId = widget.sessionTab?.id;
    setState(() {
      session.busy = true;
      session.streamCancel = cancel;
      session.streamReasoning = '';
      session.streamContent = '';
      session.messages.add({'role': 'user', 'content': text});
      session.touch();
      _input.clear();
    });
    _scrollBottom();

    try {
      final svc = LlmOpenAiChatService(
        baseUrl: base,
        model: model,
        apiKey: widget.settings.llmApiKey,
      );
      await svc.runTurnStreaming(
        messages: session.messages,
        ssh: widget.ssh,
        useZhTools: _zh,
        onRequestTerminalApproval: _confirmTerminalCommand,
        cancel: cancel,
        onStreamRoundStart: () {
          if (session.isDisposed) return;
          session.streamReasoning = '';
          session.streamContent = '';
          _scheduleStreamUi(session);
        },
        onStreamDelta: ({reasoningDelta, contentDelta}) {
          if (session.isDisposed) return;
          if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
            session.streamReasoning += reasoningDelta;
          }
          if (contentDelta != null && contentDelta.isNotEmpty) {
            session.streamContent += contentDelta;
          }
          _scheduleStreamUi(session);
        },
        onMessagesChanged: () {
          if (!session.isDisposed) session.touch();
        },
      );
    } catch (e) {
      if (!session.isDisposed) {
        session.messages.add({
          'role': 'assistant',
          'content': _zh ? '请求失败：$e' : 'Request failed: $e',
        });
        session.touch();
      }
      if (mounted && widget.sessionTab?.id == tabId) setState(() {});
    } finally {
      if (!session.isDisposed) {
        session.busy = false;
        session.streamCancel = null;
        session.streamReasoning = '';
        session.streamContent = '';
      }
      if (mounted && widget.sessionTab?.id == tabId) {
        setState(() {});
        _scrollBottom();
      }
    }
  }

  void _stopGeneration() {
    _session?.streamCancel?.cancel();
  }

  Future<void> _clear() async {
    final l = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.assistantClearConfirmTitle),
        content: Text(l.assistantClearConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.settingsCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.assistantClearConfirm),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      _session?.reset(zh: _zh);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final wb = context.wb;
    final session = _session;

    if (session == null) {
      return Material(
        color: wb.panel,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l.placeholderTerminalSubtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: wb.textMuted, fontSize: 12, height: 1.4),
            ),
          ),
        ),
      );
    }

    return Material(
      color: wb.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: wb.border)),
            ),
            child: Row(
              children: [
                Icon(Icons.smart_toy_outlined, size: 18, color: wb.accentBlue),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.assistantPanelTitle,
                    style: TextStyle(
                      color: wb.primaryText,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l.assistantClearTooltip,
                  onPressed: _busy ? null : _clear,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: wb.textMuted,
                  ),
                ),
                if (_busy)
                  IconButton(
                    tooltip: l.assistantStopTooltip,
                    onPressed: _stopGeneration,
                    icon: Icon(
                      Icons.stop_circle_outlined,
                      size: 22,
                      color: wb.accentBlue,
                    ),
                  ),
                IconButton(
                  tooltip: l.assistantCollapseTooltip,
                  onPressed: widget.onCollapse,
                  icon: Icon(Icons.chevron_right_rounded, color: wb.accentBlue),
                ),
              ],
            ),
          ),
          Expanded(
            child: SelectionArea(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                children: buildAssistantChatMessageTiles(
                  context: context,
                  l: l,
                  messages: _apiMessages,
                  busy: _busy,
                  streamReasoning: _streamReasoning,
                  streamContent: _streamContent,
                ),
              ),
            ),
          ),
          if (_showGlobalThinking)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: wb.accentBlue,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l.assistantThinking,
                    style: TextStyle(color: wb.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          if (!(widget.ssh?.connected ?? false))
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Text(
                l.assistantNotConnected,
                style: TextStyle(
                  color: wb.textMuted,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(
                  LogicalKeyboardKey.enter,
                  control: true,
                ): () {
                  if (!_busy) unawaited(_send());
                },
                const SingleActivator(
                  LogicalKeyboardKey.enter,
                  meta: true,
                ): () {
                  if (!_busy) unawaited(_send());
                },
              },
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      onChanged: (v) => session.draftInput = v,
                      minLines: 1,
                      maxLines: 5,
                      enabled: !_busy,
                      style: TextStyle(color: wb.primaryText, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: l.assistantInputHint,
                        filled: true,
                        fillColor: wb.panelElevated,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : () => unawaited(_send()),
                    style: FilledButton.styleFrom(
                      backgroundColor: wb.accentBlue,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                    child: Text(l.assistantSend),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

}

/// 参考 Cursor：图标标题、说明、深色代码块、安全提示、底部 Deny / Run。
class _TerminalRunApprovalDialog extends StatelessWidget {
  const _TerminalRunApprovalDialog({required this.preview, required this.l10n});

  final String preview;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: wb.panelElevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: wb.border),
      ),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: wb.accentBlue.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: wb.accentBlue.withValues(alpha: 0.35)),
            ),
            child: Icon(Icons.terminal_rounded, color: wb.accentBlue, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.assistantTerminalApprovalTitle,
              style: theme.textTheme.titleLarge?.copyWith(
                color: wb.primaryText,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.assistantTerminalApprovalSubtitle,
                style: TextStyle(
                  color: wb.secondaryText,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                l10n.assistantTerminalCommandSectionTitle,
                style: TextStyle(
                  color: wb.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: wb.terminalBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: wb.border),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    preview,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.45,
                      color: wb.secondaryText,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: const Color(0xFFF59E0B),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.assistantTerminalSecurityHint,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: wb.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.assistantTerminalDeny),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow_rounded, size: 20),
          label: Text(l10n.assistantTerminalAllowExecute),
          style: FilledButton.styleFrom(
            backgroundColor: wb.accentBlue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          ),
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
  }
}
