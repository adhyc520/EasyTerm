# 远程桌面下一迭代方案（Desktop Next Iteration）

> 目标：把「远程可视化桌面」从**功能齐全但偏静态**的窗口集合，提升为**实时、可操作、像真实桌面**的工作环境。本期聚焦三件事：① 让数据「活」起来（流式基础）；② 让桌面外壳「深」起来（工作区 / 命令面板 / 系统托盘 / 桌面右键 / 窗口置顶）；③ 让应用之间「连」起来（跨窗口拖拽、编辑器/浏览器多标签、文件检索与权限）。配套做可靠性与可观测性加固。
>
> 基线：`plan/remote-desktop.md`（已实现完毕，原文件已删）所规划的阶段 0–3 全部落地。本期在其之上增量演进，**不改既有 SSH 连接模型与终端模式**。

---

## 0. 现状评估（已核实事实，含行号）

### 0.1 已建成能力
- **窗口管理器**（`lib/desktop/desktop_window_manager.dart`，803 行）：`open/close/requestClose(带 onWillClose)/focus/beginDrag·dragBy·endDrag/beginResize·resizeBy·endResize/tile(8 区)/cycleFocus/minimize/toggleMaximize/restore/leaveDesktop/taskbarActivate/setDesktopSize`；贴边吸附预览（`_detectSnapHint` 734-757，顶边最大化、四角四半屏）；z 序自增；`focusGeneration` 重夺键盘焦点；拖动/缩放几何变更合并到微任务通知（`_notifyGeometryChanged` 654-663）避开 mouse_tracker 临界区。
- **10 个应用**（`lib/desktop/apps/`）：terminal / files / browser / monitor / tasks / logs / containers / diskUsage / transfers / editor。
- **外壳**（`remote_desktop_view.dart` 619 行）：渐变背景 + 网格 + 左上 10 个桌面快捷方式（`_DesktopBackground` 486-544）；掉线全屏浮层 + 重连按钮（277-344）；快捷键 `CallbackShortcuts`（134-200）：`⌘/Ctrl+W` 关窗、`⌘/Ctrl+M` 最小化、`⌘/Ctrl+N` 新终端、`⌘/Ctrl+\`` 循环焦点、`Alt+方向` 贴边/最大化/最小化。
- **任务栏**（`desktop_taskbar.dart` 308 行）：启动器 `PopupMenuButton`（10 应用）+ 横向窗口按钮列表（活跃高亮、最小化删除线）。
- **跨应用联动已部分落地**：文件管理器 → 编辑器 / 磁盘占用 / 在此打开终端（`file_manager_app.dart` 87-110）；监控 → 详情窗口（`monitor_app.dart:481`）；磁盘占用 → 详情（`disk_usage_app.dart:114`）；容器 → 日志（`containers_app.dart:310`）；任务管理器 → 浏览器打开端口（`task_manager_app.dart:453`）。
- **文件操作**（共享 `widgets/sftp_browser.dart` + `desktop_sftp_controller.dart`）：复制/剪切/粘贴（远端树，`sftp_remote_copy.dart`）、重命名、删除、新建文件/文件夹、下载、拖出（zip/gzip/tar 格式）、双击编辑、目录磁盘占用、在此开终端。

### 0.2 关键转折与缺口（本期的发力点）

| # | 事实 | 来源 | 影响 |
|---|---|---|---|
| 1 | **窗口布局持久化已被移除**，仅按 host+应用类型记忆「上次缩放宽高」；每次进入桌面是空桌面，只开一个默认终端。 | `desktop_window_manager.dart:89-92, 603-622`（`prepareFreshDesktop` 主动 `prefs.remove('desktop_layout_$hostKey')`） | 用户精心摆好的多窗口布局无法保留；本期考虑以「会话快照」形式选择性恢复。 |
| 2 | **所有数据采集都是轮询快照**，无任何流式。 | logs 4s / monitor 5s / containers 5s / tasks 2·3·8s / editor mtime 3s（`apps/*.dart` Timer.periodic） | 日志不能实时 tail，任务管理器/监控有秒级滞后；慢链路上 `run()` 并发会拥塞。 |
| 3 | **命令执行走一次性 exec**：`runRemoteForStatus` 用 `c.run()` 缓冲全量输出，无队列/无并发上限。 | `ssh_workspace_controller.dart:1485-1495` | 多窗口同时刷新 → 同一 SSH 连接上多条 exec 通道并发，慢服务器拥塞、超时、互相拖慢。 |
| 4 | **dartssh2 支持流式 exec 但未启用**：`SSHClient.execute(cmd)` 返回 `SSHSession`，其 `stdout/stderr` 是 `Stream<Uint8List>`。 | `dartssh2 ssh_client.dart:426`、`ssh_session.dart:14-24` | 流式基础可零新增传输层落地。 |
| 5 | **外壳缺少真实桌面的核心交互**：无虚拟工作区、无命令面板、无系统托盘（时钟/连接状态/显示桌面）、无桌面右键菜单、无窗口置顶、无窗口 exposé、任务栏按钮无右键菜单、无 Win11 风格 snap 布局选择器。 | `remote_desktop_view.dart`、`desktop_taskbar.dart` 全文 | 桌面「像应用不像 OS」。 |
| 6 | **应用深度不足**：编辑器无查找替换/多标签/跳行；浏览器单视图、不处理弹窗（`onCreateWindow` 未接）、无 devtools、无地址栏历史下拉；文件管理器无内容搜索/属性面板/chmod/chown/归档解压。 | `editor_app.dart`、`browser_app.dart`、`sftp_browser.dart` grep | 高频操作仍要回到 CLI。 |
| 7 | **跨窗口拖拽缺失**：文件管理器拖文件进终端只粘贴路径、进编辑器直接打开、进浏览器上传——均未实现。 | 各 app 无 `DropTarget` 接收远端条目 | 桌面窗口间割裂。 |
| 8 | **无桌面级设置**：`WorkbenchSettingsStore` 只有终端/界面/LLM 键（`workbench_settings_store.dart:8-25`），无壁纸/默认窗口尺寸/snap 开关/任务栏位置/工作区数。桌面里也进不去设置。 | 同上 | 桌面不可个性化。 |
| 9 | **错误对用户不可见**：`runRemoteForStatus` catch 后 `debugPrint` 返回 null（1492-1494）；各 app 收 null 多半静默空白。 | 同上 | 命令失败时用户不知道发生了什么。 |
| 10 | **本地化缺口**：桌面外壳/应用大量硬编码中文（"终端"/"重连"/"正在重连…"/"连接已断开"/"启动器"…），`app_localizations_*.dart` 桌面相关字符串仅 10–13 条。 | `remote_desktop_view.dart:299`、`desktop_taskbar.dart:63` 等 | 与终端模式已本地化的体验不一致。 |
| 11 | **测试只覆盖解析器**：`test/remote_desktop_unit_test.dart`（627 行）全是纯函数解析测试，无窗口管理器/流式/集成 widget 测试。 | `test/` | 几何/并发/重连逻辑回归无护栏。 |

---

## 1. 迭代目标与范围

### 1.1 主题：**让桌面「活」起来 —— 实时化 · 外壳深度 · 集成化**

| 工作流 | 目标 | 优先级 |
|---|---|---|
| **A. 实时流式基础** | 新增 `RemoteStream` 流式 exec 抽象；日志实时 tail、任务管理器/监控实时刷新；命令执行队列化防拥塞。 | P0 |
| **B. 桌面外壳深度** | 虚拟工作区、命令面板、系统托盘（时钟/状态/显示桌面）、桌面右键菜单、窗口置顶、任务栏右键、Win11 snap 布局选择器、桌面设置。 | P0（「桌面模式」重点） |
| **C. 跨应用集成与应用深度** | 窗口间拖拽、编辑器查找替换+多标签+跳行、浏览器多标签+弹窗+历史下拉、文件管理器搜索+属性+chmod/归档。 | P1 |
| **D. 可靠性与可观测性** | 命令队列与并发上限、每应用重连恢复、资源泄漏审计、错误可见化、widget/集成测试。 | P1 |
| **E. 新增应用（扩展）** | 端口转发管理器、运行命令、（可选）包管理器/防火墙/cron。 | P2 |

### 1.2 本期不做（非目标）
- 不做 VNC/RDP/X11 投屏（维持原则）。
- 不替换终端模式或 SSH 连接模型；所有改动对终端模式零回归。
- 不引入新传输层；流式/队列复用 dartssh2 既有 `execute()`/`run()`。
- 不把全部 10 个应用一次性改成流式；先改日志/任务/监控三个高频刷新应用，其余按需。

---

## 2. 工作流 A：实时流式基础（P0）

### 2.1 `RemoteStream` —— 流式 exec 抽象

**文件**：`lib/services/remote_stream.dart`（新增）

```dart
/// 一条流式 exec 通道：跑一条命令，按行吐出 stdout，可停止、可观察退出码。
/// 用于实时 tail / top / watch 等需要持续输出的场景，替代轮询快照。
class RemoteStream extends ChangeNotifier {
  RemoteStream._(this._session, this._cmd);
  final SSHSession _session;
  final String _cmd;
  StreamSubscription<Uint8List>? _outSub;
  StreamSubscription<Uint8List>? _errSub;
  final List<String> _lines = [];          // 环形缓冲（容量可配）
  final int maxLines;
  bool _closed = false;
  int? _exitCode;
  String? _error;                          // 启动/运行期错误，供 UI 显示

  static Future<RemoteStream> start(
    SSHClient? client, {
    required String command,
    int maxLines = 5000,
  }) async {
    if (client == null) throw StateError('SSH 未连接');
    final session = await client.execute(command);   // dartssh2 ssh_client.dart:426
    final s = RemoteStream._(session, command);
    s._wire();
    return s;
  }

  void _wire() {
    _outSub = _session.stdout.listen(
      (data) => _append(utf8.decode(data, allowMalformed: true)),
      onError: (e) => _fail(e),
      onDone: () => _done(),
    );
    _errSub = _session.stderr.listen(
      (data) => _append(utf8.decode(data, allowMalformed: true)),
    );
  }

  void _append(String chunk) {
    // 按 \n 切分，维护 _lineBuffer 处理半行；超 maxLines 丢弃头部
    ...
    notifyListeners();
  }

  List<String> get lines => List.unmodifiable(_lines);
  bool get closed => _closed;
  int? get exitCode => _exitCode;
  String? get error => _error;

  Future<void> stop() async {
    _closed = true;
    await _outSub?.cancel();
    await _errSub?.cancel();
    try { _session.close(); } catch (_) {}
    notifyListeners();
  }
}
```

**要点**：
- 半行缓冲：跨 chunk 的不完整行用 `_pendingLine` 拼接，`tail -f` 这类无结尾换行的输出也能正确显示。
- 环形缓冲：`_lines` 超 `maxLines` 丢弃头部，防止长时间 `tail -f` 内存膨胀。
- 错误可见：`_error` 暴露给 UI（接 §4.4）。
- 生命周期：窗口关闭 / 掉线 / 退桌面 必调 `stop()`（接 §D 资源回收）。

### 2.2 `RemoteCommandQueue` —— 命令执行队列（P0，防拥塞）

**文件**：`lib/services/remote_command_queue.dart`（新增）

现状：每个 app 各自 `Timer.periodic` → `runRemoteForStatus` → `c.run()`，多窗口并发时同一 SSH 连接上同时挂着多条 exec 通道，慢服务器拥塞/超时。

```dart
/// 串行化（或低并发）执行一次性命令，避免多窗口轮询在同一 SSH 连接上并发 exec 拥塞。
class RemoteCommandQueue {
  RemoteCommandQueue(this._clientGetter, {this.maxConcurrent = 2});
  final SSHClient? Function() _clientGetter;
  final int maxConcurrent;                 // 允许的并发 exec 上限
  int _inFlight = 0;
  final _pending = <_QueuedCmd>[];

  Future<String?> run(String command, {Duration timeout = const Duration(seconds: 15)}) {
    final c = Completer<String?>();
    _enqueue(_QueuedCmd(command, timeout, c));
    return c.future;
  }

  void _enqueue(_QueuedCmd cmd) { _pending.add(cmd); _pump(); }

  void _pump() {
    while (_inFlight < maxConcurrent && _pending.isNotEmpty) {
      final cmd = _pending.removeAt(0);
      _inFlight++;
      _exec(cmd);
    }
  }

  Future<void> _exec(_QueuedCmd cmd) async {
    final client = _clientGetter();
    if (client == null) { cmd.completer.complete(null); _inFlight--; _pump(); return; }
    try {
      final out = await client.run(cmd.command, stderr: false).timeout(cmd.timeout);
      cmd.completer.complete(utf8.decode(out, allowMalformed: true).trim());
    } catch (e) {
      debugPrint('cmdq run: $e');
      cmd.completer.complete(null);          // null = 失败，UI 据 §4.4 显示
    } finally {
      _inFlight--; _pump();
    }
  }
}
```

**集成**：
- `SshWorkspaceController` 持有一个 `RemoteCommandQueue`（懒创建），新增 `Future<String?> runQueued(String cmd)` 转发；**保留 `runRemoteForStatus` 旧签名**（内部改调 `runQueued`，零回归）。
- `maxConcurrent=2`：允许监控+任务管理器并行刷新，但堵住第 3 个排队，避免雪崩。可配置。
- 掉线时 `_clientGetter()` 返回 null，队列里所有命令立即返回 null（UI 显示「连接已断开」而非无限转圈）。

### 2.3 日志应用：实时 tail（P0）

**文件**：`lib/desktop/apps/logs_app.dart`（改）、`lib/services/remote_logs.dart`（改）

现状：`fetchRemoteLogs` 每 4s 跑一次 `tail -n N` / `journalctl -n N`，是「快照重拉」。

改造：
- 新增 `RemoteLogStream`：用 `RemoteStream.start(client, command: 'journalctl -f -n $n ...' / 'tail -F $file' / 'docker logs -f ...')`，`-f`/`-F` 持续输出。
- `LogsApp` 增加模式开关：**实时跟随**（流式，默认）/ **快照**（原轮询，适合不支持 -f 的场景或低性能服务器）。
- 流式模式下 `_lines` 直接来自 `RemoteStream.lines`，`ListView` 用 `ScrollController` 自动滚到底（用户上滚时暂停自动跟随，点「回到底部」恢复——复用 xterm 终端的同类交互逻辑）。
- 暂停/恢复：窗口最小化时 `stop()`，恢复时重开（接 §D）。
- 兼容 Windows：Windows 事件日志无 tail -f，保留快照模式；`Get-WinEvent -MaxEvents ...` 轮询。

**命令对照**（`remote_logs.dart` 已有命令的基础上加 `-f` 变体）：
| 来源 | 快照（现有） | 实时（新增） |
|---|---|---|
| journalctl | `journalctl -n $n --no-pager -o short-iso` | `journalctl -f -n $n --no-pager -o short-iso` |
| 文件 | `tail -n $n $file` | `tail -F -n $n $file` |
| docker | `docker logs --tail $n $ref` | `docker logs -f --tail $n $ref` |
| dmesg | `dmesg -T \| tail -n $n` | （无 -f，保留快照） |

### 2.4 任务管理器：实时进程（P1）

**文件**：`lib/desktop/apps/task_manager_app.dart`（改）、`remote_process_list.dart`（改）

现状：「进程」页 3s 轮询 `ps`。可改为流式 `top -b -d 2`（Linux）解析，或保持 `ps` 但用队列降并发。**建议**：进程页保留轮询（`ps` 输出结构稳定，3s 够用），但改走 `runQueued`；性能页/网络页同样改走队列。流式优先给日志（收益最大、最适合 tail）。任务管理器本期只接队列，不改流式，避免 `top -b` 解析的复杂度风险。

### 2.5 验收（工作流 A）
- [x] `RemoteStream` 单测：喂跨 chunk 半行 + 超 maxLines 截断 + stop() 后不再 notify。
- [x] `RemoteCommandQueue` 单测：maxConcurrent=2 时第 3 个排队、掉线时返回 null、超时返回 null。
- [ ] 日志实时跟随：开 journalctl -f，远端 `logger hello` → 1s 内桌面出现；上滚暂停跟随、回到底部恢复。（需真机 SSH）
- [ ] 多窗口同时刷新监控+任务+日志：慢服务器（人为限速）下不超 2 条并发 exec，UI 不卡死。（需真机 SSH）

---

## 3. 工作流 B：桌面外壳深度（P0，本期重点）

### 3.1 虚拟工作区（Workspaces）

**目标**：多套独立窗口布局，像 macOS Spaces / Win 虚拟桌面。任务栏显示工作区指示器，快捷键切换。

**数据模型**（`desktop_window_manager.dart` 改）：
```dart
class DesktopWorkspace {
  final String id;
  final List<DesktopWindow> windows = [];
  String name;
  DesktopWorkspace(this.id, this.name);
}

class DesktopWindowManager extends ChangeNotifier {
  final List<DesktopWorkspace> _workspaces = [];
  int _activeWs = 0;
  static const int kDefaultWorkspaceCount = 2;

  List<DesktopWorkspace> get workspaces => List.unmodifiable(_workspaces);
  DesktopWorkspace get activeWorkspace => _workspaces[_activeWs];
  int get activeWorkspaceIndex => _activeWs;

  void switchWorkspace(int i);          // 切换：隐藏旧 ws 全部窗口，显示新 ws
  void moveWindowToWorkspace(String winId, int wsIndex);  // 右键菜单 / 快捷键
  void addWorkspace();
  void removeWorkspace(int i);          // 至少留 1 个；窗口移到相邻
  List<DesktopWindow> get windows => activeWorkspace.windows;  // 兼容现有 API
}
```

**关键决策**：
- `windows` getter 改为返回**当前工作区**的窗口，现有所有 `wm.windows` 调用零改动即可只看当前工作区。
- 切换工作区 = `notifyListeners()`，视图层 `remote_desktop_view.dart:230` 的 `wm.windows.where(...)` 自动只渲染当前工作区。
- 工作区数持久化（接 §3.7 桌面设置）；窗口所属工作区**不持久化**（与 §0.2#1 一致：本期不恢复完整布局，工作区只是运行期组织）。

**UI**：
- 任务栏右侧工作区指示器（1/2/3 圆点，点击切换，右键新增/删除）。
- 快捷键：`Ctrl+1..9` 切到第 N 工作区，`Ctrl+→/←` 相邻切换，`Shift+Ctrl+→/←` 把当前窗口移到相邻工作区（接 `remote_desktop_view.dart` CallbackShortcuts 134-200）。

### 3.2 命令面板（Command Palette）

**目标**：`⌘/Ctrl+Shift+P`（动作）与 `⌘/Ctrl+P`（快速开应用/文件）唤起居中搜索框，模糊搜索执行动作。让桌面所有能力一键可达，替代翻启动器菜单。

**文件**：`lib/desktop/desktop_command_palette.dart`（新增）

```dart
class DesktopCommandPalette extends StatefulWidget {
  const DesktopCommandPalette({super.key, required this.wm, required this.controller});
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;
}

abstract class CommandItem {
  String get title;
  String? get subtitle;
  IconData? get icon;
  String get category;       // "应用" / "窗口" / "工作区" / "设置" / "文件"
  void invoke(BuildContext ctx);
}
```

**命令来源**（动态聚合）：
- **应用**：开 10 类应用（复用 `DesktopAppType` 枚举）。
- **窗口**：聚焦/关闭/最小化每个现有窗口；置顶（§3.5）；移到工作区 N。
- **工作区**：切换/新增/删除。
- **设置**：打开桌面设置（§3.7）、终端模式设置、重连。
- **文件**（接 §3.3 桌面右键 / §C 文件搜索）：最近打开的文件。

**集成**：
- `remote_desktop_view.dart` 顶层 `CallbackShortcuts` 加 `⌘/Ctrl+Shift+P` → 用 `Overlay` 注入 `DesktopCommandPalette`（不Navigator.push，避免脱离桌面上下文）。
- 模糊匹配：简单子串 + 标题首字母缩写（如 "tm" 匹配「任务管理器」）；无需引入新依赖。
- `Esc` 关闭；`↑↓` 选择；`Enter` 执行。

### 3.3 桌面右键菜单 + 桌面设置入口

**目标**：右键桌面空白处弹菜单（真实桌面习惯），提供：在此开终端 / 在此开文件管理器 / 粘贴 / 更换壁纸 / 桌面设置 / 新建工作区。

**文件**：`remote_desktop_view.dart` 改（`_DesktopBackground` 486-544 加 `GestureDetector.onSecondaryTapUp`）

```dart
GestureDetector(
  onSecondaryTapUp: (d) => _showDesktopContextMenu(context, d.globalPosition),
  child: DecoratedBox(...),
)
```

菜单项调 `wm.openTerminal()` / `wm.open(files)` / 壁纸选择（§3.7）/ 桌面设置（§3.7）。

### 3.4 系统托盘（任务栏右侧状态区）

**目标**：任务栏右侧加：连接状态点（绿/黄/红）、远端时钟、一键 CPU/内存小数字、显示桌面按钮。

**文件**：`desktop_taskbar.dart` 改（`Row` 末尾加 `TrayArea`）

```dart
Row(children: [
  _LauncherButton(wm: wm),
  const SizedBox(width: 8),
  Expanded(child: /* 窗口按钮列表 */),
  const SizedBox(width: 8),
  _TrayArea(wm: wm, controller: controller),   // 新增
])
```

`_TrayArea`：
- **连接状态**：`ListenableBuilder(controller)` → 绿点（connected）/ 黄（connecting）/ 红（dropped）；点击 = 重连。
- **远端时钟**：复用 `RemoteHostSnapshot` 的 uptime/时间，或单独 `runQueued('date +%s')` 低频（30s）刷新；显示远端时间（解决跨时区）。
- **CPU/内存微指标**：复用 `RemoteHostSnapshot`，5s 刷新一次（与监控窗口共享采样，见 §D.3 避免重复采样）。
- **显示桌面**：点一下最小化全部 → 再点恢复（记忆被最小化的窗口 id 列表）。

### 3.5 窗口置顶（Always-on-top）

**文件**：`desktop_window_manager.dart` 改

```dart
class DesktopWindow {
  bool alwaysOnTop = false;   // 新增
}

// DesktopWindowManager：
void toggleAlwaysOnTop(String id) {
  final w = _find(id);
  if (w == null) return;
  w.alwaysOnTop = !w.alwaysOnTop;
  if (w.alwaysOnTop) w.z = ++_zSeq;   // 置顶时抬到最前
  notifyListeners();
}
```

**渲染**（`remote_desktop_view.dart:230-233` 排序）：z 序排序时 `alwaysOnTop` 的窗口始终排在非置顶之上：
```dart
visible.sort((a, b) {
  final at = a.alwaysOnTop ? 1 : 0;
  final bt = b.alwaysOnTop ? 1 : 0;
  if (at != bt) return at - bt;
  return a.z.compareTo(b.z);
});
```

**入口**：标题栏右键菜单（§3.6）+ 命令面板 + 快捷键 `Ctrl+T`（toggle top）。

### 3.6 标题栏右键菜单 + 任务栏按钮右键菜单

**文件**：`desktop_window_frame.dart`（标题栏 `onSecondaryTapUp`）、`desktop_taskbar.dart`（`_TaskbarWindowButton` 加 `onSecondaryTapUp`）

菜单项：**置顶 / 最大化 / 最小化 / 还原 / 贴边左/右/上/下四角 / 移到工作区 N / 关闭**。复用 `wm.tile/toggleMaximize/minimize/restore/toggleAlwaysOnTop/moveWindowToWorkspace/requestClose`。

### 3.7 Win11 风格 Snap 布局选择器

现状：拖到边缘吸附（`_detectSnapHint`）已支持 8 区 + 顶边最大化。增强：**悬停窗口最大化按钮**弹布局网格（2×2 / 1×2 / 2×1），点选直接 `wm.tile(zone)`。

**文件**：`desktop_window_frame.dart` 改（最大化按钮 `onHover`/`onTap` 长按 → `PopupMenu` 或自定义 `Overlay` 网格）

### 3.8 桌面设置（Desktop Settings）

**文件**：`lib/services/desktop_settings_store.dart`（新增，沿用 `WorkbenchSettingsStore` 的 SharedPreferences 模式）、`lib/widgets/desktop_settings_dialog.dart`（新增）

**设置项**（键 `desktop_*`）：
| 键 | 默认 | 说明 |
|---|---|---|
| `desktop_workspace_count` | 2 | 初始工作区数 |
| `desktop_snap_enabled` | true | 拖动贴边吸附开关 |
| `desktop_snap_edge_px` | 28 | 吸附边缘阈值（现 `_snapEdgePx` 130） |
| `desktop_show_grid` | true | 桌面网格背景 |
| `desktop_wallpaper` | '' | 自定义壁纸路径（本地图片，base64 或文件 URI） |
| `desktop_taskbar_autohide` | false | 任务栏自动隐藏 |
| `desktop_default_window_w_frac` | 0.52 | 新窗口默认宽（现 `_defaultWFrac` 109） |
| `desktop_default_window_h_frac` | 0.58 | 新窗口默认高 |
| `desktop_tray_show_clock` | true | 托盘显示远端时钟 |
| `desktop_tray_show_metrics` | true | 托盘显示 CPU/内存微指标 |
| `desktop_live_logs_default` | true | 日志默认实时跟随 |

**集成**：`DesktopWindowManager` 构造注入 `DesktopSettingsStore`，`_detectSnapHint`/`_staggeredDefaultRect`/背景绘制读设置；桌面右键 / 命令面板 / 托盘均可打开设置对话框。

### 3.9 验收（工作流 B）
- [x] 工作区：开 2 工作区各放窗口，`Ctrl+1/2` 切换互不干扰；`Shift+Ctrl+→` 移窗到下一工作区。（已实现 + WM 单测）
- [x] 命令面板：`⌘/Ctrl+Shift+P` 唤起，输 "tm" → 任务管理器；`Esc` 关闭。
- [x] 桌面右键：弹菜单，「在此开终端」在桌面开终端窗口。
- [x] 系统托盘：状态点随连接变化；远端时钟显示；「显示桌面」最小化全部再恢复。
- [x] 置顶：置顶窗口拖动其他窗口时不被遮挡。
- [x] 标题栏/任务栏右键菜单各项可用。
- [x] snap 布局选择器：悬停最大化按钮弹网格，选 1×2 → 窗口贴左半。
- [x] 桌面设置：改壁纸/关网格/关 snap，立即生效并持久化。
- [ ] 终端模式零回归（切换回终端，AI/侧栏/状态栏原样）。（需手工冒烟）

---

## 4. 工作流 C：跨应用集成与应用深度（P1）

### 4.1 跨窗口拖拽

**目标**：文件管理器拖一个远端文件 → 拖到终端窗口粘贴其路径；拖到编辑器窗口打开该文件；拖到浏览器窗口上传（若该站支持）。

**基础**：仓库已 `super_drag_and_drop` + `desktop_drop` + `super_clipboard`（见 `pubspec.yaml`）。文件管理器已有拖出（`sftp_transfer_helpers.dart` 的 `startBackgroundDirectoryDragOut` / `materializeRemoteFileToTempForDrag`）。

**改造**：
- **终端窗口接收**（`terminal_app.dart`）：包 `DropTarget`，落点检测 `super_clipboard` 的 `DataReader` 是否含文件 URI 或文本；若是内部远端拖出（`isPathFromRecentDragOut`）→ `shell.paste(remotePath)`；若是本地文件 → 粘贴本地路径字符串。
- **编辑器窗口接收**（`editor_app.dart`）：落点 → 读拖出路径 → `wm.open(editor, args:{'path': ...})`（新开编辑器）或当前窗口加载（若未修改）。
- **拖到任务栏窗口按钮**：悬停 0.3s 聚焦该窗口，再落入其内容区（仿 OS 任务栏拖拽聚焦）。

**注意**：远端文件拖到另一窗口时，路径要用远端绝对路径（`remoteJoin(host.remoteCwd, name)`），不能物化到本地临时文件再传——除非目标是本地上传。

### 4.2 编辑器深度：查找替换 / 多标签 / 跳行

**文件**：`lib/desktop/apps/editor_app.dart`（改）、`lib/screens/remote_editor_screen.dart`（共享逻辑）

- **查找替换**：`CallbackShortcuts` 加 `⌘/Ctrl+F`（查找栏）、`⌘/Ctrl+G` 下一个、`⌘/Ctrl+Shift+G` 上一个、`⌘/Ctrl+H` 替换。基于 `TextEditingController` + `TextField` 的现有编辑实现做高亮匹配（或引入 `flutter_highlight` 已有依赖的轻量方案）。
- **多标签**：编辑器窗口内 `TabBar` + `TabController`，每个 tab 一个文件路径 + 独立 controller + 独立 mtime 轮询。`args['path']` 改为初始 tab；`onOpenInEditor` 若已有同路径 tab 则聚焦而非新开。
- **跳行**：`⌘/Ctrl+L` 弹行号输入 → `ScrollController` 跳转。
- **未保存标记**：标题栏标题前加 `●`（已有 `_save` 256 行，补 dirty 状态追踪）；`onWillClose` 已有钩子，补「未保存 → 确认」对话框。

### 4.3 浏览器深度：多标签 / 弹窗 / 历史下拉

**文件**：`lib/desktop/apps/browser_app.dart`（改，939 行）

- **多标签**：`TabBar` + 每个 tab 一个 `InAppWebViewController` + 独立地址栏。注意 webview 内存：标签数上限（如 8），超出时 LRU 释放 `InAppWebViewController`。
- **弹窗/新窗口**：接 `InAppWebView` 的 `onCreateWindow` → `createWindowAction` → 在新 tab 打开（`webview.loadRequest(...)`），而非弹系统浏览器。配 `settings.javaScriptCanOpenWindowsAutomatically = true`。
- **地址栏历史下拉**：`browser_history_store.dart` 已存在，地址栏 `TextField` 聚焦时下拉最近 N 条匹配。
- **devtools**（P2/可选）：`InAppWebViewController` 调 `WebChromeClient` / `setWebContentsDebugging` 受限，桌面端可暴露「复制当前 URL 到外部浏览器」按钮作为兜底（已有 `externalBrowserNavigationUri`，测试见 `remote_desktop_unit_test.dart:81`）。

### 4.4 文件管理器深度：搜索 / 属性 / chmod / 归档

**文件**：`widgets/sftp_browser.dart`（改）、`services/desktop_sftp_controller.dart`（改）

- **内容搜索**（P1）：右上搜索框 → `runQueued("grep -rln -- '$pattern' .")` 或 `find . -name '*pattern*'`；结果列表点击跳转。用队列（§2.2）避免阻塞目录浏览。
- **属性面板**（P1）：右键「属性」→ 弹窗显示 `stat`（size/owner/group/perm/mtime）；`runQueued("stat -c '%s %U %G %A %Y' '$path'")`。
- **chmod/chown UI**（P2）：属性面板加权限勾选矩阵（rwx × owner/group/other）→ `runQueued("chmod XXX '$path'")`；chown 输入框 → `chown owner:group`。需远端权限，失败接 §D.4 错误提示。
- **归档**（P2）：右键「压缩」→ `tar czf /tmp/x.tgz ...` / `zip`；「解压」→ `tar xf` / `unzip`。进度走传输队列提示。

### 4.5 验收（工作流 C）
- [x] 拖远端文件到终端：粘贴远端绝对路径；拖到编辑器：打开该文件。
- [x] 编辑器 `⌘/Ctrl+F` 查找高亮、`⌘/Ctrl+H` 替换；多 tab 切换；`⌘/Ctrl+L` 跳行；未保存关窗有确认。
- [x] 浏览器多 tab 独立；点站内 `target=_blank` 链接在新 tab 打开；地址栏聚焦下拉历史。
- [x] 文件管理器搜索 / 属性 / chmod；压缩解压。

---

## 5. 工作流 D：可靠性与可观测性（P1）

### 5.1 资源泄漏审计

**目标**：确保「关窗 / 关标签 / 退桌面 / 掉线」四处统一回收所有资源。

现状（`ssh_workspace_controller.dart:1501` `_teardownConnection`）：取消 stdout/stderr 订阅、关 shell/sftp/client。需确认/补齐：
- `RemoteStream`（§2.1）：每个流式窗口在 `_teardownConnection` 时 `stop()`。机制：controller 维护 `final Set<RemoteStream> _activeStreams`，`openShell`/流式 app 注册，teardown 时全部 stop。
- `RemoteShell`（桌面多终端，`remote_shell.dart`）：确认 `leaveDesktop`（wm 558-564）清窗时各 `TerminalApp` 的 `dispose` 调了 `shell.close()`。
- `LocalPortForwarder` / `BrowserGateway`：确认监听 `client.done` 自动停（`local_port_forwarder.dart` 已有，需复查 gateway）。
- 审计方式：在 debug 模式给每类资源加「open/close 计数」`debugPrint`，开/关桌面/掉线后核对归零。

### 5.2 每应用重连恢复

现状（`remote_desktop_view.dart:88-99`）：只在连接态变化时重建桌面外壳。各 app 内部对重连的处理不一：
- **流式日志**：掉线 `RemoteStream` 自动结束（`session` 随 client 关闭）；重连后需用户重新点「跟随」或自动重开（建议：记忆「跟随中」状态，重连后自动 `start()`）。
- **轮询 app**（监控/任务/容器）：重连后下一 tick 自然恢复，但需清空「上次错误」状态。
- **文件管理器**：`desktop_sftp_controller._onWorkspace`（51 行）监听 controller，重连后应自动 `refreshDirectory`——需确认 `sftp` getter 重建后通知到位。
- **编辑器**：重连后 mtime 轮询恢复，但打开的文件缓冲仍在；若远端文件已变，提示「文件已变更，是否重新加载」。

**统一**：给 app 一个 `onConnectionRestored()` 钩子（通过 `wm` 或 controller listener 分发），各 app 实现自己的恢复策略。

### 5.3 共享采样去重

现状：监控窗口、任务管理器性能页、托盘微指标（§3.4）可能各自跑 `RemoteHostSnapshot.fetchRemoteHostSnapshot`，同一周期重复采样。

改造：`SshWorkspaceController` 持有 `RemoteHostSnapshot? _lastSnapshot` + `DateTime? _lastSnapshotAt`，新增 `Future<RemoteHostSnapshot?> snapshot({Duration maxAge = const Duration(seconds: 3)})`：若 `_lastSnapshotAt` 在 maxAge 内直接返回缓存，否则跑一次并广播。各 app 监听广播而非各自拉。降低 exec 频次。

### 5.4 错误可见化

现状：`runRemoteForStatus` 失败 `debugPrint` + 返回 null，UI 静默。

改造：
- `RemoteCommandQueue.run` 返回 `({String? output, String? error})` 而非裸 `String?`（或保留 null 但 controller 记录最近错误）。
- 各 app 在数据为 null 时显示「刷新失败：$error」而非空白；提供「重试」按钮。
- 托盘状态点（§3.4）在最近命令失败时短暂变橙并 tooltip 显示错误。

### 5.5 测试加固

- **widget 测试**：`DesktopWindowManager` 几何/焦点/贴边/工作区切换的纯逻辑测试（不需要真 SSH，用假 controller）。
- **集成测试**：`RemoteStream` 半行/截断/stop；`RemoteCommandQueue` 并发/超时/掉线。
- **回归**：终端模式选择/拖选/拖出/上传/编辑/断线重连逐项回归（沿用原 plan 阶段 0 验收）。

---

## 6. 工作流 E：新增应用（P2 扩展）

> 桌面已有 10 应用，本期优先「深耕」而非「铺摊」。以下按价值排序，视工期取做。

### 6.1 端口转发管理器（推荐，复用既有基建）

**目标**：可视化管理局部端口转发（§`local_port_forwarder.dart` 方案 A）与网关（§`browser_gateway.dart` 方案 B），列出活动转发、增删、持久化。

**文件**：`lib/desktop/apps/forwards_app.dart`（新增）、`DesktopAppType.forwards`（枚举新增）

- 列表：`[类型] 本地端口 → 远端 host:port` + 状态 + 流量（可选）。
- 新增：填远端 host:port → `controller.openLocalForward` → 加入列表。
- 持久化：按 host 存转发清单，重连后自动重建。
- 入口：启动器 + 命令面板 + 桌面快捷方式。

### 6.2 运行命令（Run Command）

**目标**：`⌘/Ctrl+R` 或命令面板「运行命令」→ 输入一条 shell 命令 → 在小窗口里流式显示输出（用 `RemoteStream`），不占终端。适合一次性 `du -sh` / `df -h` / `who`。

**文件**：`lib/desktop/apps/run_command_app.dart`（新增）、`DesktopAppType.runCommand`

### 6.3 可选（后续迭代）
- [x] **包管理器**：apt/dnf/yum/pacman/brew/zypper 检测、已安装列表、搜索、安装/卸载（`sudo -n`，失败提示终端命令）。
- [x] **防火墙**：ufw / firewalld / iptables 状态；UFW 启停、放行/拒绝、删规则（同样 `sudo -n` + 终端兜底）。
- [x] **计划任务**：crontab 列表/编辑（`cron_app.dart` + `remote_cron.dart`）。
- [x] **用户与组**：`who`/`last`/`passwd`（`users_app.dart` + `remote_users.dart`）。
- [x] **归档**（§4.4 P2）：文件管理器右键压缩 `.tar.gz` / 解压 tar·zip·gz。

---

## 7. 目录结构与集成点

### 7.1 新增/改动文件清单

```
lib/services/
  remote_stream.dart              # 新增 · 流式 exec（§2.1）
  remote_command_queue.dart       # 新增 · 命令队列（§2.2）
  desktop_settings_store.dart     # 新增 · 桌面设置（§3.8）
  ssh_workspace_controller.dart   # 改 · 注入队列 + runQueued + snapshot 缓存 + _activeStreams（§2.2/5.3/5.1）
  remote_logs.dart                # 改 · 加 -f 实时变体（§2.3）
  desktop_window_manager.dart     # 改 · 工作区 + 置顶 + 设置注入（§3.1/3.5/3.8）
lib/desktop/
  desktop_command_palette.dart    # 新增 · 命令面板（§3.2）
  remote_desktop_view.dart        # 改 · 桌面右键 + 命令面板快捷键 + 工作区渲染 + 置顶排序（§3.2/3.3/3.5）
  desktop_taskbar.dart            # 改 · 系统托盘 + 工作区指示器 + 按钮右键（§3.4/3.1/3.6）
  desktop_window_frame.dart       # 改 · 标题栏右键 + snap 布局选择器（§3.6/3.7）
  apps/
    logs_app.dart                 # 改 · 实时跟随模式（§2.3）
    task_manager_app.dart         # 改 · 走队列（§2.4）
    monitor_app.dart              # 改 · 走共享 snapshot（§5.3）
    editor_app.dart               # 改 · 查找替换/多标签/跳行/拖入（§4.2/4.1）
    browser_app.dart              # 改 · 多标签/弹窗/历史下拉（§4.3）
    terminal_app.dart             # 改 · 接收拖入粘贴路径（§4.1）
    forwards_app.dart             # 新增 · 端口转发管理器（§6.1，P2）
    run_command_app.dart          # 新增 · 运行命令（§6.2，P2）
lib/widgets/
  desktop_settings_dialog.dart    # 新增 · 桌面设置对话框（§3.8）
  sftp_browser.dart               # 改 · 搜索/属性/chmod/归档（§4.4）
test/
  remote_stream_test.dart         # 新增（§2.5）
  remote_command_queue_test.dart  # 新增（§2.5）
  desktop_window_manager_test.dart# 新增（§5.5）
```

### 7.2 关键集成点（行号锚定）
- **命令队列接入**：`ssh_workspace_controller.dart:1485` `runRemoteForStatus` 内部改调 `runQueued`；新增 `runQueued`/`snapshot` getter。
- **工作区兼容**：`desktop_window_manager.dart:132` `windows` getter 改返回 `activeWorkspace.windows`，所有下游零改动。
- **置顶排序**：`remote_desktop_view.dart:230-233` 排序逻辑加 `alwaysOnTop` 分层。
- **托盘**：`desktop_taskbar.dart:26-47` `Row` 末尾加 `_TrayArea`。
- **桌面右键**：`remote_desktop_view.dart:507` `_DesktopBackground` 的 `DecoratedBox` 外包 `GestureDetector`。
- **命令面板快捷键**：`remote_desktop_view.dart:134` `CallbackShortcuts` bindings 加 `⌘/Ctrl+Shift+P`。
- **设置注入**：`desktop_window_manager.dart:94-98` 构造加 `DesktopSettingsStore`；`_detectSnapHint`（734）/`_staggeredDefaultRect`（678）/背景绘制读设置。

---

## 8. 实施阶段

### 阶段 1 · 流式基础 + 队列（P0，1–2 周）
- [x] `RemoteStream` + 单测（§2.1/2.5）。
- [x] `RemoteCommandQueue` + 单测（§2.2/2.5）；`runRemoteForStatus` 切队列，终端模式回归。
- [x] 日志实时 tail（§2.3）；任务/监控走队列（§2.4/5.3）。
- [x] **验收**：§2.5 全过；现有 10 应用行为不变。

### 阶段 2 · 桌面外壳深度（P0，2–3 周，重点）
- [x] 桌面设置 store + 对话框（§3.8）。
- [x] 工作区（§3.1）+ 置顶（§3.5）+ 标题栏/任务栏右键（§3.6）。
- [x] 系统托盘（§3.4）+ 桌面右键（§3.3）+ snap 布局选择器（§3.7）。
- [x] 命令面板（§3.2）。
- [x] **验收**：§3.9 全过；终端模式零回归。

### 阶段 3 · 集成与应用深度（P1，2 周）
- [x] 跨窗口拖拽（§4.1）。
- [x] 编辑器查找替换/多标签/跳行（§4.2）。
- [x] 浏览器多标签/弹窗/历史（§4.3）。
- [x] 文件管理器搜索/属性/chmod（§4.4）。
- [x] **验收**：§4.5 全过。

### 阶段 4 · 可靠性 + 新增应用（P1/P2，1–2 周）
- [x] 资源泄漏审计（§5.1）+ 重连恢复（§5.2）+ 错误可见化（§5.4）。
- [x] 测试加固（§5.5）。
- [x] 端口转发管理器 + 运行命令（§6.1/6.2，视工期）。
- [x] **验收**：§5 全过；debug 模式资源计数归零。

---

## 9. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| `RemoteStream` 长时间运行（`tail -f`）内存膨胀 / 掉线后僵尸 | 中 | 环形缓冲 maxLines；`client.done` 自动 stop；窗口最小化/关闭必 stop；debug 计数审计。 |
| 命令队列把刷新拖慢（maxConcurrent=2 排队） | 中 | 队列只管一次性 `run`；流式走独立 exec 通道不进队列；maxConcurrent 可配置；监控/任务共享 snapshot 去重（§5.3）降总频次。 |
| 工作区改造 `windows` getter 语义变化引发回归 | 高 | getter 返回当前工作区窗口，下游全部「只看当前」语义不变；补 wm 单测；终端模式不受影响（不用 wm）。 |
| 命令面板 `Overlay` 与终端硬件键盘焦点冲突 | 中 | 面板用独立 `FocusNode`，关闭时把焦点还回原窗口（复用 `focusGeneration` 机制，wm 269-295）。 |
| 浏览器多标签 webview 内存 | 中 | 标签上限 8，LRU 释放 controller；macOS WKWebView / Windows WebView2 单例复用。 |
| 跨窗口拖拽跨平台行为差异（super_drag_and_drop 桌面成熟度） | 中 | 先做「内部远端拖出 → 粘贴路径」最稳；本地文件拖入兜底为路径文本；逐平台冒烟。 |
| chmod/chown/包管理器需远端 sudo，失败处理 | 中 | 失败接 §5.4 错误提示；不静默；sudo 场景提示用户在终端手动执行。 |
| 桌面设置/工作区持久化与「不恢复布局」原则冲突 | 低 | 本期只持久化设置项与工作区数，不持久化窗口清单/位置（维持 §0.2#1 现状），避免跨分辨率失配老问题。 |
| 本地化工作量（桌面大量硬编码 zh） | 低 | 新增字符串走 `app_localizations`（en+zh）；旧硬编码字符串在改动到的文件顺手补齐；不单独做大扫除。 |
| 流式 exec 与一次性 `run` 并发总量仍可能压满 SSH 窗口 | 中 | 队列限并发；流式通道数上限（如同时最多 3 条 `RemoteStream`）；监控共享采样。 |

---

## 10. 与原方案（`remote-desktop.md`）的衔接

- 原方案阶段 0–3 全部落地，**本期不改其连接模型、终端渲染抽取、SFTP 抽取**等既有架构。
- 原方案 §6.4「窗口布局按 host 持久化」**已在实现期被主动移除**（改为按类型记尺寸）。本期不推翻该决定，但提供「工作区」作为运行期布局组织，与「会话快照恢复」解耦——若后续用户强烈需要恢复布局，再以工作区为单元做选择性快照（P3+）。
- 原方案 §7.3「可选重构 RemoteSession」仍未做；本期不强制，仅在 `RemoteCommandQueue`/`RemoteStream`/`snapshot` 缓存等新能力挂在 `SshWorkspaceController` 上时保持低侵入，为未来抽 `RemoteSession` 留接缝。
