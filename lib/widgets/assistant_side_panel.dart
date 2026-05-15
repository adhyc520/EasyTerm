import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/llm_openai_chat_service.dart';
import '../services/ssh_workspace_controller.dart';
import '../services/workbench_settings_store.dart';
import '../theme/workbench_theme.dart';

/// 终端区域右侧：可拖拽宽度、可收起的助手栏（大模型对话 + 终端工具调用）。
class TerminalWithAssistantSplit extends StatefulWidget {
  const TerminalWithAssistantSplit({
    super.key,
    required this.settings,
    required this.ssh,
    required this.terminalChild,
  });

  final WorkbenchSettingsStore settings;
  final SshWorkspaceController? ssh;
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

        const assistantKey = ValueKey<String>('workbench_assistant_chat');
        final assistant = AssistantChatPanel(
          key: assistantKey,
          settings: widget.settings,
          ssh: widget.ssh,
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
            SizedBox(
              width: collapsed ? 40 : aw,
              child: ClipRect(
                child: Stack(
                  alignment: Alignment.centerRight,
                  fit: StackFit.expand,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: SizedBox(
                        width: aw,
                        height: double.infinity,
                        child: Opacity(
                          opacity: collapsed ? 0.0 : 1.0,
                          child: IgnorePointer(
                            ignoring: collapsed,
                            child: assistant,
                          ),
                        ),
                      ),
                    ),
                    if (collapsed)
                      Positioned.fill(
                        child: _AssistantCollapsedRail(
                          onExpand: () => unawaited(_setAssistantCollapsed(false)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
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
    required this.ssh,
    required this.onCollapse,
  });

  final WorkbenchSettingsStore settings;
  final SshWorkspaceController? ssh;
  final VoidCallback onCollapse;

  @override
  State<AssistantChatPanel> createState() => _AssistantChatPanelState();
}

class _AssistantChatPanelState extends State<AssistantChatPanel> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<Map<String, Object?>> _apiMessages = [];
  bool _busy = false;
  LlmStreamCancel? _streamCancel;
  String _streamReasoning = '';
  String _streamContent = '';
  Timer? _streamUiThrottle;

  bool get _zh => widget.settings.appLocaleCode == 'zh';

  bool get _streamingBubbleVisible =>
      _busy && (_streamReasoning.isNotEmpty || _streamContent.isNotEmpty);

  @override
  void initState() {
    super.initState();
    _resetSystemMessage();
  }

  void _resetSystemMessage() {
    _streamReasoning = '';
    _streamContent = '';
    _apiMessages
      ..clear()
      ..add({
        'role': 'system',
        'content': _zh
            ? '你是 EasyTerm 里 SSH 终端旁的助手。用户已连接远程 shell。'
                  '回答与推理可能分字段或分标签返回；向用户说明时区分「思考」与正式答复。'
                  '需要远端执行时调用 terminal_run；每一次注入前用户都会在弹窗中单独确认是否执行；'
                  '若模型未在命令末尾写换行，客户端会自动补上回车以便 shell 提交。'
                  '工具结果中会附带注入后一段时间的终端尾部输出，请据实引用，勿编造。'
            : 'You assist next to an SSH terminal in EasyTerm. The user has an active remote shell. '
                  'Separate reasoning from the final answer when presenting to the user. '
                  'Use terminal_run for remote execution; the user must confirm every injection in a dialog. '
                  'If the command text has no trailing newline, the client appends a carriage return so the shell submits the line. '
                  'Tool results include a terminal buffer tail after injection—quote it faithfully, do not invent output.',
      });
  }

  @override
  void dispose() {
    _streamUiThrottle?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _scheduleStreamUi() {
    _streamUiThrottle?.cancel();
    _streamUiThrottle = Timer(const Duration(milliseconds: 45), () {
      _streamUiThrottle = null;
      if (mounted) setState(() {});
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
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    final l = AppLocalizations.of(context)!;
    final base = widget.settings.llmBaseUrl.trim();
    final model = widget.settings.llmModel.trim();
    if (base.isEmpty || model.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.llmMissingConfig)));
      return;
    }

    final cancel = LlmStreamCancel();
    setState(() {
      _busy = true;
      _streamCancel = cancel;
      _streamReasoning = '';
      _streamContent = '';
      _apiMessages.add({'role': 'user', 'content': text});
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
        messages: _apiMessages,
        ssh: widget.ssh,
        useZhTools: _zh,
        onRequestTerminalApproval: _confirmTerminalCommand,
        cancel: cancel,
        onStreamRoundStart: () {
          if (!mounted) return;
          setState(() {
            _streamReasoning = '';
            _streamContent = '';
          });
        },
        onStreamDelta: ({reasoningDelta, contentDelta}) {
          if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
            _streamReasoning += reasoningDelta;
          }
          if (contentDelta != null && contentDelta.isNotEmpty) {
            _streamContent += contentDelta;
          }
          _scheduleStreamUi();
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _apiMessages.add({
            'role': 'assistant',
            'content': _zh ? '请求失败：$e' : 'Request failed: $e',
          });
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _streamCancel = null;
          _streamReasoning = '';
          _streamContent = '';
        });
        _scrollBottom();
      }
    }
  }

  void _stopGeneration() {
    _streamCancel?.cancel();
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
      setState(_resetSystemMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final wb = context.wb;

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
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              itemCount: _bubbleCount(),
              itemBuilder: (context, i) => _bubbleAt(i),
            ),
          ),
          if (_busy && !_streamingBubbleVisible)
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

  int _bubbleCount() {
    var n = 0;
    for (final m in _apiMessages) {
      final role = m['role'] as String?;
      if (role == 'system') continue;
      if (role == 'user') n++;
      if (role == 'assistant') {
        final rc = m['reasoning_content'] as String?;
        if (rc != null && rc.trim().isNotEmpty) n++;
        final tc = m['tool_calls'];
        final c = m['content'];
        if (tc is List && tc.isNotEmpty) n++;
        if (c is String && c.trim().isNotEmpty) n++;
      }
      if (role == 'tool') n++;
    }
    if (_streamingBubbleVisible) n++;
    return n;
  }

  Widget _bubbleAt(int index) {
    var walk = 0;
    for (final m in _apiMessages) {
      final role = m['role'] as String?;
      if (role == 'system') continue;

      if (role == 'user') {
        if (walk == index) {
          return _UserBubble(text: (m['content'] as String?) ?? '');
        }
        walk++;
        continue;
      }

      if (role == 'assistant') {
        final rc = m['reasoning_content'] as String?;
        if (rc != null && rc.trim().isNotEmpty) {
          if (walk == index) {
            return _ReasoningBubble(text: rc);
          }
          walk++;
        }
        final tc = m['tool_calls'];
        final c = m['content'];
        if (tc is List && tc.isNotEmpty) {
          if (walk == index) {
            return _ToolCallBubble(summary: _formatToolCalls(tc));
          }
          walk++;
        }
        if (c is String && c.trim().isNotEmpty) {
          if (walk == index) {
            return _AssistantBubble(text: c);
          }
          walk++;
        }
        continue;
      }

      if (role == 'tool') {
        if (walk == index) {
          return _ToolResultBubble(text: (m['content'] as String?) ?? '');
        }
        walk++;
      }
    }
    if (_streamingBubbleVisible && walk == index) {
      return _StreamingAssistantBubble(
        reasoning: _streamReasoning,
        content: _streamContent,
      );
    }
    return const SizedBox.shrink();
  }

  String _formatToolCalls(List<dynamic> tc) {
    final names = <String>[];
    for (final t in tc) {
      if (t is! Map) continue;
      final m = Map<String, dynamic>.from(t);
      final fn = m['function'];
      if (fn is Map) {
        final f = Map<String, dynamic>.from(fn);
        final name = f['name'];
        if (name is String) names.add(name);
      }
    }
    return names.isEmpty ? 'terminal_run' : names.join(', ');
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

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: wb.accentBlue.withValues(alpha: 0.22),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomLeft: Radius.circular(12),
          ),
        ),
        child: SelectableText(
          text,
          style: TextStyle(color: wb.primaryText, fontSize: 13, height: 1.35),
        ),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final l = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: wb.panelElevated,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
          border: Border.all(color: wb.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.assistantAnswerHeader,
              style: TextStyle(
                color: wb.accentBlue,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
              text,
              style: TextStyle(
                color: wb.primaryText,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReasoningBubble extends StatelessWidget {
  const _ReasoningBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final l = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: wb.accentBlue.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: const Color(0xFFD97706).withValues(alpha: 0.55),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.psychology_outlined,
                  size: 16,
                  color: const Color(0xFFD97706),
                ),
                const SizedBox(width: 6),
                Text(
                  l.assistantReasoningHeader,
                  style: TextStyle(
                    color: const Color(0xFFB45309),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              text,
              style: TextStyle(
                color: wb.primaryText.withValues(alpha: 0.92),
                fontSize: 12,
                height: 1.35,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StreamingAssistantBubble extends StatelessWidget {
  const _StreamingAssistantBubble({
    required this.reasoning,
    required this.content,
  });

  final String reasoning;
  final String content;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final l = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: wb.panelElevated,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: wb.accentBlue.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (reasoning.trim().isNotEmpty) ...[
              Text(
                l.assistantReasoningHeader,
                style: TextStyle(
                  color: const Color(0xFFB45309),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                reasoning,
                style: TextStyle(
                  color: wb.textMuted,
                  fontSize: 12,
                  height: 1.35,
                  fontStyle: FontStyle.italic,
                ),
              ),
              if (content.trim().isNotEmpty) const SizedBox(height: 10),
            ],
            if (content.trim().isNotEmpty) ...[
              Text(
                l.assistantAnswerHeader,
                style: TextStyle(
                  color: wb.accentBlue,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                content,
                style: TextStyle(
                  color: wb.primaryText,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ],
            if (reasoning.trim().isEmpty && content.trim().isEmpty)
              Text(
                l.assistantThinking,
                style: TextStyle(color: wb.textMuted, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToolCallBubble extends StatelessWidget {
  const _ToolCallBubble({required this.summary});

  final String summary;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final l = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(Icons.bolt_rounded, size: 16, color: wb.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l.assistantToolRunning(summary),
              style: TextStyle(
                color: wb.textMuted,
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolResultBubble extends StatelessWidget {
  const _ToolResultBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final preview = text.length > 400 ? '${text.substring(0, 400)}…' : text;
    return Container(
      margin: const EdgeInsets.only(bottom: 8, left: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: wb.terminalBg.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: wb.border.withValues(alpha: 0.6)),
      ),
      child: SelectableText(
        preview,
        style: TextStyle(
          color: wb.textMuted,
          fontSize: 11,
          height: 1.25,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
