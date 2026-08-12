import 'dart:async';

import 'package:flutter/foundation.dart';

import 'assistant_chat_store.dart';
import 'llm_context_builder.dart';
import 'llm_openai_chat_service.dart';
import 'terminal_session_controller.dart';
import 'ssh_workspace_controller.dart';

/// 单个 SSH 标签页的助手对话状态（切换标签时保留，关闭标签时销毁）。
class AssistantChatSession extends ChangeNotifier {
  AssistantChatSession({this.hostKey, AssistantChatStore? store})
    : _store = store ?? AssistantChatStore.instance;

  /// 主机键（如 `user@host:port`），用于对话持久化。
  String? hostKey;

  final AssistantChatStore _store;
  final List<Map<String, Object?>> messages = [];
  bool busy = false;
  LlmStreamCancel? streamCancel;
  String streamReasoning = '';
  String streamContent = '';
  String draftInput = '';

  /// 实时工具进度（供 UI 展示 running 卡片）。
  final List<Map<String, String>> liveToolProgress = [];

  bool _disposed = false;
  bool _loaded = false;
  Timer? _persistDebounce;
  Future<void>? _loadFuture;

  bool get isDisposed => _disposed;

  void touch() {
    if (_disposed) return;
    notifyListeners();
    _schedulePersist();
  }

  void setLiveToolProgress(String toolName, String status, {String? detail}) {
    if (_disposed) return;
    liveToolProgress.removeWhere((e) => e['name'] == toolName);
    if (status == 'running') {
      liveToolProgress.add({
        'name': toolName,
        'status': status,
        if (detail != null && detail.isNotEmpty) 'detail': detail,
      });
    }
    notifyListeners();
  }

  void clearLiveToolProgress() {
    if (_disposed) return;
    if (liveToolProgress.isEmpty) return;
    liveToolProgress.clear();
    notifyListeners();
  }

  Future<void> ensureLoaded() async {
    if (_disposed || _loaded) return;
    final key = hostKey?.trim();
    if (key == null || key.isEmpty) {
      _loaded = true;
      return;
    }
    _loadFuture ??= () async {
      final loaded = await _store.load(key);
      if (_disposed) return;
      if (loaded.isNotEmpty && messages.isEmpty) {
        messages
          ..clear()
          ..addAll(loaded);
      }
      _loaded = true;
      notifyListeners();
    }();
    await _loadFuture;
  }

  Future<void> ensureSystemMessage({
    required bool zh,
    TerminalSessionController? ssh,
    String? customPrompt,
  }) async {
    if (_disposed) return;
    await ensureLoaded();
    if (_disposed) return;

    String content;
    if (ssh != null && ssh.connected) {
      content = await buildSystemContext(
        ssh,
        zh: zh,
        customPrompt: customPrompt,
      );
    } else {
      content = _fallbackSystemContent(zh: zh);
    }

    final msg = <String, Object?>{'role': 'system', 'content': content};
    if (messages.isEmpty) {
      messages.add(msg);
    } else if (messages.first['role'] == 'system') {
      messages.first['content'] = content;
    } else {
      messages.insert(0, msg);
    }
    touch();
  }

  Future<void> reset({
    required bool zh,
    TerminalSessionController? ssh,
    String? customPrompt,
  }) async {
    if (_disposed) return;
    streamReasoning = '';
    streamContent = '';
    busy = false;
    streamCancel?.cancel();
    streamCancel = null;
    liveToolProgress.clear();
    messages.clear();
    final key = hostKey?.trim();
    if (key != null && key.isNotEmpty) {
      await _store.delete(key);
    }
    await ensureSystemMessage(zh: zh, ssh: ssh, customPrompt: customPrompt);
  }

  /// 导出可见对话为 Markdown。
  String exportMarkdown({bool zh = true}) {
    final buf = StringBuffer();
    buf.writeln(zh ? '# EasyTerm 助手对话' : '# EasyTerm assistant chat');
    if (hostKey != null && hostKey!.trim().isNotEmpty) {
      buf.writeln();
      buf.writeln('- host: `${hostKey!.trim()}`');
    }
    buf.writeln();
    for (final m in messages) {
      final role = m['role'] as String?;
      if (role == null || role == 'system') continue;
      if (role == 'user') {
        final text = m['content'];
        if (text is! String || text.trim().isEmpty) continue;
        buf.writeln(zh ? '## 用户' : '## User');
        buf.writeln();
        buf.writeln(text.trim());
        buf.writeln();
      } else if (role == 'assistant') {
        final reasoning = m['reasoning_content'];
        if (reasoning is String && reasoning.trim().isNotEmpty) {
          buf.writeln(zh ? '## 思考' : '## Reasoning');
          buf.writeln();
          buf.writeln(reasoning.trim());
          buf.writeln();
        }
        final toolCalls = m['tool_calls'];
        if (toolCalls is List && toolCalls.isNotEmpty) {
          buf.writeln(zh ? '## 工具调用' : '## Tool calls');
          buf.writeln();
          for (final t in toolCalls) {
            if (t is! Map) continue;
            final fn = t['function'];
            if (fn is Map && fn['name'] is String) {
              buf.writeln('- `${fn['name']}`');
            }
          }
          buf.writeln();
        }
        final answer = m['content'];
        if (answer is String && answer.trim().isNotEmpty) {
          buf.writeln(zh ? '## 助手' : '## Assistant');
          buf.writeln();
          buf.writeln(answer.trim());
          buf.writeln();
        }
      } else if (role == 'tool') {
        final ui = m['_ui_tool'];
        final name = ui is Map && ui['name'] is String
            ? ui['name'] as String
            : 'tool';
        final content = m['content'];
        buf.writeln('### $name');
        buf.writeln();
        buf.writeln('```json');
        buf.writeln(content is String ? content : '$content');
        buf.writeln('```');
        buf.writeln();
      }
    }
    return buf.toString().trimRight();
  }

  void _schedulePersist() {
    final key = hostKey?.trim();
    if (key == null || key.isEmpty || _disposed) return;
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 450), () {
      if (_disposed) return;
      unawaited(_store.save(key, List<Map<String, Object?>>.from(messages)));
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _persistDebounce?.cancel();
    _persistDebounce = null;
    streamCancel?.cancel();
    streamCancel = null;
    final key = hostKey?.trim();
    if (key != null && key.isNotEmpty && messages.isNotEmpty) {
      unawaited(_store.save(key, List<Map<String, Object?>>.from(messages)));
    }
    super.dispose();
  }

  static String _fallbackSystemContent({required bool zh}) => zh
      ? '你是 EasyTerm 里 SSH 终端旁的助手。'
            '可用工具包括 file_read/file_write/file_list/file_search/file_grep、'
            'system_info/process_list/disk_usage/network_info/package_query，以及 terminal_run。'
            'terminal_run 与 file_write 每次执行前需用户确认。'
            '回答时区分思考与正式答复；工具结果据实引用，勿编造。'
      : 'You assist next to an SSH terminal in EasyTerm. '
            'Tools: file_read/file_write/file_list/file_search/file_grep, '
            'system_info/process_list/disk_usage/network_info/package_query, and terminal_run. '
            'terminal_run and file_write require user approval. '
            'Separate reasoning from the final answer; quote tool results faithfully.';
}
