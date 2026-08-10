# Follow Terminal Folder - 跟随终端当前目录方案

> 目标：终端模式 / 桌面终端里，用户在 shell 中 `cd` 后，文件浏览器（SFTP 侧栏 / 桌面文件管理器）能跟随到同一目录，并可在状态栏展示当前远端目录。
>
> 核心矛盾：当前 `_remoteCwd`（`ssh_workspace_controller.dart:392`）是 **SFTP 浏览器自己的目录**，由 SFTP 导航（`goInto`/`goUp`/`navigateToPath`，`:809-835`）更新，**完全不跟踪 shell 的 `cd`**。两者割裂--用户在终端 `cd /var/log` 后，文件侧栏还在原地。
>
> 方案：拦截 PTY → `terminal.write()` 的输出流，解析 **OSC 7**（`ESC ] 7 ; file://<host>/<path> BEL`，现代 bash/zsh/fish 的标准 cwd 上报序列），维护 `terminalCwd`，并把它作为「跟随源」同步给 SFTP 浏览器与状态栏。无 OSC 7 的环境提供降级手段。

---

## 0. 现状评估（已核实，含行号）

### 0.1 PTY 输出流喂给终端的唯一入口

`lib/services/ssh_workspace_controller.dart`：

```dart
// :734-751
void _wireShell() {
  final session = _shell;
  if (session == null) return;
  _stdoutSub?.cancel();
  _stderrSub?.cancel();
  final term = _terminal;
  if (term == null) return;
  _stdoutSub = session.stdout.listen((data) {
    term.write(utf8.decode(data, allowMalformed: true));   // :745 唯一 stdout 入口
  }, onError: (e) => debugPrint('stdout: $e'));
  _stderrSub = session.stderr.listen((data) {
    term.write(utf8.decode(data, allowMalformed: true));   // :749 stderr 入口
  }, onError: (e) => debugPrint('stderr: $e'));
}
```

- shell 由 `_client!.shell(pty: ...)` 创建（`:625`），`session.stdout/stderr` 是 `Stream<Uint8List>`。
- 终端输入侧：`Terminal(onOutput: ...)` 把按键写回 `session.write`（`:705-709`）。
- **这是 OSC 7 拦截的唯一点**：在 `term.write(...)` 前插一个扫描器即可。

### 0.2 `_remoteCwd` 不跟踪 shell

- 定义 `String _remoteCwd = '/'`（`:392`），`String get remoteCwd => _remoteCwd`（`:411`）。
- 初始：`_remoteCwd = await _sftp!.absolute('.')`（`:635`）--连上时取 SFTP 默认目录（通常是用户家目录）。
- 更新点全是 SFTP 浏览器导航：`goInto`（`:816`）、`goUp`（`:830`）、`navigateToPath`（`:858`）、`goHome`（`:835`）、`cdHistory`（`:794,803`）。
- **shell 里 `cd` 不会改 `_remoteCwd`**。所以「在此打开终端」从文件侧栏过去是准的（`terminal_app.dart:105-107` 用 `args['cwd'] ?? controller.remoteCwd`），但反方向（终端 → 文件侧栏）从不联动。

### 0.3 现有「终端 → 文件」单向联动（可复用入口）

- 桌面终端 `terminal_app.dart:129`：`widget.wm.open(DesktopAppType.files, args: {'cwd': path})`--「在当前目录打开文件管理器」，`path` 来自 `_resolveStartupCwd`（`:105-107`，读 `args['cwd']` 或 `controller.remoteCwd`）。当前用的还是 SFTP 的 `remoteCwd`，不是 shell 真实 cwd。
- 桌面文件管理器 `file_manager_app.dart:82-83`：`widget.window.args['cwd'] = _host.remoteCwd`。
- 即「打开文件」按钮已存在，只差 `path` 来源换成 `terminalCwd`。

### 0.4 xterm 4.0.0 不解析 OSC 7

- `terminal.dart` 仅暴露 `onTitleChange`（`:39`，对应 OSC 0/2）。
- OSC 解析器（`core/escape/parser.dart:1049-1079`）：`case '0'/'2'` 调 `setTitle`，其余走 `handler.unknownOSC`（`:1079`），**未公开给应用层**。
- grep `xterm-4.0.0/lib/src` 无 `case '7'`、无 cwd/file:// 处理。
- 结论：**不能靠 xterm 回调拿 cwd**，必须在 `term.write` 前自己扫。

### 0.5 远端 OS 区分已有

`RemoteOsKind`（`remote_shell_cd.dart:8`，linux/windows/unknown）与 `detectRemoteOs` 已在桌面终端用（`terminal_app.dart:241-251`）。OSC 7 的 `file://` URL 在 Windows 远端 OpenSSH 下一般不常见（PowerShell 默认不发），故 Windows 远端走降级路径（§3）。

---

## 1. 目标与范围

| 工作流 | 目标 | 优先级 |
|---|---|---|
| **A. PTY 流拦截器 + OSC 7 解析** | 新增 `PtyInterceptor`，在 `term.write` 前扫描，维护 `terminalCwd`；含鼠标模式状态机（与 nano 方案共用）。 | P0 |
| **B. terminalCwd 暴露与状态栏** | `SshWorkspaceController.terminalCwd` getter + 变更通知；终端模式状态栏 / 桌面终端底栏显示当前目录。 | P0 |
| **C. 跟随同步** | 「跟随终端目录」开关：开时 SFTP 侧栏 / 文件管理器在 `terminalCwd` 变化时自动导航过去（带防抖与用户手动操作优先）。 | P0 |
| **D. 降级与远端启用** | OSC 7 未发时的探测；提供「注入 shell 片段启用 OSC 7」的可选设置；Windows 远端降级。 | P1 |
| **E. 测试** | 拦截器单测（OSC 7 拼包/转义/异常）+ 跟随同步 widget 测试。 | P1 |

### 非目标
- 不改 `_remoteCwd` 的 SFTP 语义（仍由 SFTP 导航主导）；`terminalCwd` 是新增独立字段。
- 不实现完整 shell 集成（OSC 133 提示符标记、命令计时等）--仅取 cwd。
- 不强制注入远端 shell 配置（仅可选提示）。

---

## 2. 工作流 A：PTY 流拦截器 + OSC 7 解析（P0）

### 2.1 新增 `lib/services/pty_interceptor.dart`

一个有状态的流处理器，跨 chunk 维护 escape 解析状态：

```dart
/// 介于 PTY stdout 与 terminal.write 之间的扫描器。
/// - 解析 OSC 7 (`ESC ] 7 ; file://<host>/<path> BEL/ST`) -> 回调 cwd。
/// - 解析鼠标上报模式开关 (`CSI ?1000/1002/1003 h/l`) -> 回调 mouseMode。
/// 其余字节原样透传给 terminal.write。
class PtyInterceptor {
  PtyInterceptor({required this.onCwd, required this.onMouseMode});

  final void Function(String cwd) onCwd;
  final void Function(bool active) onMouseMode;

  final List<int> _buf = [];       // 跨 chunk 的未决 escape
  bool _inEsc = false;

  /// 喂入一段解码后的字符串，返回应原样写回 terminal 的字符串
  /// （OSC 7 / 鼠标模式序列可选择保留或剥离；保留更安全，xterm 会忽略 OSC 7）。
  String process(String input) {
    // 状态机：扫 ESC (0x1b)。
    //   ESC ] -> OSC，读到 BEL(0x07) 或 ST(ESC \) 结束。
    //     若 OSC body 以 "7;file://" 开头 -> 解析 path，回调 onCwd。
    //   ESC [ ? <num> h/l -> 鼠标模式开关，1000/1002/1003/1006/1015。
    // 跨 chunk：若读到一半 ESC 序列未结束，缓存剩余到 _buf，下次拼接。
    ...
  }
}
```

**解析要点**：
- `file://host/path` 的 path 部分做 `Uri.decodeFull`（OSC 7 的 path 是 percent-encoded）。
- 仅取 `file://` scheme；`file://localhost/...` 与 `file://<host>/...` 都接受，取 pathname。
- BEL(`\x07`) 与 ST(`\x1b\\`) 两种终止符都支持。
- **跨 chunk**：OSC 7 可能被分包（`ESC ] 7 ; file://host/va` + `r/log\x07`），状态机必须缓存。这是单测重点。
- 保留原序列透传：xterm 4.0.0 对 OSC 7 调 `unknownOSC` 无副作用（`parser.dart:1079`），保留可避免改流长度引发其它解析问题。亦可剥离（更干净），二选一，单测固定。

### 2.2 接入 `_wireShell`

```dart
// ssh_workspace_controller.dart
late final PtyInterceptor _ptyInterceptor = PtyInterceptor(
  onCwd: (cwd) => _onTerminalCwd(cwd),
  onMouseMode: (active) => _mouseMode = active,   // 给 nano 方案用
);

void _wireShell() {
  ...
  _stdoutSub = session.stdout.listen((data) {
    final decoded = utf8.decode(data, allowMalformed: true);
    final out = _ptyInterceptor.process(decoded);   // 扫描 + 透传
    term.write(out);
  }, onError: (e) => debugPrint('stdout: $e'));
  _stderrSub = session.stderr.listen((data) {
    term.write(utf8.decode(data, allowMalformed: true));  // stderr 不扫 OSC 7
  }, onError: (e) => debugPrint('stderr: $e'));
}
```

- stderr 不经拦截器（OSC 7 只走 stdout）。
- 鼠标模式状态机与本方案无关，但同处扫描，顺带产出 `_mouseMode` 供 `windows-nano-copy.md` §2.1 用，避免二次扫流。

### 2.3 `terminalCwd` 字段与通知

```dart
// ssh_workspace_controller.dart
String _terminalCwd = '/';
String get terminalCwd => _terminalCwd;
bool _followTerminalCwd = false;          // §3 开关
bool get followTerminalCwd => _followTerminalCwd;

void _onTerminalCwd(String cwd) {
  final norm = normalizeRemotePath(cwd);              // 复用 remote_paths.dart
  if (norm == _terminalCwd) return;
  _terminalCwd = norm;
  notifyListeners();                                   // UI 刷新
  if (_followTerminalCwd) _syncBrowserToTerminalCwd(); // §3
}
```

- 初值仍取 SFTP 家目录（`:635` 后同步一次 `_terminalCwd = _remoteCwd`），首条 OSC 7 到达后覆盖。

---

## 3. 工作流 C：跟随同步（P0）

### 3.1 开关与策略

- 新增设置 `followTerminalCwd`（`WorkbenchSettingsStore`，默认 **false**，避免打断手动浏览）。
- 开启后：`terminalCwd` 变化 -> 防抖 400ms（避免 `cd` 抖动）-> 若用户**当前未在 SFTP 浏览器手动操作**（用「上次手动操作时间戳」判定，手动导航后 1.5s 内不抢夺），则 `navigateToPath(terminalCwd)`。
- 终端模式：SFTP 侧栏 `sftp_side_panel.dart` / `sftp_browser.dart` 监听 `controller.terminalCwd` + 开关，自动 `navigateToPath`。
- 桌面模式：桌面文件管理器窗口（`file_manager_app.dart`）若打开且开关开，跟随；否则「在当前目录打开文件管理器」按钮（`terminal_app.dart:129`）的 `path` 改用 `controller.terminalCwd` 而非 `remoteCwd`（`:107`）。

### 3.2 同步实现

```dart
void _syncBrowserToTerminalCwd() {
  if (!_followTerminalCwd) return;
  if (_manualNavRecent) return;            // 用户刚手动操作，让让
  final target = _terminalCwd;
  if (normalizeRemotePathForCompare(target) ==
      normalizeRemotePathForCompare(_remoteCwd)) return; // 已在同一目录
  navigateToPath(target);                  // 复用 :856-858，带 cwd 历史
}
```

- `navigateToPath` 已有 `_pushCwdHistory`（`:857`），跟随导航也入历史，用户可「后退」回到原目录。
- 防抖与「手动优先」避免跟随变成干扰：用户在侧栏点进子目录时，1.5s 内终端即便 `cd` 也不抢。

### 3.3 状态栏展示（即使不开跟随也有用）

- 终端模式状态栏 `workbench_status_bar.dart`：增加「远端目录」片段，显示 `controller.terminalCwd`（截断显示末两段，hover 全路径）。
- 桌面终端 `terminal_app.dart` 底栏（已有「字号」片段，`:297`）：加「目录」片段，点击 = 「在当前目录打开文件管理器」（用 `terminalCwd`）。

---

## 4. 工作流 D：降级与远端启用（P1）

### 4.1 OSC 7 未发的探测

连上后 3s 内若未收到任何 OSC 7：
- 状态栏目录片段显示 SFTP `remoteCwd`（降级），并给一个淡提示「未检测到目录上报」。
- 不阻塞功能。

### 4.2 可选：注入 shell 片段启用 OSC 7

提供设置项「自动启用目录上报」，开启后 `connect()` 在 `shell()` 后、首次 prompt 前写一段无害的 shell 片段（仅对 bash/zsh 生效）：

```sh
# bash
__osc7_cwd() { printf '\e]7;file://%s%s\a' "$HOSTNAME" "$PWD"; }
PROMPT_COMMAND="__osc7_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
# zsh
precmd() { printf '\e]7;file://%s%s\a' "$HOSTNAME" "$PWD"; }
```

- 注入用 `session.write`（经 `Terminal.onOutput` 已有的写入路径，`:705-709`），或更干净地用一个独立 `execute()` 在 shell 启动后注入。
- **风险**：改远端 shell 环境可能影响用户自定义。故默认关，开启前弹说明；仅对检测到 bash/zsh 的远端注入（用 `detectRemoteOs` 同源探测 `$SHELL`）。
- fish 用户自有 `fish` 的 OSC 7 钩子，一般无需注入。

### 4.3 Windows 远端降级

- Windows OpenSSH 的 PowerShell 默认不发 OSC 7。
- 降级：`terminalCwd` 保持 SFTP `remoteCwd` 初值；状态栏显示之；跟随功能不可用（开关对 Windows 远端禁用并提示）。
- 未来可选：Windows Terminal 的 OSC 9;9（`cmd /c` cwd 上报）解析，作为 Windows 远端扩展--本期不做。

---

## 5. 测试

### 5.1 拦截器单测 `test/pty_interceptor_test.dart`

- OSC 7 完整一次性：`"\x1b]7;file://host/var/log\x07"` -> `onCwd('/var/log')`。
- 跨 chunk：`"\x1b]7;file://host/va"` + `"r/log\x07"` -> 同上。
- percent-encode：`"\x1b]7;file://host/My%20Dir\x07"` -> `onCwd('/My Dir')`。
- `file://localhost/path` 与 `file://host/path` 都解析为 `/path`。
- ST 终止符：`"\x1b]7;file://host/x\x1b\\"` -> `onCwd('/x')`。
- 非 OSC 7（OSC 0 标题、OSC 52 剪贴板）原样透传，不回调 cwd。
- 鼠标模式：`"\x1b[?1003h"` -> `onMouseMode(true)`；`"\x1b[?1003l"` -> `false`；跨 chunk `"\x1b[?10"` + `"03h"`。
- 透传保真：`process(s)` 输出与输入字节一致（若选保留策略）。
- 普通文本（含中文、`\x1b[31m` 颜色码）不被误吞。

### 5.2 跟随同步 widget 测试 `test/terminal_follow_cwd_test.dart`

- 伪造 controller：`terminalCwd` 从 `/` 变 `/var/log` + `followTerminalCwd=true` -> 断言 SFTP 侧栏 `remoteCwd` 变 `/var/log`。
- 手动优先：`terminalCwd` 变化前 1s 内用户手动 `goInto` -> 不跟随。
- 防抖：连续两次 `cd`（200ms 内）只导航一次（到最终目录）。
- 开关关：`terminalCwd` 变化 -> `remoteCwd` 不变。
- 同目录不重复 `navigateToPath`（避免无谓刷新 / 历史 push）。

---

## 6. 风险与回退

| 风险 | 缓解 |
|---|---|
| 拦截器状态机吃 CPU（高吞吐日志场景） | 仅扫 escape，非 escape 段直接拼接返回；状态机 O(n)。可加「连续 N 字节无 ESC 则整段透传」快路径。 |
| 跟随抢夺用户手动浏览 | 手动优先窗口 1.5s + 防抖 400ms + 默认关开关。 |
| 注入 shell 片段破坏用户环境 | 默认关；仅 bash/zsh；弹说明；提供「撤销注入」（重连不注入即可）。 |
| OSC 7 path 与 SFTP 路径体系不一致（Windows 盘符） | 用 `normalizeRemotePath`（`remote_paths.dart:36`）统一；Windows 远端走降级不解析。 |
| 重连后 `terminalCwd` 残留旧值 | `_teardownConnection(keepTerminal: true)` 时**不**清 `terminalCwd`，但重连首条 OSC 7 到达前显示可能短暂不准；可在 `connect()` 成功后重置为 `_remoteCwd` 初值。 |

---

## 7. 涉及文件清单

| 文件 | 动作 |
|---|---|
| `lib/services/pty_interceptor.dart` | 新增（OSC 7 + 鼠标模式状态机） |
| `lib/services/ssh_workspace_controller.dart` | 改：`_wireShell` 接拦截器；加 `terminalCwd`/`followTerminalCwd`/`_onTerminalCwd`/`_syncBrowserToTerminalCwd` |
| `lib/services/workbench_settings_store.dart` | 改：加 `followTerminalCwd` 设置项 |
| `lib/widgets/sftp_browser.dart` / `sftp_side_panel.dart` | 改：监听 `terminalCwd` + 开关跟随 |
| `lib/desktop/apps/terminal_app.dart` | 改：「打开文件」用 `terminalCwd`；底栏加目录片段 |
| `lib/desktop/apps/file_manager_app.dart` | 改：跟随 `terminalCwd`（开关开时） |
| `lib/widgets/workbench_status_bar.dart` | 改：显示 `terminalCwd` |
| `lib/widgets/workbench_terminal_settings_dialog.dart` | 改：加「跟随终端目录」「启用目录上报」开关 |
| `lib/l10n/app_localizations_*.dart` | 加：跟随目录 / 目录上报等字符串 |
| `test/pty_interceptor_test.dart` | 新增 |
| `test/terminal_follow_cwd_test.dart` | 新增 |

---

## 8. 与其它方案的关系

- **`pty_interceptor.dart` 与 `windows-nano-copy.md` 共用**：鼠标模式状态机是 nano Shift 旁路判定的输入。两方案应同步实现拦截器，一次扫流两用。
- 不依赖编辑器方案；不依赖高分屏方案。
