# AI 助手 2.0：LLM 工具链扩展、上下文感知、多步任务、会话持久化

> 现状：`LlmOpenAiChatService` 仅有一个 `terminal_run` 工具，单向注入终端文本。没有文件系统访问、系统状态感知、对话历史持久化。UI 侧 `assistant_side_panel.dart` 有基础聊天气泡，但无多步任务进度、无工具调用可视化。

---

## 1. 现状评估（附文件:行号）

| 模块 | 文件 | 现状 |
|------|------|------|
| LLM 服务 | `lib/services/llm_openai_chat_service.dart` | 仅 `terminal_run` 一个工具（:29-50），OpenAI 兼容流式，无函数调用结果回传 |
| 聊天会话 | `lib/services/assistant_chat_session.dart` | 消息列表 + 基础流式回调，无工具调用状态机 |
| 聊天 UI | `lib/widgets/assistant_side_panel.dart` | 基础面板 + 消息列表，无工具调用可视化 |
| 聊天气泡 | `lib/widgets/assistant_chat_bubble.dart` | 用户/助手气泡，无工具调用卡片 |
| 聊天 Markdown | `lib/widgets/assistant_chat_markdown.dart` | 基础 Markdown 渲染 |
| LLM 设置 | `lib/widgets/workbench_llm_settings_dialog.dart` | API 地址/Key/模型选择 |
| 终端回传 | `lib/services/ssh_workspace_controller.dart` | `pasteRemoteInputWithLineSubmit`（:1485 附近），可获取终端尾部输出 |

**关键缺口：**
1. 没有文件系统工具（读/写/列表/搜索文件）
2. 没有系统信息工具（进程/磁盘/网络状态）
3. 工具调用结果不回传给 LLM（无多步推理）
4. 没有上下文注入（当前目录、系统信息、最近命令）
5. 对话历史不持久化（刷新即丢失）
6. UI 不展示工具调用过程（用户不知道 AI 在做什么）

---

## 2. 工作流 A1（P0）：工具链扩展

### 2.1 新增工具定义

在 `LlmOpenAiChatService` 中新增以下工具：

```dart
// 文件系统工具
static const _toolReadFile = 'file_read';
static const _toolWriteFile = 'file_write';
static const _toolListDir = 'file_list';
static const _toolSearchFile = 'file_search';
static const _toolSearchContent = 'file_grep';

// 系统信息工具
static const _toolSystemInfo = 'system_info';      // uname, uptime, distro
static const _toolProcessList = 'process_list';     // ps aux
static const _toolDiskUsage = 'disk_usage';         // df -h
static const _toolNetworkInfo = 'network_info';     // ip addr, ss -tlnp
static const _toolPackageQuery = 'package_query';   // dpkg -l / rpm -qa

// 终端工具（已有）
static const _toolTerminalRun = 'terminal_run';     // 现有

// 多步控制
static const _toolTaskComplete = 'task_complete';   // 标记任务完成
```

### 2.2 工具执行器

每个工具对应一个 `ToolExecutor`：

```dart
abstract class ToolExecutor {
  String get toolName;
  Future<String> execute(Map<String, dynamic> args, ToolContext ctx);
}

class ToolContext {
  final SshWorkspaceController controller;
  final void Function(String toolName, String status) onProgress;
}
```

**执行策略：**
- 文件读写：复用 `SftpBrowserHost` 的 SFTP 通道（`lib/services/sftp_browser_host.dart`）
- 系统信息：复用已有的 `RemoteHostMetrics`、`RemoteProcessList`、`RemoteDiskUsage` 等
- 文件搜索：`find` + `grep` 通过 `runRemoteForStatus` 执行
- 所有工具结果以 JSON 字符串返回给 LLM

### 2.3 工具调用闭环

当前流程：用户消息 → LLM 流式响应 → 显示。**没有** tool_calls 回传。

新流程：
```
用户消息 → LLM 响应（含 tool_calls）
  → 解析 tool_calls → 执行工具 → 收集结果
  → 构造 assistant message（含 tool_calls）+ tool result messages
  → 再次请求 LLM → 最终响应
```

**关键实现：`LlmChatSession` 状态机**

```dart
enum LlmSessionState {
  idle,          // 等待用户输入
  streaming,     // 正在接收 LLM 响应
  executing,     // 正在执行工具调用
  waitingConfirm,// 等待用户确认（terminal_run 等危险操作）
}

class LlmChatSession {
  LlmSessionState state;
  List<ChatMessage> messages;       // 完整对话历史（含工具调用）
  List<ToolCall> pendingToolCalls;  // 当前待执行的工具调用
  int toolCallDepth;                // 防止无限循环
  static const maxToolCallDepth = 10;
}
```

---

## 3. 工作流 A2（P0）：上下文感知

### 3.1 系统上下文注入

每次对话开始时，自动注入系统上下文作为 system message：

```dart
Future<String> buildSystemContext(SshWorkspaceController c) async {
  final buf = StringBuffer();
  buf.writeln('## 当前环境');
  buf.writeln('- 主机: ${c.host}');
  buf.writeln('- 用户: ${c.username}');
  buf.writeln('- 当前目录: ${c.terminalCwd}');
  
  // 系统信息（缓存 5 分钟）
  final info = await _cachedSystemInfo(c);
  if (info != null) {
    buf.writeln('- 系统: ${info.uname}');
    buf.writeln('- 发行版: ${info.distro}');
    buf.writeln('- 运行时间: ${info.uptime}');
  }
  
  buf.writeln('\n## 行为准则');
  buf.writeln('- 修改文件前先读取确认内容');
  buf.writeln('- 危险命令（rm -rf, iptables, systemctl stop）需要用户额外确认');
  buf.writeln('- 优先使用绝对路径');
  
  return buf.toString();
}
```

### 3.2 工作目录感知

- 每次 `terminal_run` 执行后，更新 `c.terminalCwd`（已有 OSC 7 解析）
- 在 system prompt 中注入当前工作目录
- 支持 `cd` 命令自动更新上下文

### 3.3 最近命令历史

注入最近 5 条命令及其输出摘要：

```dart
void injectRecentCommands(List<CommandRecord> recent) {
  // 格式: 最近命令:
  //   $ ls -la /etc/nginx → (exit 0, 42 lines)
  //   $ cat /etc/nginx/nginx.conf → (exit 0, 117 lines)
}
```

---

## 4. 工作流 A3（P0）：UI 工具调用可视化

### 4.1 工具调用卡片

在 `assistant_chat_bubble.dart` 中新增 `ToolCallCard`：

```
┌─────────────────────────────────────────┐
│ 🔧 正在执行: file_read /etc/nginx/nginx.conf  │  ← 执行中（旋转）
│ ✅ 已读取: /etc/nginx/nginx.conf (117 行)    │  ← 完成
│ ❌ 失败: file_write /root/protected — 权限不足 │  ← 失败
└─────────────────────────────────────────┘
```

### 4.2 确认弹窗

对危险操作（terminal_run 默认需要确认，文件写入/删除需要确认），弹出确认卡片：

```dart
class ToolConfirmCard extends StatelessWidget {
  final ToolCall toolCall;
  final void Function(bool approved) onConfirm;
  // 显示命令内容，用户可选择:
  // - 执行一次
  // - 始终允许（本次会话）
  // - 拒绝
}
```

### 4.3 多步任务进度条

当 LLM 连续执行多个工具调用时，显示步骤进度：

```
┌──────────────────────────────────────────┐
│ 步骤 1/3: 读取配置文件 ✅                  │
│ 步骤 2/3: 分析配置 🔄                      │
│ 步骤 3/3: 生成修改建议 ⏳                   │
└──────────────────────────────────────────┘
```

---

## 5. 工作流 A4（P1）：会话持久化

### 5.1 对话存储

```dart
class AssistantChatStore {
  static const _kChatsPrefix = 'assistant_chats_';  // + hostKey
  
  Future<void> saveChats(String hostKey, List<ChatMessage> messages);
  Future<List<ChatMessage>> loadChats(String hostKey);
  Future<void> deleteChats(String hostKey);
  Future<List<String>> listHostsWithChats();
}
```

存储格式：JSON 序列化到 `shared_preferences`（小规模）或文件（大规模）。

### 5.2 对话管理

- 每个主机独立对话历史
- 支持清除对话
- 支持导出对话为 Markdown
- 对话列表（按时间排序）

---

## 6. 工作流 A5（P2）：高级功能

### 6.1 自定义 System Prompt

用户可在设置中自定义 system prompt 模板，支持变量：
- `{{host}}` — 主机名
- `{{user}}` — 用户名
- `{{cwd}}` — 当前目录
- `{{os}}` — 操作系统

### 6.2 预设 Prompt 模板

快速发送常用 prompt：
- "分析系统性能瓶颈"
- "检查安全配置"
- "查看磁盘空间占用最大的目录"
- "分析最近的错误日志"

### 6.3 多模型支持

当前仅支持 OpenAI 兼容 API。新增：
- Anthropic Claude API（需新增 `LlmAnthropicChatService`）
- 本地模型（Ollama 兼容）

---

## 7. 文件清单

### 新建文件
| 文件 | 说明 |
|------|------|
| `lib/services/llm_tool_executor.dart` | 工具执行器抽象 + 所有工具实现 |
| `lib/services/llm_chat_session.dart` | 聊天会话状态机（替换现有简单版） |
| `lib/services/assistant_chat_store.dart` | 对话持久化存储 |
| `lib/services/llm_context_builder.dart` | 系统上下文构建器 |
| `lib/widgets/assistant_tool_call_card.dart` | 工具调用可视化卡片 |
| `lib/widgets/assistant_tool_confirm_dialog.dart` | 工具确认弹窗 |
| `lib/widgets/assistant_prompt_templates.dart` | 预设 Prompt 模板 |

### 修改文件
| 文件 | 改动 |
|------|------|
| `lib/services/llm_openai_chat_service.dart` | 新增工具定义 + 函数调用闭环 |
| `lib/services/assistant_chat_session.dart` | 重写为状态机 |
| `lib/widgets/assistant_side_panel.dart` | 新增对话管理、历史列表 |
| `lib/widgets/assistant_chat_bubble.dart` | 新增工具调用卡片渲染 |
| `lib/widgets/assistant_chat_messages.dart` | 新增工具调用消息类型 |
| `lib/widgets/workbench_llm_settings_dialog.dart` | 新增 system prompt 自定义 |

---

## 8. 非目标

- 不做本地模型推理（需要 on-device ML，太重）
- 不做 Agent 循环（自动执行多步不需要用户确认）—— 始终保留用户确认环节
- 不做语音输入/输出
- 不做图片/多模态输入

---

## 9. 测试

- 单元测试：每个 `ToolExecutor` 的 JSON 解析和错误处理
- Widget 测试：工具调用卡片的三种状态（执行中/完成/失败）
- 集成测试：`LlmChatSession` 状态机转换（idle → streaming → executing → streaming → idle）
- 手动测试：真实 SSH 连接下的文件读写、命令执行、多步任务

---

## 10. 风险

| 风险 | 缓解 |
|------|------|
| LLM 生成危险命令（rm -rf） | terminal_run 默认需要确认 + 危险命令模式匹配告警 |
| 工具调用死循环 | `maxToolCallDepth = 10` 硬限制 |
| SFTP 通道不可用 | 文件工具降级为 `cat`/`echo` 通过终端执行 |
| 大文件读取超出 token 限制 | 自动截断 + 提示用户文件过大 |
| API 调用失败 | 重试 1 次 + 友好错误提示 |