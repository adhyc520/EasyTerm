# 终端生产力：终端内搜索、命令书签、会话录制、输出复制

> 现状：xterm 4.0.0 提供完整的终端模拟，但缺少终端内搜索、命令管理、会话录制等生产力功能。`TerminalSurface` 仅做基础渲染，`SshWorkspaceController` 管理连接生命周期但无录制能力。

---

## 1. 现状评估

| 模块 | 文件 | 现状 |
|------|------|------|
| 终端表面 | `lib/widgets/terminal_surface.dart` | xterm `TerminalView` 包装，有上下文菜单、选择复制、粘贴 |
| 终端控制器 | `lib/services/ssh_workspace_controller.dart` | PTY 读写、输出拦截（OSC 7）、鼠标模式 |
| 输出拦截 | `lib/services/pty_interceptor.dart` | 解析 OSC 7 和鼠标模式序列 |
| 代码片段 | `lib/services/code_snippets_store.dart` | 代码片段 CRUD，与终端独立 |
| 会话分屏 | `lib/services/session_pane.dart` | 分屏树结构 |
| xterm 库 | 第三方包 `xterm: ^4.0.0` | 提供 `Terminal.buffer`、`Terminal.search`（v4） |

**关键缺口：**
1. 无法在终端输出中搜索文本（Cmd+F 在终端无响应）
2. 无命令书签/快捷指令（每次手动输入重复命令）
3. 无会话录制/回放（无法复盘操作）
4. 终端选择后只能鼠标复制，无键盘复制模式
5. 终端缓冲区无导出能力

---

## 2. 工作流 B1（P0）：终端内搜索

### 2.1 搜索栏

在 `TerminalSurface` 上叠加搜索栏（类似 `editor_find_bar.dart`）：

```
┌─────────────────────────────────────────────────┐
│ 🔍 [search term          ]  ▲  ▼  1/12  [Aa] [.*]  ✕ │
│ 终端内容...                                      │
└─────────────────────────────────────────────────┘
```

- `Cmd+F` / `Ctrl+F` 打开搜索栏
- 输入即搜索（防抖 200ms）
- 上下箭头跳转匹配项
- `Aa` 切换大小写敏感
- `.*` 切换正则模式
- 匹配项高亮（黄色背景）
- 自动滚动到匹配位置

### 2.2 搜索实现

```dart
class TerminalSearchController {
  final Terminal terminal;
  
  List<TerminalMatch> search(String pattern, {bool caseSensitive = true, bool regex = false}) {
    // 使用 xterm 4.0 的 Terminal.search() API
    // 或回退到遍历 buffer lines
  }
  
  void highlightMatches(List<TerminalMatch> matches);
  void navigateToMatch(int index);
  void clearHighlights();
}
```

**技术细节：**
- xterm 4.0.0 的 `Terminal` 类有 `search()` 方法，但需要确认具体 API
- 如果没有，则遍历 `terminal.buffer.lines`（`BufferString` 列表）
- 高亮通过修改终端渲染器的颜色覆写实现
- 搜索栏打开时，终端内容向上偏移 40px 避免遮挡

### 2.3 搜索栏 UI 组件

```dart
class TerminalFindBar extends StatefulWidget {
  // 复用 EditorFindBar 的设计模式（lib/widgets/editor_find_bar.dart）
  // 终端专用：无替换功能，有上下导航
  final TerminalSearchController searchController;
  final VoidCallback onClose;
}
```

---

## 3. 工作流 B2（P0）：命令书签

### 3.1 快捷命令面板

在终端中按 `Cmd+Shift+P`（或自定义快捷键）打开命令面板：

```
┌──────────────────────────────────────────────────┐
│ 🔍 搜索命令...                                    │
│ ──────────────────────────────────────────────── │
│ 📌 systemctl status nginx          # 查看 nginx 状态 │
│ 📌 journalctl -u nginx -f          # 跟踪 nginx 日志 │
│ 📌 df -h | grep -v tmpfs           # 磁盘使用       │
│ 📌 docker ps --format '{{.Names}}' # 容器列表       │
│ ──────────────────────────────────────────────── │
│ + 新增命令                                        │
└──────────────────────────────────────────────────┘
```

### 3.2 命令书签存储

扩展 `CodeSnippetsStore`：

```dart
class CommandBookmark {
  String id;
  String label;         // 显示名称
  String command;       // 命令内容
  String? description;  // 备注
  String? hostPattern;  // 限定主机（glob），null = 全局
  List<String> tags;    // 标签
  int useCount;         // 使用次数
  DateTime lastUsed;
  DateTime createdAt;
}
```

### 3.3 命令书签 UI

- 终端内快速搜索（输入 `> ` 前缀激活搜索）
- 右键菜单「添加到书签」
- 标签筛选
- 按使用频率排序

---

## 4. 工作流 B3（P1）：会话录制与回放

### 4.1 录制

```dart
class SessionRecorder {
  final List<SessionEvent> _events = [];
  bool _recording = false;
  DateTime? _startTime;
  
  void start();
  void stop();
  Future<void> saveToFile(String path);
  
  // 事件类型
  void recordOutput(String data, DateTime timestamp);
  void recordInput(String data, DateTime timestamp);
  void recordResize(int cols, int rows, DateTime timestamp);
}

class SessionEvent {
  final SessionEventType type; // input, output, resize
  final String data;
  final Duration offset;       // 从录制开始的时间偏移
}
```

**录制介入点：** 在 `SshWorkspaceController` 的 `term.write` 调用之后、PTY 输出写入 terminal 之前，插入录制钩子。

### 4.2 回放

```dart
class SessionPlayer {
  Future<void> loadFromFile(String path);
  void play({double speed = 1.0});
  void pause();
  void seek(Duration offset);
  void stop();
}
```

回放 UI：在 `TerminalSurface` 上叠加控制栏（播放/暂停/速度/进度条）。

### 4.3 导出格式

- **asciicast v2**：兼容 asciinema.org 播放器（`https://asciinema.org`）
- **原始文本**：纯文本带时间戳
- **JSON**：内部格式，用于回放

---

## 5. 工作流 B4（P1）：输出复制模式

### 5.1 键盘复制模式

类似 tmux 的复制模式，纯键盘操作：

```
Enter 复制模式 (C-b [ 风格)
  ↓
vi 键移动 (h/j/k/l/w/b/0/$/G/gg)
  ↓
v 开始选择 (Visual 模式)
  ↓
y 复制到剪贴板
  ↓
Esc 退出复制模式
```

### 5.2 实现方案

```dart
class TerminalCopyMode {
  bool _active = false;
  int _cursorRow = 0;
  int _cursorCol = 0;
  int _selectionStartRow = -1;
  int _selectionStartCol = -1;
  bool _visualMode = false;
  
  void handleKey(LogicalKeyboardKey key);
  void moveCursor(int dRow, int dCol);
  void toggleVisual();
  void copySelection();
  void exit();
}
```

在 `TerminalSurface` 的键盘处理中，当复制模式激活时，拦截所有按键。

---

## 6. 工作流 B5（P2）：终端输出导出

- 导出选中区域为文本
- 导出整个缓冲区为文本
- 导出为带 ANSI 颜色的 HTML（用于分享）
- 一键复制最近 N 行输出

---

## 7. 文件清单

### 新建文件
| 文件 | 说明 |
|------|------|
| `lib/widgets/terminal_find_bar.dart` | 终端搜索栏 |
| `lib/services/terminal_search_controller.dart` | 终端搜索逻辑 |
| `lib/services/command_bookmark_store.dart` | 命令书签存储 |
| `lib/widgets/command_palette_overlay.dart` | 命令面板弹层 |
| `lib/services/session_recorder.dart` | 会话录制器 |
| `lib/services/session_player.dart` | 会话回放器 |
| `lib/services/terminal_copy_mode.dart` | 键盘复制模式 |
| `lib/widgets/terminal_recording_controls.dart` | 录制/回放控制栏 |

### 修改文件
| 文件 | 改动 |
|------|------|
| `lib/widgets/terminal_surface.dart` | 集成搜索栏、复制模式、录制状态、命令面板 |
| `lib/services/ssh_workspace_controller.dart` | 插入录制钩子、导出终端缓冲 |
| `lib/services/workbench_desktop_shortcuts.dart` | 新增搜索、复制模式、命令面板快捷键 |

---

## 8. 非目标

- 不做 tmux/screen 集成（那是服务端的事）
- 不做终端主题商店（可手动配置颜色）
- 不做终端插件系统（太重）
- 不做 asciicast 在线播放（仅本地回放 + 导出）

---

## 9. 测试

- 单元测试：搜索匹配（大小写/正则）、录制事件序列化、复制模式光标移动
- Widget 测试：搜索栏显示/隐藏、命令面板筛选、回放控制栏
- 集成测试：录制-回放往返、搜索高亮与导航

---

## 10. 风险

| 风险 | 缓解 |
|------|------|
| xterm 4.0 search API 不存在 | 回退到遍历 buffer lines |
| 录音文件过大（长时间会话） | 限制最大录制时长（2h）+ 压缩存储 |
| 复制模式与终端应用快捷键冲突 | 复制模式独占键盘，退出时恢复 |
| 命令书签跨主机不适用 | 支持 hostPattern 限定主机 |