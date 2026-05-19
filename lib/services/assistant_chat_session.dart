import 'package:flutter/foundation.dart';

import 'llm_openai_chat_service.dart';

/// 单个 SSH 标签页的助手对话状态（切换标签时保留，关闭标签时销毁）。
class AssistantChatSession extends ChangeNotifier {
  final List<Map<String, Object?>> messages = [];
  bool busy = false;
  LlmStreamCancel? streamCancel;
  String streamReasoning = '';
  String streamContent = '';
  String draftInput = '';

  void touch() => notifyListeners();

  void ensureSystemMessage({required bool zh}) {
    if (messages.isEmpty) {
      messages.add(_systemMessage(zh: zh));
      return;
    }
    final first = messages.first;
    if (first['role'] == 'system') {
      first['content'] = _systemMessage(zh: zh)['content'];
    } else {
      messages.insert(0, _systemMessage(zh: zh));
    }
    touch();
  }

  void reset({required bool zh}) {
    streamReasoning = '';
    streamContent = '';
    busy = false;
    streamCancel?.cancel();
    streamCancel = null;
    messages
      ..clear()
      ..add(_systemMessage(zh: zh));
    touch();
  }

  @override
  void dispose() {
    streamCancel?.cancel();
    streamCancel = null;
    super.dispose();
  }

  static Map<String, Object?> _systemMessage({required bool zh}) => {
    'role': 'system',
    'content': zh
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
  };
}
