# 远程可视化桌面方案（Remote Visual Desktop）

> 目标：SSH 连接到服务器后，可在当前终端工作区内**切换到一个由本程序渲染的可视化桌面**。桌面里可以开终端、文件管理器、浏览器，浏览器能访问**服务器内部**（remote localhost / 内网）的网站，实现纯图形化操作。
>
> 本方案基于 terminall（package: `easyterm`）现有架构，强调**复用**已有终端（xterm v4）、SFTP、远程编辑、状态采集能力，新增一个桌面壳层 + 窗口管理器 + 浏览器（进程内 HTTP 网关，走 SSH `direct-tcpip` 通道）。

---

## 0. 已确认决策

| # | 决策 | 说明 |
|---|---|---|
| 1 | **每标签一个模式开关** | 模式（终端/桌面）是 `SessionTab` 级状态，开关挂在标签栏每个标签上，作用于该标签；非全局顶栏按钮。 |
| 2 | **桌面模式不保留 AI 助手** | 进入桌面模式时 AI 助手面板完全不渲染；侧栏可收成图标条用于召回文件管理器。退回终端模式恢复 AI。 |
| 3 | **浏览器直接采用方案 B（进程内 HTTP 网关）** | 默认走网关，支持点链接漫游多个内部站点；方案 A（按端口 `ssh -L` 直连）作为窗口内「直连端口」兜底模式，用于网关改写失效的站点。 |
| 4 | **窗口布局按 host 持久化** | 每个 host 记住其桌面窗口清单（类型/参数/归一化坐标/状态），重连或重开时还原。 |
| 5 | **监控窗口、编辑器窗口纳入第一期** | 与终端/文件管理器同为 MVP 应用。 |

---

## 1. 背景与目标

### 1.1 现状一句话
terminall 是一个 Flutter 桌面端 SSH 客户端（macOS + Windows），单 `MainShellScreen` 内以「标签 -> 分屏树（`SessionPaneNode`）-> 终端 + SFTP 侧栏 + AI 助手」组织。每个分屏叶子持有一个 `SshWorkspaceController`，它**独占一条 SSH 连接**，同时持有：一个交互 shell（PTY）、一个 SFTP、一个 xterm `Terminal`、上传任务队列、助手会话。

### 1.2 目标能力
| 能力 | 说明 |
|---|---|
| 桌面模式切换 | 每个标签自带「终端/桌面」开关；切到桌面时该标签主内容区换成桌面，与终端模式共享同一条 SSH 连接。 |
| 桌面窗口系统 | 由本程序渲染的窗口化桌面：拖动、缩放、最小化、最大化、聚焦/z 序、任务栏 + 启动器。 |
| 终端窗口 | 桌面内可开**多个**终端，复用 xterm `TerminalView`；每个终端是同一 `SSHClient` 上的一个独立 PTY shell。 |
| 文件管理器窗口 | 复用 SFTP 浏览能力（面包屑、列表、拖出上传、右键菜单、双击编辑），以桌面窗口形式呈现，可多开、独立目录。 |
| 浏览器窗口 | 内嵌 webview，经**进程内 HTTP 网关**（走 SSH `direct-tcpip` 通道）访问服务器内部网站，支持点链接漫游；自签证书放行；「直连端口」兜底。 |
| 监控窗口 | 复用 `RemoteHostSnapshot`（CPU/内存/磁盘/负载/运行时间），周期刷新。 |
| 任务管理器 | 远端进程列表（Linux `ps` / Windows `tasklist`），筛选、排序、结束进程。 |
| 编辑器窗口 | 复用 `RemoteEditorScreen` 读写逻辑，以窗口形式打开远程文本文件。 |
| 可视化操作 | 文件双击用编辑器窗口打开、拖拽上传、右键菜单、窗口间拖放--尽量用 GUI 替代 CLI。 |
| 布局持久化 | 按 host 记住窗口布局，重连/重开自动还原。 |

### 1.3 非目标（本期不做）
- 不做 VNC/RDP/X11 远程桌面投屏（用户明确要「我们程序渲染的桌面」）。
- 不做远程 GUI 应用（无 X11 转发）。
- 不替换现有终端工作台；桌面是并列的视图模式。

---

## 2. 现状分析（关键事实，含行号）

> 来源：`ssh_workspace_controller.dart`、`session_tabs_controller.dart`、`session_pane.dart`、`session_pane_layout.dart`、`session_workspace.dart`、`sftp_side_panel.dart`、`main_shell_screen.dart`、`assistant_side_panel.dart`、`workbench_settings_store.dart`、`workbench_desktop_shortcuts.dart`、`remote_host_metrics.dart`，及 dartssh2 2.17.1 源码。

### 2.1 连接模型（`ssh_workspace_controller.dart`）
- `connect()`（375-507）：`SSHSocket.connect`（391）-> 建 `SSHClient`（414-426）-> `await _client!.authenticated`（428）-> `client.shell(pty: SSHPtyConfig(type, width, height))`（431-437）-> `_sftp = await _client!.sftp(); handshake`（439-440）-> `_remoteCwd = sftp.absolute('.')`（443）-> `if (_terminal==null) _initTerminal()`（448，仅首次）-> `_wireShell()`（451）-> `_connected=true`（453）-> `_startDropMonitor()`（455）。
- `_initTerminal()`（509-522）：建 xterm `Terminal`，`onOutput -> _shell.write`，`onResize -> _shell.resizeTerminal`。
- `_wireShell()`（542-559）：`session.stdout/stderr -> term.write`。
- getter：`sftp`（359）、`terminal`（273）、`runRemoteForStatus(cmd)`（1251-1261，用 `_client.run`）、`remoteCwd/entries/error/loadingDir/connecting/connected/dropped`（345-351）、`uploadTasks`（362，`SftpUploadTaskList`）。
- `readRemoteFile(name)`（1206）/`writeRemoteFile(name,bytes)`（1223）/`remoteMtime(name)`（1242），上限 `kMaxEditorBytes=512*1024`（30）。
- `_teardownConnection({keepTerminal})`（1267-1293）：取消 stdout/stderr 订阅、关 shell/sftp/client；`keepTerminal=true` 保留 `_terminal`+`_entries`。
- `_startDropMonitor()`（1332-1339）：挂 `client.done` -> `_handleTransportClosedAsync`（1345-1376，判 `identical(_client, client)` 防陈旧）-> `_teardownConnection(keepTerminal:true)` + `_dropped=true`。
- `reconnect()`（1322-1326）：重入 `connect()`，保留 `_terminal` 滚动历史。`reconnectWithCredentials()`（1303-1316）：换凭据 + 全量 teardown + 重连。
- **dartssh2 端口转发**（`ssh_client.dart`）：`forwardLocal(remoteHost, remotePort, {localHost, localPort})`（370-384）返回 `SSHForwardChannel`，是**单条 direct-tcpip 通道**（不是本地监听器）；`localHost/localPort` 仅协议字段。`forwardDynamic(...)`（394-408）返回 `SSHDynamicForward`（本地 SOCKS5 监听器）。`SSHHttpClient`（`http/http_client.dart`）内部用 `forwardLocal` 做 HTTP。

### 2.2 UI 结构（`main_shell_screen.dart`）
- 单 `MaterialApp` home，`setState` 驱动；全屏子页仅 `RemoteEditorScreen`（`Navigator.push`），其余 `showDialog/showModalBottomSheet`。
- `_rightPane()`（856-877）：无标签返回 `_WorkbenchPlaceholder`；否则返回 `SessionPaneLayout(key: ValueKey('tab-${tab.id}'), tabs, tab, tabIndex, workbenchSettings, ...)`。
- 终端区挂载点：`_ResizableSidebarAndTerminal` 内 `Expanded(child: TerminalWithAssistantSplit(settings, sessionTab: _tabs.selectedTab, terminalChild: _rightPane()))`（819-824）。**这是桌面视图的最低成本插入点**。
- `TerminalWithAssistantSplit`（`assistant_side_panel.dart` 17-32）：`Row` -> `Expanded(terminalChild)` + 5px splitter + 助手（展开 `SizedBox(width: assistantPanelWidth)` / 收起 40px `_AssistantCollapsedRail`）（98-113）。常量 `_minTerminal=200/_minAssistant=220/_maxAssistant=560`（36-39）。**桌面模式下需跳过 99-113 这段，只留 `Expanded(terminalChild)`**。
- 标签栏 `_WorkspaceSessionTabBar`（1365-1728）；每标签由 `buildTab(t, i)`（1521-1636）渲染：`Row`（1551-1629）= 状态点+标题（1554-1586）+ 复制按钮（1588-1608）+ 关闭按钮（1609-1628）。**模式开关按钮插在 1586 与 1588 之间**。

### 2.3 终端渲染（`session_workspace.dart`，类 `SessionTerminalPane`）
- 构造（18-23）：`controller`、`workbenchSettings`、`autofocusTerminal`。
- `TerminalView`（527-548）：`controller:_viewController`、`focusNode:_termFocus`、`scrollController:_termScroll`、`theme:_workbenchTerminalTheme(context.wb.terminalBg)`、`textStyle`（508-512）、`readOnly:!c.connected`、`autoResize:true`、`hardwareKeyboardOnly:!kIsWeb`、右键 `onSecondaryTapUp -> _showTerminalContextMenu`。
- 待抽取进 `TerminalSurface` 的纯渲染/输入/选择部分：拖选逻辑（142-338）、右键菜单（340-422）、断线浮层（553-631）、主题助手（57-84）、focusNode 管理（42/101/274-276/327-338）、终端缓冲切换监听 `_syncTerminalBufferListener`（118-124）+ 选择即复制防抖 `_onTerminalBufferChanged`（126-140）。
- I/O 接线在 controller（`_initTerminal`/`_wireShell`），不在 widget。

### 2.4 SFTP（`sftp_side_panel.dart`，类 `SftpSidePanel`）
- 构造（322-333）：仅 `controller`；`_c => widget.controller`（339）；静态 `isDraggingInternalItem`（329）。
- 面包屑（542-613）、目录 `ListView`（710-865，`itemCount:_c.entries.length`）、右键菜单 `_showEntryContextMenu`（121-158）、拖出 `_SftpRemoteEntryDragWrap`（190-320）、拖入 `DropTarget`（616-903）、上传页脚 `ListenableBuilder(_c.uploadTasks)`（866-898）。
- 对 controller 的全部依赖（抽取 `SftpBrowser` 的接缝）：`remoteCwd`（535）、`entries`（715/721）、`loadingDir`（563/602/652/831）、`sftp`（208）、`uploadTasks`（867/869/886/887/895/896）、`refreshDirectory`（604）、`navigateToAbsolutePath`（566）、`navigateInto`（834）、`deleteRemote`（523）、`downloadRemoteDirectoryToLocal`（353）、`downloadRemoteFileToLocalPath`（365）、`readRemoteFile`（473）、`remoteMtime`（482）、`inspectLocalUploadConflict`（419）、`removeRemoteSubtreeForOverwrite`（458）、`uploadMultipleLocalPaths`（403）、`startBackgroundDirectoryDragOut`（237）、`materializeRemoteFileToTempForDrag`（269）、`streamRemoteFileIntoDragSink`（293-298）、`registerDragTempPath`/`isPathFromRecentDragOut`（静态）。

### 2.5 分屏与设置
- `SessionPaneNode` sealed（`session_pane.dart` 7-21）：`SessionPaneLeaf{paneId, controller}`（23-51）、`SessionPaneSplit{axis, first, second, ratio}`（53-129，ratio 0.15-0.85）。`splitLeaf()`（140-153）。
- `_PaneLeafFrame`（`session_pane_layout.dart` 208-458）：`showChrome=tab.hasSplit` 时渲染 28px 标题栏（264-352）；叶子内容 `SessionWorkspace(...)`（357-362）。
- `WorkbenchSettingsStore`（`workbench_settings_store.dart`）：`SharedPreferences` 持久化，键 `wb_*`（8-25）。含 `assistantPanelCollapsed=true`（85）、`assistantPanelWidth=320`（88，clamp [240,560]）。`load()`（109-149）/`persist()`（151-172）。
- `workbench_desktop_shortcuts.dart`（1-94）：**OS 级窗口快捷键/窗口控制助手**（`windowManager.destroy/close/minimize`、Cmd/Ctrl+Q 等），**与「可视化桌面」无概念冲突**；命名上我们的类用 `RemoteDesktop*` 前缀避免混淆。

---

## 3. 总体设计

### 3.1 概念：标签级「视图模式」
给 `SessionTab` 增加字段 `SessionViewMode viewMode`（默认 `terminal`）。标签栏每标签一个模式开关；`_rightPane()` 据此返回 `SessionPaneLayout` 或 `RemoteDesktopView`。二者共用该标签 `SshWorkspaceController` 的 `SSHClient`/`SftpClient`。

```
┌──────────────── MainShellScreen ────────────────┐
│ 顶栏  [新建]  ...                                 │
├──────────┬──────────────────────────────────────┤
│ 侧栏(可收 │  标签栏: [host1:终端 ●][host2:桌面 ●]  │ ← 每标签模式开关
│ 成图标条)│          主内容区(该标签模式决定)        │
│          │  ┌─ RemoteDesktopView ─────────────┐ │
│          │  │  桌面顶条 + 启动器                 │ │
│          │  │  ┌窗口┐ ┌窗口──┐ ┌窗口┐           │ │
│          │  │  │终端│ │浏览器│ │文件│           │ │
│          │  │  └────┘ └─────┘ └────┘           │ │
│          │  │  任务栏: [□终端 ▣浏览器 ▣文件]     │ │
│          │  └──────────────────────────────────┘ │
└──────────┴──────────────────────────────────────┘
```

桌面模式下：**AI 助手面板完全不渲染**；侧栏收成图标条，点击召回文件管理器（也可直接在桌面开文件管理器窗口）。退回终端模式恢复原布局（含 AI）。

### 3.2 复用 vs 新增
| 模块 | 策略 |
|---|---|
| SSH 连接 / 掉线 / 重连 | **复用** `SshWorkspaceController` 生命周期；新增按需开 shell/转发方法。 |
| 终端渲染 | **抽取** `TerminalSurface`（纯渲染/输入/选择/菜单/浮层）；桌面终端复用。 |
| 终端 I/O 接线 | **新增** `RemoteShell`（PTY+Terminal+onOutput/onResize/stdout/stderr），桌面多终端各持一个；controller 主终端保持现状（阶段 3 可统一）。 |
| SFTP 浏览 | **抽取** `SftpBrowser` + 接口 `SftpBrowserHost`；`SshWorkspaceController implements SftpBrowserHost`；桌面 `FileManagerApp` 用独立 `DesktopSftpController`（共享 `SftpClient`，独立 cwd）。 |
| 上传/拖出 | **抽取** `SftpTransferHelpers`（静态/mixin），controller 与桌面共用。 |
| 远程编辑器 | **复用** `RemoteEditorScreen` 读写逻辑，桌面内改为窗口组件。 |
| 远程指标 | **复用** `RemoteHostSnapshot` + `runRemoteForStatus`。 |
| 窗口管理器 / 任务栏 / 启动器 | **新增**。 |
| 浏览器 + HTTP 网关 + 端口转发 | **新增**。 |
| 窗口布局持久化 | **新增** `DesktopLayoutStore`。 |

### 3.3 分层
```
┌─────────────────────── UI 层 ───────────────────────┐
│ RemoteDesktopView │ DesktopWindowFrame │ Taskbar    │
├──────────── 桌面应用层（每个 = 一个窗口内容）──────────┤
│ TerminalApp │ FileManagerApp │ BrowserApp │ MonitorApp│ TaskManagerApp │ EditorApp
├──────────────── 会话/资源层（共享一条 SSH）────────────┤
│ SshWorkspaceController（基座，扩方法）                │
│  ├─ RemoteShell（多实例：PTY+Terminal）              │
│  ├─ SftpClient（共享）+ DesktopSftpController（多实例）│
│  ├─ BrowserGateway（HTTP 网关，用 forwardLocal）     │
│  └─ LocalPortForwarder（方案 A 兜底，用 ServerSocket）│
└────────────────────────────────────────────────────┘
```

> **低侵入优先**：阶段 0-2 只给 `SshWorkspaceController` 加方法、抽取组件，不改其生命周期。阶段 3 可选把 `SSHClient`/`SftpClient` 抽到 `RemoteSession`（§7.3）。

---

## 4. 桌面窗口管理器

### 4.1 数据模型（`lib/desktop/desktop_window_manager.dart`）
```dart
enum WindowState { normal, minimized, maximized }
enum DesktopAppType { terminal, files, browser, monitor, editor }
enum TileZone { left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }

class DesktopWindow {
  final String id;            // uuid
  final DesktopAppType type;
  String title;
  Rect _normalRect;           // normal 态逻辑坐标
  WindowState state;
  double z;                   // 越大越在上
  bool focused;
  Rect? _preMaxRect;          // 最大化前的位置，用于还原
  final Map<String, dynamic> args;  // browser: {url,mode} / editor: {path} / terminal: {cwd}
  Widget Function(BuildContext, DesktopWindow) contentBuilder;
  // 序列化用
  Map<String, dynamic> toJson();
}

class DesktopWindowManager extends ChangeNotifier {
  DesktopWindowManager({required this.controller, required this.hostKey});
  final SshWorkspaceController controller;
  final String hostKey;
  final List<DesktopWindow> _windows = [];
  final DesktopLayoutStore _store;        // 注入
  Size desktopSize = Size.zero;           // 由 LayoutBuilder 更新
  double _zSeq = 0;
  int _idSeq = 0;

  List<DesktopWindow> get windows => List.unmodifiable(_windows);
  DesktopWindow? get focused => _windows.firstWhereOrNull((w) => w.focused);

  DesktopWindow open(DesktopAppType type, {Map<String,dynamic>? args, Rect? rect});
  void close(String id);
  void focus(String id);                  // w.z = ++_zSeq; focused 置位；notify + 防抖存盘
  void startDrag(String id);              // 进入拖动
  void dragBy(String id, Offset delta);   // clamp 标题栏不出桌面
  void startResize(String id, Edge corner);
  void resizeBy(String id, Edge corner, Size delta);  // min 240x160，clamp
  void minimize(String id);
  void toggleMaximize(String id);         // 存 _preMaxRect，置 maximized，rect=工作区
  void restore(String id);
  void tile(String id, TileZone zone);    // 贴边分屏（阶段 3）
  void setDesktopSize(Size s);            // 桌面尺寸变化时重排/clamp
  void restoreLayout();                   // 进入桌面模式调用
  void _persistDebounced();               // 500ms 防抖落盘
}
```

### 4.2 渲染（`lib/desktop/remote_desktop_view.dart`，本程序渲染）
`RemoteDesktopView` = `LayoutBuilder` -> `DesktopWindowManager`（注入或托管于 `SessionTab`）-> `Stack`：
- **背景层**：纯色/主题图；可放 host 快捷方式（预留，阶段 3）。
- **窗口层**：每个非 minimized 的 `DesktopWindow` -> `Positioned(left,top,width,height, child: DesktopWindowFrame(...))`，按 `z` 升序绘制（focused 在最上）。
- **任务栏层**（底部，高 44）：`DesktopTaskbar`，列出所有窗口按钮（点击聚焦/最小化切换）+ 启动器按钮（弹出应用菜单：终端/文件/浏览器/监控）。

`DesktopWindowFrame`（`lib/desktop/desktop_window_frame.dart`）：
- 标题栏（高 30）：图标 + 标题 + [最小化][最大化/还原][关闭]。`GestureDetector.onPanUpdate -> wm.dragBy`；双击 `-> wm.toggleMaximize`。
- 8 个 resize 手柄（4 边 + 4 角，`MouseRegion` 改光标 + `GestureDetector.onPanUpdate -> wm.resizeBy(corner, delta)`）。
- 内容区：`contentBuilder(context, win)`，`min` 尺寸 240x160。
- 聚焦态：边框高亮；点击窗口任意处 `wm.focus`。

### 4.3 交互与几何
- **z 序**：`focus` 时 `w.z = ++_zSeq`；`Stack` 按 `z` 升序绘制；focused 必为最大 z。
- **拖动 clamp**：标题栏中心点始终保持在桌面内（`left ∈ [-w+80, desktopW-80]`, `top ∈ [0, desktopH-30]`）。
- **缩放 clamp**：min 240x160；右边/下边不超过 `desktopW/desktopH`。
- **最大化**：`rect = Rect.fromLTRB(0, 0, desktopW, desktopH - taskbarH)`，存 `_preMaxRect` 还原。
- **桌面尺寸变化**：`setDesktopSize` 后，所有 maximized 重算；normal rect 按比例/绝对 clamp 进可视区。
- **快捷键**：`CallbackShortcuts`（复用 `workbenchBindActivators`），`Cmd/Ctrl+W` 关当前窗口、`Cmd/Ctrl+M` 最小化、`Esc` 关启动器。

### 4.4 托管与生命周期
- `DesktopWindowManager` 由谁持有？方案：挂在 `SessionTab` 上（`SessionTab.desktopWindowManager`，懒创建，进入桌面模式时实例化并 `restoreLayout()`）。`SessionTabsController._disposeTabResources`（329-335）追加 `tab.desktopWindowManager?.dispose()`。
- `dispose()`：关闭所有窗口（触发各 App 资源回收：shell/网关/转发关闭）、落盘。
- 掉线：监听 `controller.dropped`，所有窗口叠浮层；监听 `controller.connected` 由假转真，清除浮层并提示重开额外 shell（主终端窗口的 `terminal` 仍来自 controller，缓冲保留）。

---

## 5. 桌面应用

### 5.1 终端窗口（TerminalApp）+ RemoteShell + TerminalSurface

#### `RemoteShell`（`lib/services/remote_shell.dart`，新增）
封装「一条 PTY + 一个 xterm Terminal + I/O 接线」，镜像 controller 的 `_initTerminal`/`_wireShell`：
```dart
class RemoteShell {
  final SSHSession session;
  final Terminal terminal;
  StreamSubscription<List<int>>? _out, _err;
  RemoteShell._(this.session, this.terminal);

  static Future<RemoteShell> open(SSHClient client, {required WorkbenchSettingsStore s, int? cols, int? rows}) async {
    final session = await client.shell(pty: SSHPtyConfig(
      type: s.terminalTermType,
      width: cols ?? s.ptyDefaultColumns,
      height: rows ?? s.ptyDefaultRows,
    ));
    final terminal = Terminal(
      maxLines: s.terminalMaxLines,
      platform: _xtermPlatform(),
      onOutput: (d) => session.write(Uint8List.fromList(utf8.encode(d))),
      onResize: (w, h, pw, ph) => session.resizeTerminal(w, h, pw, ph),
    );
    final shell = RemoteShell._(session, terminal);
    shell._out = session.stdout.listen((d) => terminal.write(utf8.decode(d, allowMalformed: true)));
    shell._err = session.stderr.listen((d) => terminal.write(utf8.decode(d, allowMalformed: true)));
    return shell;
  }
  void resize(int w, int h, int pw, int ph) => session.resizeTerminal(w, h, pw, ph);
  void paste(String s) => terminal.paste(s);
  Future<void> close() async {
    await _out?.cancel(); await _err?.cancel();
    try { session.close(); } catch (_) {}
  }
}
```

#### `TerminalSurface`（`lib/widgets/terminal_surface.dart`，抽取自 `session_workspace.dart`）
纯渲染/输入/选择/菜单/浮层，不依赖 `SshWorkspaceController`：
```dart
class TerminalSurface extends StatefulWidget {
  const TerminalSurface({
    super.key,
    required this.terminal,
    this.connected = true,
    this.autofocus = false,
    this.onReconnect,
    this.themeBg,
    this.textStyle,
    this.selectToCopy = false,
  });
  final Terminal terminal;
  final bool connected;          // readOnly = !connected；并决定是否叠断线浮层
  final bool autofocus;
  final VoidCallback? onReconnect;
  final Color? themeBg;
  final TerminalStyle? textStyle;
  final bool selectToCopy;
}
```
State 内迁入（原行号见 §2.3）：拖选 142-338、右键菜单 340-422、断线浮层 553-631、主题 57-84、focusNode/scrollController/viewController 自管。`connected=false` 且 `onReconnect!=null` 时叠「重连」浮层。

`SessionTerminalPane` 改为薄封装：持 controller，监听 `terminal`/`connected`，把 `controller.terminal!`、`controller.connected`、`controller.reconnect` 接给 `TerminalSurface`；保留 `_syncTerminalBufferListener`（118-124）逻辑。

`TerminalApp`：`contentBuilder` 内 `RemoteShell.open(controller.clientForDesktop, settings: ...)` -> `TerminalSurface(terminal: shell.terminal, connected: true, onReconnect: ...)`；窗口 `resizeBy`/最大化时调 `shell.resize(w,h,pw,ph)`（用 `WidgetsBinding.addPostFrameCallback` 取内容区像素尺寸换算行列）。关闭窗口 -> `shell.close()`。

### 5.2 文件管理器窗口（FileManagerApp）+ SftpBrowser + SftpBrowserHost

#### `SftpBrowserHost` 接口（`lib/services/sftp_browser_host.dart`，新增）
把 `SftpSidePanel` 对 controller 的全部依赖（§2.4 列表）抽成抽象接口：
```dart
abstract class SftpBrowserHost extends ChangeNotifier {
  SftpClient? get sftp;
  String get remoteCwd;
  List<SftpName> get entries;
  bool get loadingDir;
  SftpUploadTaskList get uploadTasks;
  Future<void> refreshDirectory();
  Future<void> navigateInto(SftpName entry);
  Future<void> navigateToAbsolutePath(String path);
  Future<Uint8List?> readRemoteFile(String name);
  Future<void> writeRemoteFile(String name, Uint8List bytes);
  Future<DateTime?> remoteMtime(String name);
  Future<void> deleteRemote(String name);
  Future<String?> downloadRemoteFileToLocalPath(String name);
  Future<String?> downloadRemoteDirectoryToLocal(String name);
  Future<List<UploadConflict>> inspectLocalUploadConflict(List<String> localPaths);
  Future<void> removeRemoteSubtreeForOverwrite(String name);
  Future<void> uploadMultipleLocalPaths(List<String> paths);
  // 拖出助手（抽到 SftpTransferHelpers，见下）
}
```
`SshWorkspaceController implements SftpBrowserHost`（既有方法直接满足，仅需 `implements` 声明 + 个别签名对齐）。

#### `SftpTransferHelpers`（`lib/services/sftp_transfer_helpers.dart`，抽取）
把拖出/临时物化逻辑抽为静态/mixin：`startBackgroundDirectoryDragOut`、`materializeRemoteFileToTempForDrag`、`streamRemoteFileIntoDragSink`、`registerDragTempPath`、`isPathFromRecentDragOut`、`isDraggingInternalItem` 静态标志。controller 与 `DesktopSftpController` 共用。

#### `SftpBrowser`（`lib/widgets/sftp_browser.dart`，抽取自 `sftp_side_panel.dart`）
```dart
class SftpBrowser extends StatefulWidget {
  const SftpBrowser({super.key, required this.host, this.onOpenInEditor});
  final SftpBrowserHost host;
  final void Function(String fileName)? onOpenInEditor;  // 桌面:开编辑器窗口; 侧栏:Navigator.push
}
```
迁入：面包屑 542-613、`ListView` 710-865、右键 121-158、`_SftpRemoteEntryDragWrap` 190-320、`DropTarget` 616-903、上传页脚 866-898。所有 `_c.xxx` 改 `host.xxx`。
`SftpSidePanel` 变薄：`SftpBrowser(host: controller, onOpenInEditor: (n) => Navigator.push(...RemoteEditorScreen...))`。

#### `DesktopSftpController`（`lib/services/desktop_sftp_controller.dart`，新增）
`implements SftpBrowserHost`，**共享** controller 的 `sftp`，**独立** `_remoteCwd`/`_entries`/`_loadingDir`/自己的 `uploadTasks`（或共用 controller 的）。多个文件管理器窗口各持一个，互不干扰目录。掉线时 `sftp=null`，重连后由 controller 重建 `sftp` 并通知各 `DesktopSftpController` 重新 `refreshDirectory`。

`FileManagerApp`：`contentBuilder` 内 `SftpBrowser(host: desktopSftpController, onOpenInEditor: (name) => wm.open(editor, args:{'path': join(host.remoteCwd, name)}))`。

### 5.3 浏览器窗口（BrowserApp）--核心新增
浏览器要访问服务器内部网站，流量必须走 SSH。**默认方案 B（进程内 HTTP 网关）**；**方案 A（按端口 `ssh -L` 直连）为窗口内兜底模式**。

#### 5.3.1 方案 B：`BrowserGateway`（`lib/services/browser_gateway.dart`，默认）
进程内 HTTP 反向代理，URL 改写使站内链接漫游。

**URL 方案**：`http://127.0.0.1:{gatewayPort}/{token}/{remoteHost}/{remotePort}/{pathAndQuery}`
- `gatewayPort`：`HttpServer.bind('127.0.0.1', 0)` 取随机端口，仅本机。
- `token`：32 字节 hex，每个 `BrowserGateway` 实例一个，每请求校验（403 拒绝）。
- `remoteHost`/`remotePort`：URL 编码的目标。
- `pathAndQuery`：原 path + query，透传。

**请求流**：
1. `HttpServer` 收到请求；拆 `/{token}/{remoteHost}/{remotePort}/{rest}`；校验 token；校验 `Host` 头 == `127.0.0.1:{gatewayPort}`（防 DNS rebinding）。
2. 判远端 scheme：默认 `http`；`remotePort==443` 或书签标注 `https` 时用 `https`。
3. `final ch = await client.forwardLocal(remoteHost, remotePort);` 拿 `SSHForwardChannel`。
   - 若 https：用 `SecureSocket.secure(ch, onBadCertificate: (_)=>true)` 包一层（远端自签放行）。webview 侧仍是 `http://127.0.0.1`，**无证书问题**。
4. 拼原始 HTTP 请求字节：`{METHOD} {rest} HTTP/1.1\r\nHost: {remoteHost}:{remotePort}\r\n` + 转发头（剔除 hop-by-hop：`Connection/Proxy-*/Transfer-Encoding/Keep-Alive`；强制 `Accept-Encoding: identity` 便于改写 body）+ body。写 `ch.sink`。
5. 读 `ch.stream` 解析响应状态行+头；**改写**：
   - `Location`：绝对内部 URL `http(s)://remoteHost:remotePort/x` -> `http://127.0.0.1:{port}/{token}/{remoteHost}/{remotePort}/x`；相对则按当前 origin 补全。
   - `Set-Cookie`：去掉 `Domain` 属性，使 cookie 绑定 `127.0.0.1`。
6. 若 `Content-Type: text/html|css`：body 流式过 URL 重写器，改写 `href`/`src`/`url(...)` 中的绝对内部 URL 到网关命名空间（相对路径不动，天然有效）。
7. 流式写回 webview 的 `HttpResponse`。

**WebSocket**：检测 `Upgrade: websocket` + `Connection: upgrade` -> 回 `101 Switching Protocols` -> 对该 `forwardLocal` 通道裸字节双向 pipe（webview 侧 `ws://127.0.0.1:{port}/{token}/{host}/{port}/...`）。

**安全**：仅 bind `127.0.0.1`；token 校验；`Host` 头校验。

**限制/兜底**：JS 运行时动态拼绝对 URL（如 `fetch('http://othersvc:80/x')`）无法改写 -> 用户在该窗口切「直连端口」模式（方案 A）直转该服务，或为该服务另开窗口。

#### 5.3.2 方案 A：`LocalPortForwarder`（`lib/services/local_port_forwarder.dart`，兜底）
真正的 `ssh -L` 等价（dartssh2 的 `forwardLocal` 不是监听器，需自起 `ServerSocket`）：
```dart
class LocalPortForwarder {
  LocalPortForwarder(this.client, this.remoteHost, this.remotePort);
  final SSHClient client; final String remoteHost; final int remotePort;
  ServerSocket? _server; StreamSubscription? _sub; int? _localPort;
  int? get localPort => _localPort;
  Future<void> start({int? localPort}) async {
    _server = await ServerSocket.bind('127.0.0.1', localPort ?? 0);
    _localPort = _server!.port;
    _sub = _server!.listen((sock) async {
      try {
        final ch = await client.forwardLocal(remoteHost, remotePort);
        _pipe(sock, ch);            // 双向 pipe，任一关闭则双双关闭
      } catch (_) { sock.destroy(); }
    });
  }
  Future<void> stop() async { await _sub?.cancel(); await _server?.close(); _server = null; }
}
```
webview 加载 `http(s)://127.0.0.1:{localPort}/...`；HTTPS 自签用 `InAppWebView` 的 `onReceivedServerTrustAuthRequest -> ServerTrustAuthResponse.PROCEED` 放行。一个转发对应一个远端端口。

#### 5.3.3 统一接口与窗口
```dart
abstract class RemoteBrowserBackend {
  Future<Uri> resolveUrl(String remoteHost, int remotePort, {String? path});
  Future<void> close();
}
class GatewayBrowserBackend implements RemoteBrowserBackend { ... }       // 方案 B（默认）
class LocalForwardBrowserBackend implements RemoteBrowserBackend { ... }  // 方案 A（兜底）
```
`BrowserApp`：`InAppWebView` + 地址栏（输入 `host:port[/path]` 或完整内部 URL，解析后 `backend.resolveUrl` 导航）+ 前进/后退/刷新 + 模式切换（网关/直连，切直连时提示输入 host:port）+ 书签（按 host 存 `SharedPreferences`）。地址栏旁标注「内网/自签」。

### 5.4 监控窗口（MonitorApp，第一期）
- 复用 `RemoteHostSnapshot.fetchRemoteHostSnapshot(controller.runRemoteForStatus)`（`remote_host_metrics.dart`）。
- 周期刷新（5s，`Timer.periodic`，窗口最小化时暂停）；画 CPU/内存/磁盘/inode/负载/运行时间卡片 + 迷你趋势条（最近 N 次）。
- 掉线：显示「重连后刷新」。

### 5.4b 任务管理器（TaskManagerApp）
- `remote_process_list.dart`：探测远端 OS（`/proc` → Linux，`tasklist` → Windows），再拉进程列表。
- 三页签：**进程** / **性能** / **服务**（结构贴近 Windows 任务管理器）。
- Linux：`ps` + `systemctl list-units`；结束进程 `kill -KILL`；服务 `systemctl start|stop|restart`。
- Windows：`tasklist /FO CSV` + `Get-Service`；结束 `taskkill /F`；服务 `sc`/`net start|stop`。
- 进程页：筛选、列排序、右键/双击结束任务；性能页复用 `RemoteHostSnapshot`；服务页可启停重启（需远端权限）。
- 按页签刷新间隔不同（进程 3s / 性能 2s / 服务 8s），最小化暂停。

### 5.5 编辑器窗口（EditorApp，第一期）
- 复用 `RemoteEditorScreen` 读写逻辑（`readRemoteFile`/`writeRemoteFile`/`remoteMtime` 轮询、`looksLikeTextBytes`/`kMaxEditorBytes` 限制、`CallbackShortcuts` ⌘S）。
- 改为窗口内组件（非 `Navigator.push`）；`args['path']` 定位初始文件（相对 `remoteCwd` 或绝对）。
- `onOpenInEditor` 由 `FileManagerApp` 双击触发：`wm.open(editor, args:{'path': ...})`。

---

## 6. 数据流与生命周期

### 6.1 连接共享
- 进入桌面模式：若已连接，直接用 `controller.clientForDesktop`/`controller.sftp`；把 controller 主 `_terminal` 包成「终端窗口 #1」（不浪费，且保留断线缓冲）。
- 桌面内新开终端/网关/转发：调 controller 新增方法（§7.2），复用同一 `SSHClient`。
- 退出桌面模式：`DesktopWindowManager` 关闭所有窗口（关额外 shell、`BrowserGateway.stop()`、`LocalPortForwarder.stop()`），落盘布局；保留主 shell + 终端缓冲。

### 6.2 掉线与重连
- `controller.dropped` 变真：所有桌面窗口叠「连接已断开 - 重连」浮层；`BrowserGateway`/`LocalPortForwarder` 监听 `client.done` 自动停本地监听。
- `controller` 重连成功：主终端窗口缓冲仍在；额外 shell 需重开（提示用户）；网关/转发按需重建；各 `DesktopSftpController` 重新 `refreshDirectory`。

### 6.3 资源回收（四处统一）
关窗口 / 关标签 / 退出桌面模式 / 掉线，均触发对应 `RemoteShell.close()`、`BrowserGateway.stop()`、`LocalPortForwarder.stop()`、`DesktopSftpController` 解绑。`SessionTabsController._disposeTabResources`（329-335）追加 `tab.desktopWindowManager?.dispose()`。

### 6.4 窗口布局持久化（按 host）
新增 `DesktopLayoutStore`（`lib/services/desktop_layout_store.dart`），`SharedPreferences` 存 JSON（沿用 `WorkbenchSettingsStore` 模式，键 `desktop_layout_<hostKey>`）。

**JSON schema**：
```json
{
  "version": 1,
  "hostKey": "user@host:22",
  "windows": [
    {"type":"terminal","args":{"cwd":null},"rect":[0.04,0.06,0.5,0.6],"state":"normal","z":1.0},
    {"type":"browser","args":{"url":"localhost:3000","mode":"gateway"},"rect":[0.52,0.08,0.44,0.7],"state":"normal","z":2.0},
    {"type":"files","args":{"cwd":"/var/www"},"rect":[0.06,0.7,0.4,0.26],"state":"minimized","z":0.0},
    {"type":"monitor","args":{},"rect":[0.5,0.74,0.2,0.22],"state":"normal","z":1.5}
  ]
}
```
- `rect = [xFrac, yFrac, wFrac, hFrac]`（0..1，相对 `desktopSize`），**避免跨分辨率/DPI 失配**。
- **还原**：进入桌面模式 `wm.restoreLayout()` -> 读 JSON -> 按清单 `open` 各窗口（终端重开 shell、浏览器恢复 URL、文件管理器恢复 cwd、监控直接建）-> `rect * desktopSize` 并 clamp 进可视区 -> 恢复 `state`/`z`。
- **保存**：窗口 open/close/drag/resize/maximize/focus 后 500ms 防抖 `_persistDebounced()`。
- **失败容忍**：JSON 损坏/版本不匹配 -> 静默丢弃，开一个默认终端窗口。
- `hostKey`：`$user@$host:$port`（或对应 host profile id）。

---

## 7. 复用与重构

### 7.1 抽取清单（让现有组件可在桌面复用）
| 新组件 | 抽取自 | 迁入内容（原行号） | 旧位置改为 |
|---|---|---|---|
| `TerminalSurface` | `session_workspace.dart` | 拖选 142-338、右键 340-422、断线浮层 553-631、主题 57-84、focusNode 管理 | 薄封装：接 controller.terminal/connected/reconnect -> `TerminalSurface` |
| `SftpBrowser` | `sftp_side_panel.dart` | 面包屑 542-613、ListView 710-865、右键 121-158、拖出 190-320、DropTarget 616-903、页脚 866-898 | 薄封装：`SftpBrowser(host: controller, onOpenInEditor: Navigator.push)` |
| `SftpBrowserHost` | （新接口） | `SftpSidePanel` 对 controller 的全部依赖（§2.4） | `SshWorkspaceController implements SftpBrowserHost` |
| `SftpTransferHelpers` | `sftp_side_panel.dart`/controller | 拖出/临时物化/内部拖拽标志 | controller 与 `DesktopSftpController` 共用 |

> 抽取是本方案**最大工作量与风险点**；收益是终端/桌面共用同一套渲染与传输组件，避免分叉。阶段 0 独立验收，终端模式逐项回归（选择/拖选/拖出/上传/编辑/断线重连）。

### 7.2 `SshWorkspaceController` 最小扩展（不破坏现有 API）
```dart
// 新增
SSHClient? get clientForDesktop => _client;             // 桌面层用，断线为 null
Future<RemoteShell> openShell({int? cols, int? rows}) =>
    RemoteShell.open(_client!, settings: settings, cols: cols, rows: rows);
Future<LocalPortForwarder> openLocalForward(String rHost, int rPort, {int? localPort}) async {
  final f = LocalPortForwarder(_client!, rHost, rPort);
  await f.start(localPort: localPort);
  return f;
}
BrowserGateway? _gateway;
BrowserGateway getOrCreateGateway() => _gateway ??= BrowserGateway(_client!)..start();
// sftp getter 已存在；runRemoteForStatus 已存在；readRemoteFile/writeRemoteFile 已存在
```
`_teardownConnection` 追加：关 `_gateway`、记录打开的 `LocalPortForwarder` 列表并停止。重连后 `_gateway` 置 null 重建。

### 7.3 可选重构（阶段 3）
把 `SSHClient`+`SftpClient`+掉线监控抽到 `RemoteSession`；`SshWorkspaceController` 与桌面层共持。代价：改 `connect()`/`_teardownConnection()`/`reconnect()`。**阶段 3 再做**。

---

## 8. 新增依赖与平台设置

| 依赖 | 用途 | 平台 | 设置 |
|---|---|---|---|
| `flutter_inappwebview` ^6.1.5 | 桌面内嵌浏览器 | macOS(WKWebView)/Windows(WebView2) | macOS：entitlements 需网络；Windows：WebView2 运行时（Win11 自带，Win10 多数自带），打包带 `WebView2Runtime`。先冒烟：证书放行/导航回调/Cookie/`ws://`。 |
| `dart:io`（已有） | `ServerSocket`/`HttpServer` 网关与转发 | 桌面 | 已在用。 |

> 端口转发/HTTP-over-SSH 全用 dartssh2 既有能力，无新传输层。

---

## 9. 目录结构与精确集成点

### 9.1 目录
```
lib/
  desktop/
    remote_desktop_view.dart        # 桌面表面：Stack + 背景 + 任务栏 + 启动器
    desktop_window_manager.dart     # DesktopWindowManager / DesktopWindow
    desktop_window_frame.dart       # 拖动/缩放/标题栏 chrome
    desktop_taskbar.dart            # 任务栏 + 启动器
    apps/
      terminal_app.dart             # TerminalSurface + RemoteShell
      file_manager_app.dart         # SftpBrowser + DesktopSftpController
      browser_app.dart              # InAppWebView + RemoteBrowserBackend
      monitor_app.dart              # RemoteHostSnapshot
      editor_app.dart               # 复用 RemoteEditorScreen 逻辑
  services/
    remote_shell.dart               # PTY + Terminal + I/O 接线
    browser_gateway.dart            # HTTP 网关（方案 B，默认）
    local_port_forwarder.dart       # ssh -L（方案 A 兜底）
    desktop_layout_store.dart       # 按 host 持久化布局
    sftp_browser_host.dart          # SftpBrowserHost 接口
    sftp_transfer_helpers.dart      # 拖出/临时物化助手
    desktop_sftp_controller.dart    # 桌面独立 cwd 的 SFTP 控制器
    # remote_session.dart           # 可选重构期（§7.3）
  widgets/
    terminal_surface.dart           # 抽取自 session_workspace.dart
    sftp_browser.dart               # 抽取自 sftp_side_panel.dart
```

### 9.2 `session_tabs_controller.dart` 改动
- 新增 `enum SessionViewMode { terminal, desktop }`。
- `SessionTab`（10-57）加字段：`SessionViewMode viewMode = SessionViewMode.terminal;` + `DesktopWindowManager? _desktop; DesktopWindowManager? get desktopWindowManager => _desktop;`。
- `SessionTabsController` 加：
  ```dart
  void setViewMode(int tabIndex, SessionViewMode mode) {
    final t = _tabs[tabIndex];
    if (t.viewMode == mode) return;
    t.viewMode = mode;
    if (mode == SessionViewMode.desktop) {
      t._desktop ??= DesktopWindowManager(controller: t.controller, hostKey: _hostKey(t));
      t._desktop!.restoreLayout();   // 已连接才真正建窗
    }
    notifyListeners();
  }
  ```
- `_disposeTabResources`（329-335）追加 `tab._desktop?.dispose()`。

### 9.3 `main_shell_screen.dart` 改动
- `_rightPane()`（856-877）：在 `tab != null` 分支前判 `tab.viewMode`：
  ```dart
  if (tab.viewMode == SessionViewMode.desktop) {
    return RemoteDesktopView(key: ValueKey('desktop-${tab.id}'), wm: tab.desktopWindowManager!, controller: tab.controller);
  }
  return SessionPaneLayout(...);  // 原
  ```
- `_ResizableSidebarAndTerminal` 终端区（819-824）：桌面模式下跳过 `TerminalWithAssistantSplit`，直接 `Expanded(child: _rightPane())`（隐藏 AI）：
  ```dart
  final isDesktop = _tabs.selectedTab?.viewMode == SessionViewMode.desktop;
  Expanded(child: isDesktop
    ? _rightPane()
    : TerminalWithAssistantSplit(settings: widget.settings, sessionTab: _tabs.selectedTab, terminalChild: _rightPane()))
  ```
- 标签栏 `buildTab` 的 `Row`（1551-1629）：在 1586 与 1588 之间插模式开关 `IconButton`：
  ```dart
  IconButton(
    icon: Icon(t.viewMode == SessionViewMode.desktop ? Icons.desktop_windows : Icons.terminal),
    tooltip: '切换 桌面/终端',
    onPressed: () => _tabs.setViewMode(i, t.viewMode == SessionViewMode.desktop
        ? SessionViewMode.terminal : SessionViewMode.desktop),
  ),
  ```
- 侧栏：桌面模式下收成图标条（点击在桌面开 `FileManagerApp` 或召回），具体在 `_WorkbenchSidebarPane` 按模式分支。

### 9.4 `session_workspace.dart` / `sftp_side_panel.dart` 改动
按 §7.1 抽取后，`SessionTerminalPane` 与 `SftpSidePanel` 变薄；保持对外构造签名不变（终端模式零回归）。

---

## 10. 实施阶段

### 阶段 0 · 抽取复用件（前置，终端模式零回归）
- [x] `TerminalSurface` 从 `session_workspace.dart` 抽出（迁 142-338/340-422/553-631/57-84）；`SessionTerminalPane` 改薄封装。
- [x] `SftpBrowser` + `SftpBrowserHost` 从 `sftp_side_panel.dart` 抽出；`SshWorkspaceController implements SftpBrowserHost`；`SftpSidePanel` 改薄封装。
- [x] `SshWorkspaceController` 加 `clientForDesktop`/`openShell()`/`openLocalForward()`/`getOrCreateGateway()`。
- [x] 新增 `RemoteShell`（独立冒烟：开第二个 shell、起一个本地转发、起网关用 curl 验证）。
- **验收**：现有功能全部不变（逐项回归：选择/拖选/拖出/上传/编辑/断线重连/状态栏/助手）；新方法可单独跑通。

### 阶段 1 · 桌面壳层 + 全部应用 + 布局持久化（MVP）
- [x] `DesktopWindowManager` + `DesktopWindowFrame` + `RemoteDesktopView` + `DesktopTaskbar`。
- [x] `SessionTab.viewMode` + `setViewMode` + 标签栏开关 + `_rightPane()`/`_ResizableSidebarAndTerminal` 分支 + 桌面隐藏 AI。
- [x] `TerminalApp`（含 `RemoteShell`）、`FileManagerApp`（含 `DesktopSftpController`）、`MonitorApp`、`EditorApp`、`TaskManagerApp`。
- [x] `DesktopLayoutStore`：按 host 还原/防抖保存（归一化坐标）。
- [x] 掉线浮层 + 资源回收（关窗/关标签/退桌面/掉线四处）。
- **验收**：连服务器 -> 切桌面 -> 开多终端、开文件管理器（独立目录）、拖拽上传、双击用编辑器窗口打开、开监控窗口；关窗/最小/最大化/聚焦 z 序；退出再重连窗口布局自动还原；切回终端模式 AI 恢复。

### 阶段 2 · 浏览器窗口（方案 B 网关为主）
- [x] `BrowserGateway`：`HttpServer` + token + Host 校验 + `forwardLocal` 透传 + URL 改写（Location/Set-Cookie/HTML href/src/CSS url）+ `Accept-Encoding: identity`。
- [x] WebSocket 升级裸字节隧道；HTTPS 远端经 `SecureSocket(onBadCertificate)`。
- [x] `BrowserApp`：`InAppWebView`、地址栏、前进/后退/刷新、网关/直连模式切换、书签。
- [x] `LocalPortForwarder`（方案 A 兜底）：`ServerSocket` + `forwardLocal` + `client.done` 自动停。
- [x] 网关/转发随窗口与连接回收；启动器已启用浏览器入口。
- **验收**：输入 `localhost:3000` -> 网关打开远端站点；点站内链接可漫游到其他内部端口/主机；HTTP/HTTPS(自签) 均可；`ws://` 站点可用；断线后网关停、重连后重建；切「直连端口」可按端口直转。

### 阶段 3 · 增强
- [x] 窗口贴边分屏（`tile`）、拖拽边缘吸附、标题栏右键/分屏菜单。
- [x] 网关健壮性：JS 动态 URL 提示（含 fetch/XHR shim）、压缩禁用、分块解析、大文件流式、超时与 HTML 错误页。
- [x] 可选重构 `RemoteSession`（§7.3）；多 SFTP 子系统。
- [x] 书签/历史管理 UI；桌面快捷方式（含任务管理器 / 编辑器）。
- [x] 任务管理器三页签 + Windows 性能 CIM 采样。
- [x] 编辑器未保存关闭确认；Windows 绝对路径；浏览器收藏切换 / 外开 / 直连确认。
- [x] GPU（nvidia-smi）接入监控 / 任务管理器性能页。
- [x] 日志 / 容器 / 磁盘占用 / 传输等桌面应用。
- [x] 监控窗口「网络」页：网卡吞吐、监听端口、TCP 摘要（`remote_network.dart`）。
- [x] 任务管理器第四页「网络」+ 性能页磁盘挂载/主机信息。
- [x] 日志查看器：journalctl / Windows 事件日志 / 文件 tail（`remote_logs.dart` + LogsApp）。
- [x] 容器管理：Docker 列表/启停/资源（`remote_containers.dart` + ContainersApp）。

---

## 11. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 抽取 `TerminalSurface`/`SftpBrowser`/`SftpBrowserHost` 改动面大，可能回归 | 高 | 阶段 0 独立验收；终端模式逐项回归（选择/拖选/拖出/上传/编辑/断线重连/状态栏/助手）。 |
| **方案 B 网关 URL 改写复杂**（绝对 URL、JS 动态拼 URL、压缩/分块、HTTP/2 远端） | 高 | 阶段 2 重点；先支持相对 URL + 常见绝对 URL 改写；`Accept-Encoding: identity` 简化 body；JS 动态 URL 不可覆盖时切「直连端口」兜底；HTTP/2 远端可能失败，记为已知限制。 |
| `flutter_inappwebview` 桌面端成熟度 | 中 | 先做 macOS/Windows 冒烟（证书放行/导航/Cookie/`ws://`）；保留「外部浏览器打开」兜底按钮。 |
| 远端 HTTPS 自签证书 | 中 | 网关模式 webview 侧无证书问题；直连模式 `onReceivedServerTrustAuthRequest` 放行，UI 标注「内网自签」。 |
| 多 shell/网关/转发资源泄漏 | 中 | 关窗/关标签/退桌面/掉线四处统一回收；`BrowserGateway`/`LocalPortForwarder` 监听 `client.done`；`_teardownConnection` 追加清理。 |
| `forwardLocal` 误用（以为它是监听器） | 高（已确认） | 直连模式（A）必须自起 `ServerSocket`，每连接一条 `forwardLocal` 通道；网关模式（B）每请求一条 `forwardLocal` 通道。代码注释写明。 |
| 布局持久化跨分辨率/DPI 失配 | 中 | 坐标归一化 0..1 存储；还原按当前 `desktopSize` clamp 进可视区；JSON 损坏静默丢弃。 |
| 共享 `SftpClient` 并发（多文件管理器窗口） | 中 | `DesktopSftpController` 各持独立 cwd/entries，共享 `sftp`（stateless listdir 可管道化）；并发传输若出问题，开第二个 sftp 子系统。 |
| DNS rebinding / 本地其他程序访问网关 | 中 | 网关仅 bind `127.0.0.1` + 每请求 token 校验 + `Host` 头校验。 |

---

## 12. 已确认决策（原待确认问题）

1. **桌面入口**：每标签一个模式开关（标签栏）。✅
2. **侧栏/AI 在桌面模式下**：AI 助手不保留（完全隐藏）；侧栏收成图标条可召回文件管理器。✅
3. **浏览器方案**：直接规划方案 B（HTTP 网关）为默认；方案 A 作为窗口内「直连端口」兜底。✅
4. **窗口布局持久化**：按 host 持久化（归一化坐标），重连/重开还原。✅
5. **监控/编辑器窗口**：纳入第一期 MVP。✅
