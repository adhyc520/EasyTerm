import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_tool_executor.dart';
import 'terminal_session_controller.dart';
import 'ssh_workspace_controller.dart';

/// 用户中断当前流式请求（例如助手面板「停止」）。
final class LlmStreamCancel {
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  bool get isCancelled => _cancelled;
}

/// OpenAI Chat Completions 兼容：流式输出、工具调用、终端回传。
final class LlmOpenAiChatService {
  LlmOpenAiChatService({
    required this.baseUrl,
    required this.model,
    required this.apiKey,
    LlmToolRegistry? toolRegistry,
  }) : toolRegistry = toolRegistry ?? LlmToolRegistry.standard();

  final String baseUrl;
  final String model;
  final String apiKey;
  final LlmToolRegistry toolRegistry;

  static const _terminalToolName = 'terminal_run';
  static const _fileWriteToolName = 'file_write';

  static Map<String, Object?> _terminalToolZh() => {
    'type': 'function',
    'function': {
      'name': _terminalToolName,
      'description':
          '向当前 SSH 终端注入 shell 文本（如同用户键入）。'
          '若文本未以换行或回车结尾，客户端会追加回车（与终端 Return 键一致）以便 PTY 提交行；多行可自行带换行。'
          '每一次调用前用户都会在弹窗中单独确认是否执行；同意后工具返回中含终端尾部输出，请据实分析。',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': '要发送到远端 shell 的完整文本，可含多行。',
          },
        },
        'required': ['text'],
      },
    },
  };

  static Map<String, Object?> _terminalToolEn() => {
    'type': 'function',
    'function': {
      'name': _terminalToolName,
      'description':
          'Inject shell text into the current SSH terminal (as if typed). '
          'If the text does not end with a newline or carriage return, the client appends a carriage return (same as the terminal Return key) to submit the line; '
          'multi-line snippets may include their own newlines. '
          'The user must approve every call in a dialog; the tool result includes a terminal tail—use it faithfully.',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description':
                'Full text to send to the remote shell; may be multi-line.',
          },
        },
        'required': ['text'],
      },
    },
  };

  static List<Map<String, Object?>> terminalToolsZh() => [_terminalToolZh()];

  static List<Map<String, Object?>> terminalToolsEn() => [_terminalToolEn()];

  List<Map<String, Object?>> allTools({required bool zh}) => [
    ...toolRegistry.openAiTools(zh: zh),
    if (zh) _terminalToolZh() else _terminalToolEn(),
  ];

  static Uri resolveChatCompletionsUri(String raw) {
    var s = raw.trim();
    if (s.isEmpty) {
      throw const FormatException('LLM base URL is empty');
    }
    final lower = s.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      s = 'https://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.toLowerCase().endsWith('/chat/completions')) {
      return Uri.parse(s);
    }
    if (s.toLowerCase().endsWith('/v1')) {
      return Uri.parse('$s/chat/completions');
    }
    return Uri.parse('$s/v1/chat/completions');
  }

  /// 发往 API 的消息副本（去掉仅用于 UI 的字段）。
  static List<Map<String, Object?>> messagesForApiRequest(
    List<Map<String, Object?>> src,
  ) {
    final out = <Map<String, Object?>>[];
    for (final m in src) {
      final role = m['role'] as String?;
      if (role == null) continue;
      final copy = <String, Object?>{'role': role};
      final c = m['content'];
      final tc = m['tool_calls'];
      if (c is String) {
        copy['content'] = c;
      } else if (tc is List && role == 'assistant') {
        copy['content'] = '';
      }
      final name = m['name'];
      if (name is String) copy['name'] = name;
      if (tc is List) copy['tool_calls'] = tc;
      final tid = m['tool_call_id'];
      if (tid is String) copy['tool_call_id'] = tid;
      // 思考链模型要求下一轮请求必须带回 assistant 的 reasoning_content。
      if (role == 'assistant') {
        if (m.containsKey('reasoning_content')) {
          final rc = m['reasoning_content'];
          copy['reasoning_content'] = rc is String ? rc : '';
        }
      }
      out.add(copy);
    }
    return out;
  }

  Future<void> testConnection() async {
    final uri = resolveChatCompletionsUri(baseUrl);
    final headers = <String, String>{'Content-Type': 'application/json'};
    final key = apiKey.trim();
    if (key.isNotEmpty) {
      headers['Authorization'] = 'Bearer $key';
    }
    final body = jsonEncode({
      'model': model,
      'messages': [
        {'role': 'user', 'content': 'ping'},
      ],
      'max_tokens': 1,
    });
    final res = await http
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 45));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final snippet = res.body.length > 500
          ? '${res.body.substring(0, 500)}…'
          : res.body;
      throw LlmHttpException(res.statusCode, snippet);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) {
      throw const FormatException('Invalid API response: not a JSON object');
    }
  }

  /// 流式一轮：累积 assistant 消息（含 reasoning / tool_calls），执行工具并写回 [messages]。
  ///
  /// [terminal_run] / [file_write] 需用户确认；其余注册工具自动执行。
  Future<void> runTurnStreaming({
    required List<Map<String, Object?>> messages,
    required TerminalSessionController? ssh,
    required bool useZhTools,
    required Future<bool> Function(String commandText)
    onRequestTerminalApproval,
    Future<bool> Function(String path, String contentPreview)?
    onRequestFileWriteApproval,
    void Function(String toolName, String status, {String? detail})?
    onToolProgress,
    required void Function({String? reasoningDelta, String? contentDelta})
    onStreamDelta,
    void Function()? onStreamRoundStart,
    void Function()? onMessagesChanged,
    LlmStreamCancel? cancel,
    int maxToolRounds = 8,
  }) async {
    void touchMessages() => onMessagesChanged?.call();
    final toolList = allTools(zh: useZhTools);
    for (var round = 0; round < maxToolRounds; round++) {
      if (cancel?.isCancelled == true) {
        return;
      }
      onStreamRoundStart?.call();
      final streamed = await _streamOneAssistantResponse(
        messages: messages,
        tools: toolList,
        onDelta: onStreamDelta,
        cancel: cancel,
      );

      if (streamed.userCancelled) {
        messages.add(_stoppedAssistantApiMessage(streamed, useZhTools));
        touchMessages();
        return;
      }

      messages.add(streamed.toAssistantMessageMap());
      touchMessages();

      final toolCalls = streamed.toolCalls;
      if (toolCalls == null || toolCalls.isEmpty) {
        return;
      }

      for (final tc in toolCalls) {
        if (cancel?.isCancelled == true) {
          return;
        }
        final id = tc['id'] as String?;
        final fn = tc['function'];
        if (id == null || fn is! Map) continue;
        final f = Map<String, Object?>.from(Map<String, dynamic>.from(fn));
        final name = f['name'] as String? ?? '';
        final argsRaw = f['arguments'];
        final args = parseToolArgs(argsRaw);

        try {
          await _executeOneToolCall(
            id: id,
            name: name,
            args: args,
            argsRaw: argsRaw,
            messages: messages,
            ssh: ssh,
            onRequestTerminalApproval: onRequestTerminalApproval,
            onRequestFileWriteApproval: onRequestFileWriteApproval,
            onToolProgress: onToolProgress,
            touchMessages: touchMessages,
          );
        } catch (e) {
          onToolProgress?.call(name, 'failure', detail: '$e');
          messages.add(
            _toolResultMessage(
              id: id,
              name: name.isEmpty ? 'unknown' : name,
              content: toolJsonErr('exception', detail: '$e'),
              status: 'failure',
              detail: '$e',
            ),
          );
          touchMessages();
        }
      }
    }
    messages.add({
      'role': 'assistant',
      'content': useZhTools
          ? '（工具调用轮数过多，请缩短任务。）'
          : '(Too many tool rounds; try a shorter task.)',
    });
    touchMessages();
  }

  Future<void> _executeOneToolCall({
    required String id,
    required String name,
    required Map<String, dynamic> args,
    required Object? argsRaw,
    required List<Map<String, Object?>> messages,
    required TerminalSessionController? ssh,
    required Future<bool> Function(String commandText) onRequestTerminalApproval,
    required Future<bool> Function(String path, String contentPreview)?
        onRequestFileWriteApproval,
    required void Function(String toolName, String status, {String? detail})?
        onToolProgress,
    required void Function() touchMessages,
  }) async {
    if (name == _terminalToolName) {
      final cmd = _parseTerminalTextArg(argsRaw);
      if (cmd == null || cmd.isEmpty) {
        messages.add(
          _toolResultMessage(
            id: id,
            name: name,
            content: jsonEncode({'ok': false, 'error': 'missing_text'}),
            status: 'failure',
            detail: 'missing_text',
          ),
        );
        touchMessages();
        return;
      }
      onToolProgress?.call(name, 'running', detail: cmd);
      final approved = await onRequestTerminalApproval(cmd);
      if (!approved) {
        onToolProgress?.call(name, 'failure', detail: 'user_denied');
        messages.add(
          _toolResultMessage(
            id: id,
            name: name,
            content: jsonEncode({
              'ok': false,
              'error': 'user_denied',
              'detail': 'User declined to run this command.',
            }),
            status: 'failure',
            detail: 'user_denied',
          ),
        );
        touchMessages();
        return;
      }
      final result = await _runTerminalToolWithCapture(cmd, ssh);
      final ok = _toolResultOk(result);
      onToolProgress?.call(
        name,
        ok ? 'success' : 'failure',
        detail: cmd.length > 80 ? '${cmd.substring(0, 80)}…' : cmd,
      );
      messages.add(
        _toolResultMessage(
          id: id,
          name: name,
          content: result,
          status: ok ? 'success' : 'failure',
          detail: cmd.length > 80 ? '${cmd.substring(0, 80)}…' : cmd,
        ),
      );
      touchMessages();
      return;
    }

    if (name == _fileWriteToolName) {
      final path = (_argString(args, 'path') ?? '').trim();
      final content = _argString(args, 'content') ?? '';
      if (path.isEmpty) {
        messages.add(
          _toolResultMessage(
            id: id,
            name: name,
            content: toolJsonErr('missing_path'),
            status: 'failure',
            detail: 'missing_path',
          ),
        );
        touchMessages();
        return;
      }
      // Normalize args so FileWriteExecutor always sees strings.
      args['path'] = path;
      args['content'] = content;
      final preview = content.length > 4000
          ? '${content.substring(0, 4000)}…'
          : content;
      onToolProgress?.call(name, 'running', detail: path);
      final approve =
          onRequestFileWriteApproval ??
          ((p, _) => onRequestTerminalApproval('file_write $p'));
      final approved = await approve(path, preview);
      if (!approved) {
        onToolProgress?.call(name, 'failure', detail: 'user_denied');
        messages.add(
          _toolResultMessage(
            id: id,
            name: name,
            content: jsonEncode({
              'ok': false,
              'error': 'user_denied',
              'detail': 'User declined to write this file.',
            }),
            status: 'failure',
            detail: path,
          ),
        );
        touchMessages();
        return;
      }
      if (ssh == null || !ssh.connected) {
        messages.add(
          _toolResultMessage(
            id: id,
            name: name,
            content: toolJsonErr('no_active_ssh_session'),
            status: 'failure',
            detail: path,
          ),
        );
        touchMessages();
        return;
      }
      final result = await toolRegistry.execute(
        name,
        args,
        ToolContext(
          controller: ssh,
          onProgress: (n, s) => onToolProgress?.call(n, 'running', detail: s),
        ),
      );
      final ok = _toolResultOk(result);
      onToolProgress?.call(name, ok ? 'success' : 'failure', detail: path);
      messages.add(
        _toolResultMessage(
          id: id,
          name: name,
          content: result,
          status: ok ? 'success' : 'failure',
          detail: path,
        ),
      );
      touchMessages();
      return;
    }

    if (toolRegistry.contains(name)) {
      if (ssh == null || !ssh.connected) {
        messages.add(
          _toolResultMessage(
            id: id,
            name: name,
            content: toolJsonErr('no_active_ssh_session'),
            status: 'failure',
          ),
        );
        touchMessages();
        return;
      }
      onToolProgress?.call(name, 'running');
      final result = await toolRegistry.execute(
        name,
        args,
        ToolContext(
          controller: ssh,
          onProgress: (n, s) => onToolProgress?.call(n, 'running', detail: s),
        ),
      );
      final ok = _toolResultOk(result);
      final detail = _summarizeToolArgs(name, args);
      onToolProgress?.call(name, ok ? 'success' : 'failure', detail: detail);
      messages.add(
        _toolResultMessage(
          id: id,
          name: name,
          content: result,
          status: ok ? 'success' : 'failure',
          detail: detail,
        ),
      );
      touchMessages();
      return;
    }

    messages.add(
      _toolResultMessage(
        id: id,
        name: name.isEmpty ? 'unknown' : name,
        content: jsonEncode({
          'ok': false,
          'error': 'unknown_tool',
          'name': name,
        }),
        status: 'failure',
        detail: 'unknown_tool',
      ),
    );
    touchMessages();
  }

  static String? _argString(Map<String, dynamic> args, String key) {
    final v = args[key];
    if (v is String) return v;
    if (v == null) return null;
    return v.toString();
  }

  static Map<String, Object?> _toolResultMessage({
    required String id,
    required String name,
    required String content,
    required String status,
    String? detail,
  }) {
    return {
      'role': 'tool',
      'tool_call_id': id,
      'content': content,
      '_ui_tool': {
        'name': name,
        'status': status,
        if (detail != null && detail.isNotEmpty) 'detail': detail,
      },
    };
  }

  static bool _toolResultOk(String content) {
    try {
      final d = jsonDecode(content);
      return d is Map && d['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  static String? _summarizeToolArgs(String name, Map<String, dynamic> args) {
    for (final key in ['path', 'pattern', 'query', 'filter', 'text']) {
      final v = args[key];
      if (v is String && v.trim().isNotEmpty) {
        final s = v.trim();
        return s.length > 80 ? '${s.substring(0, 80)}…' : s;
      }
    }
    return name;
  }

  static Map<String, Object?> _stoppedAssistantApiMessage(
    _StreamedAssistant s,
    bool useZh,
  ) {
    var body = s.content.trim();
    final rc = s.reasoning;
    if (body.isEmpty && rc.trim().isEmpty) {
      body = useZh ? '（已停止）' : '(Stopped.)';
    } else {
      body = '$body${useZh ? '\n\n（输出已停止。）' : '\n\n(Output stopped.)'}';
    }
    return {'role': 'assistant', 'content': body, 'reasoning_content': rc};
  }

  Future<_StreamedAssistant> _streamOneAssistantResponse({
    required List<Map<String, Object?>> messages,
    required List<Map<String, Object?>> tools,
    required void Function({String? reasoningDelta, String? contentDelta})
    onDelta,
    LlmStreamCancel? cancel,
  }) async {
    final uri = resolveChatCompletionsUri(baseUrl);
    final headers = <String, String>{'Content-Type': 'application/json'};
    final key = apiKey.trim();
    if (key.isNotEmpty) {
      headers['Authorization'] = 'Bearer $key';
    }

    final body = jsonEncode({
      'model': model,
      'messages': messagesForApiRequest(messages),
      'tools': tools,
      'tool_choice': 'auto',
      'stream': true,
    });

    final client = http.Client();
    try {
      final request = http.Request('POST', uri);
      request.headers.addAll(headers);
      request.body = body;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 180));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errBody = await response.stream.bytesToString();
        final snippet = errBody.length > 800
            ? '${errBody.substring(0, 800)}…'
            : errBody;
        throw LlmHttpException(response.statusCode, snippet);
      }

      final reasoning = StringBuffer();
      final content = StringBuffer();
      final tagSplit = _RedactedThinkingSplitter();
      final toolAgg = _StreamingToolCallAgg();

      String? finishReason;
      var userCancelled = false;

      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (cancel?.isCancelled == true) {
          userCancelled = true;
          break;
        }
        if (line.isEmpty) continue;
        if (line.startsWith(':')) continue;
        if (line == 'data: [DONE]') break;
        if (!line.startsWith('data: ')) continue;
        final payload = line.substring(6).trim();
        if (payload.isEmpty) continue;
        final decoded = jsonDecode(payload);
        if (decoded is! Map) continue;
        final root = Map<String, Object?>.from(
          Map<String, dynamic>.from(decoded),
        );

        final err = root['error'];
        if (err is Map) {
          final em = Map<String, Object?>.from(Map<String, dynamic>.from(err));
          final msg = em['message'] ?? em.toString();
          throw FormatException('API error: $msg');
        }

        final choices = root['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final c0 = choices.first;
        if (c0 is! Map) continue;
        final choice = Map<String, Object?>.from(Map<String, dynamic>.from(c0));

        final fr = choice['finish_reason'];
        if (fr is String) finishReason = fr;

        final delta = choice['delta'];
        if (delta is! Map) continue;
        final d = Map<String, Object?>.from(Map<String, dynamic>.from(delta));

        for (final rk in _reasoningKeys) {
          final v = d[rk];
          if (v is String && v.isNotEmpty) {
            reasoning.write(v);
            onDelta(reasoningDelta: v, contentDelta: null);
          }
        }

        final dc = d['content'];
        if (dc is String && dc.isNotEmpty) {
          for (final seg in tagSplit.push(dc)) {
            if (seg.isThinking) {
              reasoning.write(seg.text);
              onDelta(reasoningDelta: seg.text, contentDelta: null);
            } else {
              content.write(seg.text);
              onDelta(reasoningDelta: null, contentDelta: seg.text);
            }
          }
        }

        final tcd = d['tool_calls'];
        if (tcd is List) {
          toolAgg.applyDeltas(tcd);
        }
      }

      for (final seg in tagSplit.flush()) {
        if (seg.isThinking) {
          reasoning.write(seg.text);
        } else {
          content.write(seg.text);
        }
      }

      if (userCancelled) {
        return _StreamedAssistant(
          reasoning: reasoning.toString(),
          content: content.toString(),
          toolCalls: null,
          userCancelled: true,
        );
      }

      final toolsDone = toolAgg.finish();
      final hasTools =
          toolsDone.isNotEmpty ||
          finishReason == 'tool_calls' ||
          (finishReason?.contains('tool') ?? false);

      return _StreamedAssistant(
        reasoning: reasoning.toString(),
        content: content.toString(),
        toolCalls: hasTools ? toolsDone : null,
      );
    } finally {
      client.close();
    }
  }

  static const _reasoningKeys = <String>[
    'reasoning_content',
    'reasoning',
    'thinking',
    'thought',
  ];

  static String? _parseTerminalTextArg(Object? arguments) {
    if (arguments is! String) return null;
    final raw = arguments.trim();
    if (raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      if (d is Map && d['text'] is String) {
        return d['text'] as String;
      }
    } catch (_) {
      return raw;
    }
    return null;
  }

  static Future<String> _runTerminalToolWithCapture(
    String text,
    TerminalSessionController? ssh,
  ) async {
    if (ssh == null || !ssh.connected) {
      return jsonEncode({'ok': false, 'error': 'no_active_ssh_session'});
    }
    final payload = ssh.pasteRemoteInputWithLineSubmit(text);
    final autoNl = payload != text;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final tail = ssh.snapshotTerminalTail(maxLines: 160, maxChars: 32000);
    const maxEcho = 12000;
    final echoBody = tail.length > maxEcho
        ? '… (${tail.length} chars total, showing last $maxEcho)\n${tail.substring(tail.length - maxEcho)}'
        : tail;
    ssh.injectTerminalLocalDisplay(
      '\r\n\x1b[33m──────── EasyTerm · assistant · captured output ────────\x1b[0m\r\n'
      '$echoBody\r\n'
      '\x1b[33m────────────────────────────────────────────────────────\x1b[0m\r\n',
    );
    return jsonEncode({
      'ok': true,
      'injected_bytes': payload.length,
      'newline_auto_appended': autoNl,
      'terminal_tail': tail,
      'hint':
          'This is the terminal buffer tail after injection and a short delay; more output may still arrive.',
    });
  }
}

final class LlmHttpException implements Exception {
  LlmHttpException(this.statusCode, this.bodySnippet);

  final int statusCode;
  final String bodySnippet;

  @override
  String toString() => 'HTTP $statusCode: $bodySnippet';
}

// --- Streaming accumulation ---

final class _StreamedAssistant {
  _StreamedAssistant({
    required this.reasoning,
    required this.content,
    required this.toolCalls,
    this.userCancelled = false,
  });

  final String reasoning;
  final String content;
  final List<Map<String, Object?>>? toolCalls;

  /// 用户点击「停止」等导致流式中断；不得再执行可能不完整的 tool_calls。
  final bool userCancelled;

  Map<String, Object?> toAssistantMessageMap() {
    final m = <String, Object?>{
      'role': 'assistant',
      'content': content,
      'reasoning_content': reasoning,
    };
    if (!userCancelled && toolCalls != null && toolCalls!.isNotEmpty) {
      m['tool_calls'] = toolCalls;
    }
    return m;
  }
}

final class _StreamingToolCallPart {
  String? id;
  String type = 'function';
  String? name;
  final StringBuffer arguments = StringBuffer();
}

final class _StreamingToolCallAgg {
  final Map<int, _StreamingToolCallPart> byIndex = {};

  void applyDeltas(List<dynamic> deltas) {
    for (final raw in deltas) {
      if (raw is! Map) continue;
      final d = Map<String, Object?>.from(Map<String, dynamic>.from(raw));
      final idxRaw = d['index'];
      final int? idx = idxRaw is int
          ? idxRaw
          : (idxRaw is num ? idxRaw.toInt() : null);
      if (idx == null) continue;
      final part = byIndex.putIfAbsent(idx, _StreamingToolCallPart.new);
      final id = d['id'];
      if (id is String && id.isNotEmpty) part.id = id;
      final tp = d['type'];
      if (tp is String && tp.isNotEmpty) part.type = tp;
      final fn = d['function'];
      if (fn is Map) {
        final f = Map<String, Object?>.from(Map<String, dynamic>.from(fn));
        final nm = f['name'];
        if (nm is String && nm.isNotEmpty) part.name = nm;
        final ar = f['arguments'];
        if (ar is String && ar.isNotEmpty) part.arguments.write(ar);
      }
    }
  }

  List<Map<String, Object?>> finish() {
    final keys = byIndex.keys.toList()..sort();
    final out = <Map<String, Object?>>[];
    for (final i in keys) {
      final p = byIndex[i]!;
      final id = p.id ?? 'call_${i}_${DateTime.now().millisecondsSinceEpoch}';
      final name = p.name ?? '';
      out.add({
        'id': id,
        'type': p.type,
        'function': {'name': name, 'arguments': p.arguments.toString()},
      });
    }
    return out;
  }
}

final class _ThinkSegment {
  _ThinkSegment(this.text, {required this.isThinking});
  final String text;
  final bool isThinking;
}

/// 将部分模型放在正文里的思考标签（如 `<think>` / `<think>`）拆到思考区。
final class _RedactedThinkingSplitter {
  /// 短标签 `<think>`（若模型使用）。
  static final _openThink = RegExp(r'<\s*think\s*>', caseSensitive: false);
  static final _closeThink = RegExp(r'<\s*/\s*think\s*>', caseSensitive: false);
  static final _openRedactedThinking = RegExp(
    r'<\s*redacted_thinking\s*>',
    caseSensitive: false,
  );
  static final _closeRedactedThinking = RegExp(
    r'<\s*/\s*redacted_thinking\s*>',
    caseSensitive: false,
  );
  static final _openReasoning = RegExp(
    r'<\s*redacted[_\s-]*reasoning\s*>',
    caseSensitive: false,
  );
  static final _closeReasoning = RegExp(
    r'<\s*/\s*redacted[_\s-]*reasoning\s*>',
    caseSensitive: false,
  );

  String _carry = '';
  bool _inThink = false;
  RegExp? _activeClose;

  List<_ThinkSegment> push(String chunk) {
    _carry += chunk;
    final out = <_ThinkSegment>[];
    while (true) {
      if (!_inThink) {
        Match? best;
        for (final (op, cl) in [
          (_openRedactedThinking, _closeRedactedThinking),
          (_openThink, _closeThink),
          (_openReasoning, _closeReasoning),
        ]) {
          final m = op.firstMatch(_carry);
          if (m != null && (best == null || m.start < best.start)) {
            best = m;
            _activeClose = cl;
          }
        }
        if (best == null) {
          if (_carry.contains('<')) {
            final cut = _carry.lastIndexOf('<');
            if (cut > 0) {
              out.add(
                _ThinkSegment(_carry.substring(0, cut), isThinking: false),
              );
              _carry = _carry.substring(cut);
            }
            break;
          }
          out.add(_ThinkSegment(_carry, isThinking: false));
          _carry = '';
          break;
        }
        if (best.start > 0) {
          out.add(
            _ThinkSegment(_carry.substring(0, best.start), isThinking: false),
          );
        }
        _carry = _carry.substring(best.end);
        _inThink = true;
        continue;
      }
      final close = _activeClose ?? _closeThink;
      final cm = close.firstMatch(_carry);
      if (cm == null) {
        break;
      }
      out.add(_ThinkSegment(_carry.substring(0, cm.start), isThinking: true));
      _carry = _carry.substring(cm.end);
      _inThink = false;
      _activeClose = null;
    }
    return out;
  }

  List<_ThinkSegment> flush() {
    final out = <_ThinkSegment>[];
    if (_inThink) {
      out.add(_ThinkSegment(_carry, isThinking: true));
    } else if (_carry.isNotEmpty) {
      out.add(_ThinkSegment(_carry, isThinking: false));
    }
    _carry = '';
    _inThink = false;
    _activeClose = null;
    return out;
  }
}
