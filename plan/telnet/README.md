# 多协议终端支持：Telnet + 串口 + 全量桌面（详细施工方案）

> 写在 2026-08-10。当前应用为**纯 SSH 客户端**（`dartssh2` + `xterm`）。本方案在不动 SSH 体验的前提下，新增 **Telnet（RFC 854）** 与 **串口（Serial）** 两种传输，抽象出**能力接口族**，并**尽力全量支持桌面模式**--靠 `ShellExecEmulator`（shell 注入 + 哨兵捕获）让 exec 类应用在无 exec 通道的协议上降级可用；SFTP/端口转发类应用确属协议层不可能，明示不支持。
>
> **核心判断：** 终端渲染层 `TerminalSurface` 已声明不依赖 `SshWorkspaceController`；`SftpBrowserHost` 已是现成的「文件能力」接口；`SshWorkspaceController extends ChangeNotifier implements SftpBrowserHost` 已确立「接口按能力分离」的模式。本方案把该模式推广为**能力接口族**（终端会话 / exec / 文件 / 转发），各协议控制器按自身能力组合实现，桌面应用按能力查询并降级。
>
> **实现状态 2026-08-10：** T1–T7 主路径已落地（`dart analyze lib` 无 error）。三协议连接表单、桌面能力过滤、Telnet 第二连接 exec 仿真、Serial 主连接尽力而为、SOCKS5/HTTP 代理均可用。

---

## 0. 方案总览

| 优先级 | 工作流 | 目标 | 本代交付 |
|--------|--------|------|----------|
| **P0** | T1 - 能力接口抽象 | 抽出 `TerminalSessionController` + `RemoteExecCapable` + `RemoteForwardCapable`；SSH 改造实现三接口 | 接口族 + SSH 改造 + 编译通过 |
| **P0** | T2 - Telnet 传输层 | `dart:io` Socket + IAC 协商 + 字符集；`TelnetWorkspaceController` 实现 `TerminalSessionController`+`RemoteExecCapable` | Telnet 连通 |
| **P0** | T2' - 串口传输层 | `flutter_libserialport` + 字符集；`SerialWorkspaceController` 实现 `TerminalSessionController`+`RemoteExecCapable` | 串口连通 |
| **P0** | T3 - 数据模型 + 连接 UI | `ConnectionProtocol{ssh,telnet,serial}` + `SerialConfig` + 连接表单三协议切换 | 迁移 + 表单 + 落盘 |
| **P0** | T4 - ShellExecEmulator | 在 Telnet(第二连接)/Serial(主连接) 上仿真 exec，喂给 `RemoteStream`/`runQueued` | exec 类桌面应用降级可用 |
| **P1** | T5 - 全量桌面 + 逐应用矩阵 | 桌面层接口化 + 注册表按能力过滤；16 应用逐个兼容矩阵；不能的明示 | 桌面尽量全量 |
| **P1** | T6 - 代理 / 跳板 | Telnet/Serial 复用 SOCKS5/HTTP；跳板仅 SSH | 代理分支 |
| **P2** | T7 - 增强 | 字符集运行时切换、登录注入、IAC/串口调试日志、ZMODEM 透传 | 体验完善 |

**预估：新建 ~12 文件，修改 ~18 文件。新增依赖 1 个：`flutter_libserialport`（串口，桌面三平台）。**

---

## 1. 现状评估

| 模块 | 文件 | 现状 | 多协议影响 |
|------|------|------|-----------|
| 终端渲染 | `lib/widgets/terminal_surface.dart` | **已解耦**：入参 xterm `Terminal` + 布尔状态，注释「不依赖 `SshWorkspaceController`」 | ✅ 无需改 |
| 会话面板 | `lib/widgets/session_workspace.dart` | `SessionTerminalPane` 持具体 `SshWorkspaceController` | ⚠️ 改接口类型 + SFTP 侧栏门控 |
| 分屏树 | `lib/services/session_pane.dart` | `SessionPaneLeaf.controller` 为具体 `SshWorkspaceController` | ⚠️ 改接口类型 |
| SSH 控制器 | `lib/services/ssh_workspace_controller.dart` (2351 行) | `extends ChangeNotifier implements SftpBrowserHost`；含 exec(`runQueued`/`startRemoteStream`/`snapshot`)、SFTP、转发、sudo、录制、cwd | ⚠️ 增 `implements TerminalSessionController, RemoteExecCapable, RemoteForwardCapable` |
| 标签/生成 | `lib/services/session_tabs_controller.dart` | `_spawnController`/`openTab` 直接 `new SshWorkspaceController`，**唯一生成点** | ⚠️ 按协议分支 |
| exec 抽象 | `lib/services/remote_stream.dart` | `RemoteStream` 绑 `SSHSession`/`client.execute` | ⚠️ 解耦为通用字节源，供仿真器喂数据 |
| 主机指标 | `lib/services/remote_host_metrics.dart` / `remote_process_list.dart` | `RemoteHostSnapshot`/`RemoteOsKind`，exec 采集 | ✅ 复用（数据型，与传输无关） |
| 文件能力接口 | `lib/services/sftp_browser_host.dart` | `abstract class SftpBrowserHost`（sftp/remoteCwd/entries/读写/上传下载）已存在 | ✅ 作为「文件能力」接口保留，SSH-only |
| 桌面视图 | `lib/desktop/remote_desktop_view.dart` + `apps/*.dart` | 持一个 `SshWorkspaceController`，按 `DesktopAppType` switch 构建 16 应用，**每个都收 `controller:` 具体类型** | ⚠️ 控制器改接口；注册表加能力过滤；逐应用门控 |
| 桌面副终端 | `lib/services/remote_shell.dart` | `RemoteShell.open(SSHClient)` 开独立 SSH PTY | ⚠️ Telnet 需 `TelnetRemoteShell`；Serial 无副终端 |
| 桌面浏览器 | `lib/desktop/apps/browser_app.dart` | SSH 本地端口转发（`openLocalForward`/`getOrCreateGateway`） | ⚠️ 无转发能力时退化为直连浏览 |
| 主机配置模型 | `lib/models/saved_host_profile.dart` | SSH-only：无 `protocol`，`port` 默认 22 | ⚠️ 加 `protocol` + `serialConfig` |
| 代理配置 | `lib/models/proxy_config.dart` | `ProxyType { sshJump, sshTunnel, socks5, http }` | ✅ `socks5`/`http` 可用于 Telnet/Serial |
| 连接表单 | `lib/widgets/connection_sheet.dart` | label/host/port(22)/user/sshPassword/keyPassphrase/keyPath/connectTimeout + 认证方式 | ⚠️ 三协议切换 + 串口专属字段 |
| 依赖 | `pubspec.yaml` | `dartssh2`、`xterm`、`charset` | ➕ `flutter_libserialport` |

---

## 2. 关键架构决策

### 2.1 三协议能力矩阵

| 能力 | SSH | Telnet | Serial |
|------|-----|--------|--------|
| 终端 shell（PTY） | ✅ `client.shell()` | ✅ TCP + IAC | ✅ 串口字节流 |
| 独立 exec 通道 | ✅ `client.execute()` | ❌（仿真，见 §2.3） | ❌（仿真） |
| 多连接（副终端/exec 后台） | ✅ 多 channel | ✅ 多 TCP 连接 | ❌ 单端口单流 |
| 文件传输/浏览（SFTP） | ✅ | ❌ 协议层无 | ❌ 协议层无 |
| 端口转发 | ✅ | ❌ | ❌ |
| 私钥认证 | ✅ | ❌ | ❌ |
| 代理（SOCKS5/HTTP） | ✅ | ✅ | N/A（本地设备） |
| 跳板机 | ✅ | ❌ | ❌ |
| 字符集 | UTF-8（强制） | 用户可选 | 用户可选（常 raw/Latin-1） |

### 2.2 能力接口族

沿用「接口按能力分离」模式，定义四个接口。各协议控制器按能力组合实现：

```dart
enum RemoteCapability { terminal, exec, file, forward }

/// 终端会话契约（三协议必备）。
abstract class TerminalSessionController extends ChangeNotifier {
  ConnectionProtocol get protocol;
  String get host;          // serial: 端口名/描述
  int get port;             // serial: 波特率（复用），无网络端口时 0
  String get username;      // serial: ''
  Set<RemoteCapability> get capabilities;

  Terminal? get terminal;
  bool get connecting;
  bool get connected;
  bool get dropped;
  String? get error;
  String get terminalCwd;
  bool get mouseModeActive;

  SessionRecorder? get sessionRecorder;
  bool get isSessionRecording;
  void startSessionRecording();
  void stopSessionRecording();
  void toggleSessionRecording();

  Future<void> connect();
  Future<void> disconnect();
  Future<void> reconnect();

  void pasteRemoteInput(String text);
  String pasteRemoteInputWithLineSubmit(String text);
  String snapshotTerminalTail({int maxLines = 120, int maxChars = 24000});
  void injectTerminalLocalDisplay(String text);

  /// 开一个独立副终端（桌面多终端窗口）。不支持时返回 null（Serial）。
  Future<RemoteShell?> openSecondaryShell();

  @override
  void dispose();
}

/// 远程命令执行能力。SSH 原生 exec；Telnet/Serial 经 ShellExecEmulator 实现。
abstract class RemoteExecCapable {
  Future<String?> runQueued(String command, {Duration timeout = const Duration(seconds: 15), List<int>? stdinBytes});
  String? get lastRemoteCommandError;
  Future<RemoteStream> startRemoteStream(String command, {int maxLines = 5000, List<int>? stdinBytes});
  void unregisterRemoteStream(RemoteStream stream);
  Future<RemoteHostSnapshot?> snapshot({Duration maxAge = const Duration(seconds: 3), RemoteOsKind? osHint});
  String get remoteCwd;   // SSH: SFTP；Telnet/Serial: 经 exec 跑 pwd
}

/// 端口转发能力（仅 SSH）。
abstract class RemoteForwardCapable {
  Future<LocalPortForwarder> openLocalForward(String remoteHost, int remotePort);
  Future<void> releaseLocalForward(LocalPortForwarder? fwd);
  Future<BrowserGateway> getOrCreateGateway();
  List<LocalPortForwarder> get desktopForwards;
}

/// 文件能力 = 现有 SftpBrowserHost（SSH-only，保持不变）。Telnet/Serial 不实现。
```

各控制器实现：
```dart
class SshWorkspaceController extends ChangeNotifier
    implements TerminalSessionController, RemoteExecCapable, RemoteForwardCapable, SftpBrowserHost {
  // capabilities = {terminal, exec, file, forward}
}

class TelnetWorkspaceController extends ChangeNotifier
    implements TerminalSessionController, RemoteExecCapable {
  // capabilities = {terminal, exec}；exec 经 ShellExecEmulator（第二连接，不可见）
}

class SerialWorkspaceController extends ChangeNotifier
    implements TerminalSessionController, RemoteExecCapable {
  // capabilities = {terminal, exec}；exec 经 ShellExecEmulator（主连接，输出可见/尽力而为）
}
```

桌面应用按能力查询：`if (c is RemoteExecCapable)` / `if (c is SftpBrowserHost)` / `if (c is RemoteForwardCapable)`，或读 `c.capabilities`。

### 2.3 ShellExecEmulator -- 全量桌面的关键

Telnet/Serial 没有 exec 通道。为让 monitor/logs/runCommand 等 11 个 exec 类桌面应用降级可用，新增 `ShellExecEmulator`：**通过 shell 注入命令 + 哨兵标记捕获 stdout 与退出码**，产出与 SSH exec 等价的 `runQueued`/`RemoteStream`。

```dart
/// 在无 exec 通道的协议上仿真 exec。
/// 后端为一个独立的字节流 shell（Telnet 第二连接；Serial 主连接）。
class ShellExecEmulator {
  ShellExecEmulator(this._backend);  // ShellBackend: 发字节 + 收字节流
  final ShellBackend _backend;
  final Codec<String, List<int>> _codec;

  /// 一次性命令：注入哨兵 + 命令 + 退出码回显，捕获区间内 stdout。
  Future<String?> run(String command, {Duration timeout = const Duration(seconds: 15), List<int>? stdinBytes}) async {
    final id = _shortId();                 // 无 Math.random：用计数器/时间戳传入
    final begin = '\x01B$id\x01';          // 哨兵：SOH + id + SOH（低碰撞且易剥离）
    final end = '\x01E$id\x01';
    // 发送：  printf '%s' '<begin>'; <command>; printf '\n%s:%s\n' '<end>' "$?"
    // 读取 backend 输出流，定位 begin 之后、end 之前的内容 = stdout；end:N 的 N = 退出码
    // 剥离 ANSI 转义与命令回显；超时返回 null，置 lastError
  }

  /// 流式命令：发送命令，把 backend 输出作为 RemoteStream 行流返回；停止时发 0x03(Ctrl-C)。
  RemoteStream startStream(String command, {int maxLines = 5000, List<int>? stdinBytes}) {
    // backend 输出（去哨兵/回显）逐行喂入 RemoteStream；stop() -> 发 Ctrl-C
  }

  String? get lastError;
}
```

**关键点：**
- **Telnet 用第二连接**：`TelnetWorkspaceController` 懒开第二条 TCP+IAC 连接作为 `_execBackend`，对用户主终端**不可见**。exec 类应用输出干净，与 SSH 体验接近。
- **Serial 用主连接**：串口单端口单流，仿真必须复用主终端流--命令与输出**会出现在用户主控台**。故 Serial 的**流式 exec**（logs/runCommand，用户本就期望看到输出）自然可用；**结构化 exec**（monitor/cron/users/packages/firewall/diskUsage/containers/tasks，靠解析 stdout）标记为**尽力而为、会污染主控台**（见 §5 矩阵）。
- `RemoteStream` 解耦：现有 `RemoteStream` 绑 `SSHSession`/`client.execute`。重构为接受**通用字节源** `Stream<List<int>>` + 可选 stdin sink + 完成/退出码 Future；SSH 路径用 `client.execute` 构造，仿真路径用 `ShellExecEmulator` 构造。`_lines`/`_exitCode`/maxLines 逻辑零改动复用。

### 2.4 终端 I/O 映射（三协议同形）

三协议都把字节流接到同一个 xterm `Terminal(onOutput/onResize)`：

| | 用户击键 -> 远端 | 远端 -> 终端 | resize |
|---|---|---|---|
| SSH | `_shell.write(utf8.encode(data))` | `session.stdout` -> utf8.decode -> PtyInterceptor -> TermWriteBatcher | `_shell.resizeTerminal` |
| Telnet | `_socket.add(codec.encode(data))` | `socket` -> **IAC 剥离** -> codec.decode -> PtyInterceptor -> TermWriteBatcher | `negotiator.sendNaws` |
| Serial | `_port.write(codec.encode(data))` | `portReader` -> codec.decode -> PtyInterceptor -> TermWriteBatcher | （无 NAWS；发 `stty rows/cols` 经 exec，尽力而为） |

> `PtyInterceptor`（OSC7/cwd/mouse）、`TermWriteBatcher`（分片写入）、`SessionRecorder`（录制/回放）、命令历史、终端搜索 -- **三协议零改动复用**。

### 2.5 串口选型

新增依赖 `flutter_libserialport`（jpnurmi，封装 libserialport，支持 macOS/Windows/Linux）。API：`SerialPort(name)`、`SerialPort.availablePorts`、`port.config.{baudRate,bits,parity,stopBits}`、`SerialPortReader`。

> 实施前需联网核对版本与平台构建（本次环境 pub.dev 不可达）。串口访问封装在 `SerialTransport` 接口后，便于后续替换实现（如 `serial_port_win32` 等备选）。Web 不支持串口--应用为桌面端，非目标平台。

---

## 3. 协议层设计

### 3.1 Telnet IAC 协商器 `TelnetNegotiator`

新建 `lib/services/telnet/telnet_negotiator.dart`（RFC 854）。

```dart
class TelnetCommand { static const iac=255, dont=254, do_=253, wont=252, will=251, sb=250, se=240; }
class TelnetOption { static const echo=1, suppressGoAhead=3, status=5, terminalType=24, naws=31, terminalSpeed=32, linemode=34, newEnviron=39; }
```

**`feed(List<int> bytes) -> List<int>`**：状态机扫描，剥离 IAC 序列并就地应答，返回纯显示数据。**`sendNaws(w,h)`** 发 NAWS 子协商（0xff 转 `IAC IAC`）。

**默认协商策略（保守，兼容 BBS/路由器/老旧主机）：**

| 选项 | 策略 |
|------|------|
| ECHO (1) | 服务端 WILL ECHO -> 我方 DO；服务端 DO ECHO -> 我方 WONT（让服务端回显，避免双回显） |
| SUPPRESS_GO_AHEAD (3) | 我方 WILL；服务端 WILL -> 我方 DO |
| TERMINAL_TYPE (24) | 服务端 DO -> 我方 WILL；`SB SEND` -> 回 `IS <settings.terminalTermType>` |
| NAWS (31) | 我方 WILL；连接 + 每次 resize 发 `SB NAWS w h` |
| 其余 | 一律 WONT / DONT |

### 3.2 字符集 `TelnetCharset`（Telnet/Serial 共用）

新建 `lib/services/terminal_charset.dart`，基于 `charset` 包：
```dart
enum TerminalEncoding { utf8, gbk, big5, latin1, shiftJis }
// 默认 utf8（allowMalformed）。中文 BBS 常需 gbk/big5；串口设备常 latin1/raw。
```
Telnet/Serial 都用此选择；SSH 强制 UTF-8。

### 3.3 串口传输层 `SerialTransport`

新建 `lib/services/serial/serial_transport.dart`，封装 `flutter_libserialport`：
```dart
class SerialTransport {
  static Future<List<String>> availablePorts();          // 枚举端口名
  Future<void> open(SerialPortConfig cfg);               // 打开 + 应用波特率/数据位/校验/停止位/流控
  Stream<Uint8List> get input;                           // 读取流
  void add(List<int> bytes);                             // 写入
  Future<void> close();
}
class SerialPortConfig { String name; int baudRate; int dataBits; SerialParity parity; int stopBits; SerialFlowControl flowControl; }
```
`SerialWorkspaceController` 经 `SerialTransport` 收发字节，接线与 Telnet 相同（无 IAC）。

### 3.4 登录凭据注入（Telnet）

Telnet 无标准化认证--服务端发 `login:`/`Password:` 提示。若用户填了凭据，匹配提示后自动注入（`\r` 结尾），密码掩码记录；未填则纯透传。提供「自动注入」开关，默认开。Serial 通常无登录提示（直连设备控制台），不注入。

---

## 4. 数据模型变更

### 4.1 `ConnectionProtocol` 三值

新建 `lib/models/connection_protocol.dart`：
```dart
enum ConnectionProtocol {
  ssh, telnet, serial;
  int get defaultPort => switch (this) { ssh => 22, telnet => 23, serial => 0 };
  bool get supportsPrivateKey => this == ssh;
  bool get supportsSftp => this == ssh;
  bool get supportsForward => this == ssh;
  bool get supportsProxyJump => this == ssh;
  bool get supportsTcpProxy => this != serial;        // socks5/http；serial 是本地设备
  bool get supportsSecondaryShell => this != serial;  // serial 单端口单流
  bool get supportsIac => this == telnet;
  String get displayName => switch (this) { ssh => 'SSH', telnet => 'Telnet', serial => 'Serial' };
}
```

### 4.2 `SavedHostProfile` 增字段

```dart
class SavedHostProfile {
  final ConnectionProtocol protocol;       // 默认 ssh
  final SerialPortConfig? serialConfig;    // serial 专属：端口名/波特率/数据位/校验/停止位/流控
  final TerminalEncoding? encoding;        // telnet/serial 字符集
  // host/port/username/password/keyPath：serial 时 host=端口名、port=波特率、username/password 可空
  // toJson/fromJson：protocol ?? ssh；serialConfig 可选；旧 JSON 零破坏
}
```

> 复用 `host`/`port` 字段承载串口「端口名/波特率」，避免模型分裂；`subtitle` 按协议渲染（serial 显示 `COM3@115200` 而非 `user@host:port`）。

### 4.3 `HostProfilesStore` / 会话快照

- `upsert/update` 透传 `protocol`/`serialConfig`/`encoding`。
- `session_snapshot.dart` 的 `TabSnapshot`/`PaneSnapshot` 增 `protocol` + `serialConfig`，恢复时按协议生成控制器。

---

## 5. 工作流 T1（P0）：能力接口抽象

**目标：** 抽出三接口，SSH `implements` 之，终端模式链路换接口类型，全工程编译通过、SSH 零回归。

1. 新建 `lib/services/terminal_session_controller.dart`（§2.2）。
2. 新建 `lib/services/remote_exec_capable.dart`、`lib/services/remote_forward_capable.dart`。
3. `SshWorkspaceController` 增 `implements TerminalSessionController, RemoteExecCapable, RemoteForwardCapable` + `protocol`/`capabilities`/`openSecondaryShell()` getter；现有方法补 `@override`。SSH-only 成员（`sftp`/`uploadTasks`/`clientForDesktop`/sudo）留自身。
4. `SessionPaneLeaf.controller` / `SessionTerminalPane.controller` / `openTab` / `_spawnController` / `main_shell_screen` 调用点 -> `TerminalSessionController`。SSH-only 后续操作用 `is SshWorkspaceController`/`is SftpBrowserHost` 保护。

**验收：** `dart analyze lib` 无 error；SSH 全功能不变。

---

## 6. 工作流 T2/T2'（P0）：Telnet + 串口传输层

### 6.1 文件结构
```
lib/services/telnet/{telnet_negotiator.dart, telnet_login_matcher.dart, telnet_remote_shell.dart}
lib/services/serial/{serial_transport.dart}
lib/services/{telnet_workspace_controller.dart, serial_workspace_controller.dart, shell_exec_emulator.dart, terminal_charset.dart}
```

### 6.2 `TelnetWorkspaceController`（`implements TerminalSessionController, RemoteExecCapable`）

- `connect()`：经 `ProxyConnector.openTcpViaProxy`（SOCKS5/HTTP，可选）或 `Socket.connect` 建立 TCP；建 `TelnetNegotiator`；`_initTerminal` + `_wireSocket`（§2.4）。
- exec：懒开**第二连接** `_execBackend`（独立 `TelnetNegotiator`+socket，对主终端不可见），构造 `ShellExecEmulator`；`runQueued`/`startRemoteStream`/`snapshot`/`remoteCwd` 转发之。
- `openSecondaryShell()`：开第三连接包成 `TelnetRemoteShell`（桌面副终端）。
- 生命周期/断线/重连：`socket.onDone/onError` -> `dropped` + 浮层 + `reconnect()`，复用 SSH 的 `keepTerminal` 语义。

### 6.3 `SerialWorkspaceController`（`implements TerminalSessionController, RemoteExecCapable`）

- `connect()`：`SerialTransport.open(serialConfig)`；`_initTerminal` + `_wirePort`（§2.4，无 IAC）。
- exec：`ShellExecEmulator` 复用**主连接**字节流；`runQueued`/`startRemoteStream` 可用但输出出现在主控台（结构化解析尽力而为）。
- `openSecondaryShell()`：返回 `null`（串口单流，无副终端）。桌面终端窗口强制 `usePrimary`。
- resize：无 NAWS；尝试经 exec 发 `stty rows R cols C`（尽力而为）。
- 断线：端口关闭/错误 -> `dropped` + 重连。

### 6.4 `RemoteStream` 解耦

`remote_stream.dart`：构造改为接受 `Stream<List<int>> stdout` + `Stream<List<int>>? stderr` + `Future<int?> exitCode` + 可选 `stdin` sink + `cancel()`。`SSHSession` 路径与 `ShellExecEmulator` 路径各自适配。`_lines`/`_exitCode`/maxLines/`waitUntilClosed` 零改动。

### 6.5 验收
- Telnet 连公网 BBS/路由器：IAC 协商、回显、resize(NAWS)、断线重连、exec 类桌面应用经第二连接正常取数
- 串口连设备控制台：收发正常、字符集正确、logs/runCommand 流式可用、断线重连

---

## 7. 工作流 T3（P0）：数据模型 + 连接 UI

### 7.1 连接表单三协议切换

`connection_sheet.dart` 顶部协议选择器（SSH / Telnet / Serial），切换时字段联动：

| 字段 | SSH | Telnet | Serial |
|------|-----|--------|--------|
| host/IP | ✅ | ✅ | → 端口名下拉（枚举 `availablePorts`） |
| port | ✅ 默认 22 | ✅ 默认 23 | → 波特率下拉（9600/115200/…） |
| username | ✅ | 可选 | 隐藏 |
| 认证方式（密码/私钥） | ✅ | 隐藏 | 隐藏 |
| 私钥路径/口令 | ✅ | 隐藏 | 隐藏 |
| 字符集 | 隐藏(UTF-8) | ✅ | ✅ |
| 串口参数（数据位/校验/停止位/流控） | 隐藏 | 隐藏 | ✅ |
| 自动注入登录凭据 | 隐藏 | ✅ | 隐藏 |
| 代理（socks5/http/跳板） | ✅ 全部 | socks5/http | 隐藏 |

### 7.2 `openTab` 签名扩展
```dart
TerminalSessionController openTab({
  required ConnectionProtocol protocol,
  required String host, required int port, required String username, required String password,
  String? privateKeyPem, ProxyConfig? proxyConfig,
  TerminalEncoding? encoding, SerialPortConfig? serialConfig,
  bool autoInjectCredentials = true,
  int? connectTimeoutSec, String? savedProfileId, bool bypassDebounce = false, bool connect = true,
});
```
`_spawnController` 按 `protocol` 分支：ssh->`SshWorkspaceController`，telnet->`TelnetWorkspaceController`，serial->`SerialWorkspaceController`。

### 7.3 l10n 新增键
协议名、串口参数、字符集、自动注入、断线/不支持文案（略）。

### 7.4 验收
- 三协议新建/保存/侧栏一键连接，参数持久化；存量 SSH 配置默认 ssh、字段不变

---

## 8. 工作流 T4（P0）：ShellExecEmulator

**目标：** 让 exec 类桌面应用在 Telnet/Serial 降级可用。详见 §2.3。

1. 新建 `lib/services/shell_exec_emulator.dart`（`run`/`startStream`/哨兵捕获/ANSI 剥离/超时/`lastError`）。
2. `RemoteStream` 解耦（§6.4）。
3. `TelnetWorkspaceController`/`SerialWorkspaceController` 实现 `RemoteExecCapable`，转发到各自 `ShellExecEmulator`。
4. `remoteCwd`：SSH 用 SFTP `absolute('.')`；Telnet/Serial 经 `run('pwd')`。
5. `snapshot()`：复用 `remote_host_metrics` 采集逻辑（基于 `runQueued` 跑 `/proc`/`vmstat`/`ps`），协议无关。

**验收：** Telnet 第二连接 exec 干净；Serial 主连接 exec 可见但可用；monitor/tasks/logs/runCommand 在 Telnet 取数正确，Serial 流式可用、结构化尽力而为。

---

## 9. 工作流 T5（P1）：全量桌面 + 逐应用兼容矩阵

**目标：** 桌面层接口化 + 注册表按能力过滤，**16 应用逐个给出去留**，不能的明示。

### 9.1 桌面层改造

- `RemoteDesktopView.controller` -> `TerminalSessionController`；据 `controller.capabilities` 决定可用应用集。
- `desktop_app_registry.dart`：`AppMeta` 增 `Set<RemoteCapability> needs`；新增 `appsForCapabilities(Set caps)`。
- 启动器/任务栏只列 `appsForCapabilities(controller.capabilities)`；不满足的应用隐藏，tooltip 标原因。
- 各应用控制器类型 -> `TerminalSessionController`；按需 `is RemoteExecCapable`/`is SftpBrowserHost`/`is RemoteForwardCapable` 取能力；不满足则该应用不注册。
- `terminal_app`：SSH 走 `RemoteShell`，Telnet 走 `TelnetRemoteShell`，Serial `openSecondaryShell()==null` -> 强制 `usePrimary`。
- `browser_app`：`is RemoteForwardCapable` -> 走转发访问远端服务；否则退化为**直连浏览**（仅公网可达 URL）。

### 9.2 逐应用兼容矩阵（诚实标注）

| 应用 | 所需能力 | SSH | Telnet | Serial | 说明 |
|------|----------|-----|--------|--------|------|
| terminal | terminal | ✅ | ✅ | ✅ 仅主终端 | Serial 无副终端窗口 |
| logs | exec(stream) | ✅ 原生 | ✅ 仿真(第二连接) | ✅ 仿真(主连接) | `tail -f`/`journalctl`，流式天然适配 |
| runCommand | exec(stream) | ✅ | ✅ 仿真 | ✅ 仿真 | 用户主动命令，输出可见合理 |
| monitor | exec(struct) | ✅ 原生 | ✅ 仿真(干净) | ⚠️ 仿真尽力而为 | Serial 输出污染主控台，解析可能受干扰 |
| tasks | exec(struct) | ✅ | ✅ 仿真 | ⚠️ 尽力而为 | 同上 |
| diskUsage | exec(struct)+remoteCwd | ✅ | ✅ 仿真 | ⚠️ 尽力而为 | 同上 |
| containers | exec(struct) | ✅ | ✅ 仿真 | ⚠️ 尽力而为 | 同上 |
| cron | exec(struct,解析) | ✅ | ✅ 仿真 | ⚠️ 尽力而为 | 靠解析 crontab 输出 |
| users | exec(struct,解析) | ✅ | ✅ 仿真 | ⚠️ 尽力而为 | 解析 getent/passwd |
| packages | exec(struct) | ✅ | ✅ 仿真 | ⚠️ 尽力而为 | apt/dnf 查询 |
| firewall | exec(struct) | ✅ | ✅ 仿真 | ⚠️ 尽力而为 | iptables/ufw 查询 |
| browser | forward | ✅ 转发 | ⚠️ 直连浏览 | ⚠️ 直连浏览 | 无转发能力时仅公网 URL |
| files | file(SFTP) | ✅ | ❌ 不支持 | ❌ 不支持 | Telnet/Serial 无 SFTP；ZMODEM 仅整文件透传(T7) |
| editor | file(SFTP) | ✅ | ❌ 不支持 | ❌ 不支持 | 同上 |
| transfers | file(SFTP) | ✅ | ❌ 不支持 | ❌ 不支持 | 同上 |
| forwards | forward | ✅ | ❌ 不支持 | ❌ 不支持 | 端口转发对 Telnet/Serial 无意义 |

### 9.3 明确不支持（协议层不可能，诚实说明）

- **files / editor / transfers（SFTP 文件浏览与编辑）**：Telnet/Serial 协议层无目录列表与随机读写。ZMODEM（T7）仅能在终端里整文件收发，**不能**支撑文件管理器/编辑器的浏览与在线编辑，故这三个应用在 Telnet/Serial **隐藏**。
- **forwards（端口转发管理）**：端口转发是 SSH 隧道能力，Telnet/Serial 无此概念，**隐藏**。
- **browser 的远端服务访问**：无转发能力时无法访问远端 `localhost` 服务，**降级为直连公网浏览**（非完全不支持）。
- **Serial 的结构化 exec**：单端口单流，仿真输出与用户主控台交织，monitor/cron/users/packages/firewall/diskUsage/containers/tasks 标记**尽力而为**（可用但可能受干扰），非完全不可用。

### 9.4 终端模式侧栏门控

| 能力 | SSH | Telnet/Serial | 门控 |
|------|-----|---------------|------|
| 文件浏览器侧栏（SFTP） | ✅ | 隐藏，终端区占满 | `is SftpBrowserHost` |
| 健康面板（远程指标） | ✅ exec | ✅(Telnet)/⚠️(Serial) | `is RemoteExecCapable` |
| sudo 缓存 / 特权流式操作 | ✅ | 隐藏 | `is SshWorkspaceController` |
| 批量执行 / 代码片段 | ✅ exec | 降级为终端注入 | `is RemoteExecCapable` 走 exec，否则注入 |
| 桌面模式切换 | ✅ | ✅（全量桌面，按能力过滤应用） | 始终允许，应用集随协议变化 |

### 9.5 验收
- SSH 桌面 16 应用全可用，零回归
- Telnet 桌面：terminal/logs/runCommand/monitor/tasks/diskUsage/containers/cron/users/packages/firewall 可用，browser 直连，files/editor/transfers/forwards 隐藏
- Serial 桌面：terminal/logs/runCommand 可用，结构化 exec 应用尽力而为，文件/转发类隐藏
- 无 `cast` 异常；不满足能力的应用在启动器隐藏并带 tooltip

---

## 10. 工作流 T6（P1）：代理 / 跳板

- `ProxyConnector.openTcpViaProxy(proxy, targetHost, targetPort)`：SOCKS5（RFC 1928）/ HTTP CONNECT，返回 `Socket`，供 Telnet 使用（Serial 不用）。
- `sshJump`/`sshTunnel` 仅 SSH；连接表单 Telnet 代理类型只列 socks5/http，Serial 无代理。
- 现有 `ProxyConnector.openForwardedSocket`（SSH 跳板转发）并存。

---

## 11. 工作流 T7（P2）：增强

- 字符集运行时切换（终端工具栏下拉，Telnet/Serial）
- 登录凭据注入开关（Telnet）
- IAC / 串口帧调试日志（写入 `SessionRecorder`/控制台）
- **ZMODEM 透传**：在 Telnet/Serial 终端流上对 ZMODEM（sz/rz）做 IAC/0xff 转义透传，让用户在终端内整文件收发（**不**等于 SFTP 浏览，files/editor 仍隐藏）
- 终端类型可配（vt100/ansi/xterm-256color），复用 `settings.terminalTermType`

---

## 12. 文件清单

### 新建

| 文件 | 说明 |
|------|------|
| `lib/models/connection_protocol.dart` | 协议枚举 + 能力谓词 |
| `lib/models/serial_port_config.dart` | 串口参数模型 |
| `lib/services/terminal_session_controller.dart` | 终端会话接口 |
| `lib/services/remote_exec_capable.dart` | exec 能力接口 |
| `lib/services/remote_forward_capable.dart` | 转发能力接口 |
| `lib/services/shell_exec_emulator.dart` | exec 仿真（全量桌面关键） |
| `lib/services/terminal_charset.dart` | 字符集 Codec（Telnet/Serial） |
| `lib/services/telnet/telnet_negotiator.dart` | IAC 状态机 |
| `lib/services/telnet/telnet_login_matcher.dart` | login:/Password: 匹配注入 |
| `lib/services/telnet/telnet_remote_shell.dart` | Telnet 副终端 |
| `lib/services/serial/serial_transport.dart` | 串口封装 |
| `lib/services/telnet_workspace_controller.dart` | Telnet 控制器 |
| `lib/services/serial_workspace_controller.dart` | 串口控制器 |

### 修改

| 文件 | 改动 |
|------|------|
| `lib/models/saved_host_profile.dart` | `protocol`+`serialConfig`+`encoding` + 迁移 |
| `lib/models/session_snapshot.dart` | `TabSnapshot`/`PaneSnapshot` 增协议字段 |
| `lib/services/host_profiles_store.dart` | 透传新字段 |
| `lib/services/ssh_workspace_controller.dart` | `implements` 三接口 + `protocol`/`capabilities`/`openSecondaryShell` + `@override` |
| `lib/services/remote_stream.dart` | 解耦为通用字节源 |
| `lib/services/session_pane.dart` | `controller` -> 接口 |
| `lib/services/session_tabs_controller.dart` | `openTab`/`_spawnController` 三协议分支 |
| `lib/services/proxy_connector.dart` | `openTcpViaProxy` |
| `lib/widgets/session_workspace.dart` | 控制器接口化 + 侧栏门控 |
| `lib/widgets/connection_sheet.dart` | 三协议切换 + 条件字段 |
| `lib/screens/main_shell_screen.dart` | `openTab` 传协议；桌面/侧栏/菜单门控 |
| `lib/desktop/remote_desktop_view.dart` | 控制器接口化 + 按能力过滤应用 |
| `lib/desktop/desktop_app_registry.dart` | `AppMeta.needs` + `appsForCapabilities` |
| `lib/desktop/apps/*.dart`（16 应用） | 控制器接口化 + 按能力 `is` 取用 + 降级 |
| `lib/desktop/apps/terminal_app.dart` | 三协议副终端分支 |
| `lib/desktop/apps/browser_app.dart` | 无转发能力时退化直连 |
| `lib/services/bulk_command_executor.dart` | Telnet/Serial 降级为终端注入 |
| `lib/l10n/app_*.arb` + 生成 | 三协议/串口/字符集/不支持文案 |
| `pubspec.yaml` | `flutter_libserialport` |

---

## 13. 实施阶段

```
阶段 0  dart analyze 通过；记录 SSH 行为基准
阶段 1（T1 接口）  三接口 + SSH implements + 终端链路换类型
        ── 编译通过、SSH 零回归 ──
阶段 2（T2/T2' 传输） TelnetNegotiator/SerialTransport 单测
        TelnetWorkspaceController / SerialWorkspaceController（先不接 exec）
        ── 三协议终端均可连通 ──
阶段 3（T3 模型+UI） 协议枚举+SerialConfig+迁移；连接表单三协议；openTab 分支；l10n
        ── UI 可建/存/连三协议 ──
阶段 4（T4 仿真）   ShellExecEmulator + RemoteStream 解耦
        Telnet/Serial 实现 RemoteExecCapable
        ── exec 类桌面应用在 Telnet/Serial 降级可用 ──
阶段 5（T5 全量桌面） 桌面层接口化 + 注册表能力过滤 + 16 应用逐个门控/降级
        ── 三协议桌面按 §9.2 矩阵呈现 ──
阶段 6（T6 代理）   openTcpViaProxy；表单代理类型按协议过滤
阶段 7（T7 增强）   字符集运行时切换/登录注入/调试日志/ZMODEM 透传
```

**依赖：** T1 先行；T2/T2' 与 T3 可并行；T4 依赖 T2/T2'；T5 依赖 T1+T4；T6/T7 独立后置。

---

## 14. 非目标

- **不**实现 `telnets`（Telnet over TLS）/ SSH 证书登录
- **不**让 files/editor/transfers 在 Telnet/Serial 工作（协议层无 SFTP；ZMODEM 仅整文件透传，不支撑浏览/在线编辑）
- **不**让 forwards 在 Telnet/Serial 工作（无端口转发概念）
- **不**为 Serial 提供副终端窗口（单端口单流）
- **不**实现 RFC 2066 字符集协商（部署率极低，用用户显式选择）
- **不**改动 `TerminalSurface` 渲染层（已解耦）
- **不**支持 Web 端串口（桌面端专用）

---

## 15. 测试

**单元：** `TelnetNegotiator.feed`（IAC 各序列/转义/分片）、`sendNaws`（0xff 转义/大尺寸）、`ShellExecEmulator.run`（哨兵捕获/退出码/ANSI 剥离/超时/分片）、`TerminalCharset` 往返、`SerialPortConfig` 序列化、`SavedHostProfile` 旧 JSON 迁移、`appsForCapabilities` 过滤。

**Widget：** `connection_sheet` 三协议字段联动；`remote_desktop_view` 按能力过滤应用集。

**集成：** SSH 全功能回归；Telnet 连 BBS/路由器（协商/回显/resize/exec 仿真/断线重连）；Serial 连设备控制台（收发/字符集/流式 exec）；会话持久化三协议恢复。

**手工兼容矩阵：** Linux telnetd、中文 BBS(GBK)、网络设备控制台(Serial)、串口调试。

---

## 16. 风险

| 风险 | 缓解 |
|------|------|
| 接口抽取波及桌面 16 应用，回归面大 | T1 先编译通过；`TerminalSurface` 已解耦；分阶段，每阶段里程碑可验 |
| `ShellExecEmulator` 哨兵捕获在不同 shell/设备上不稳 | 哨兵用 SOH 包裹低碰撞；ANSI 剥离 + 命令回显剥离；超时兜底；Serial 结构化 exec 标尽力而为 |
| Serial 结构化 exec 污染主控台、解析受干扰 | 矩阵诚实标 ⚠️；流式应用优先；结构化应用给「尽力而为」提示 |
| `flutter_libserialport` 平台构建/版本问题 | 封装在 `SerialTransport` 后；实施前联网核对；备选 `serial_port_win32` |
| 三协议控制器状态机差异致断线/重连不一致 | 抽公共 `keepTerminal` 语义；断线浮层/重连按钮复用 |
| 串口无 NAWS，远端 tty 尺寸不匹配 | 经 exec 发 `stty rows/cols` 尽力而为；不保证 |
| 存量配置迁移破坏 | `protocol` 默认 ssh，`fromJson` 容错；旧 JSON 行为不变 |
| ZMODEM 与 IAC/0xff 冲突 | 仿真器与协商器对 0xff 透传转义；T7 单独验证 |

---

## 17. 关键入口（实现后）

| 能力 | 怎么用 |
|------|--------|
| 新建 Telnet 连接 | 协议选 Telnet -> host/port(23)/可选凭据/字符集 -> 连接 |
| 新建串口连接 | 协议选 Serial -> 端口名下拉/波特率/数据位/校验/停止位/流控/字符集 -> 连接 |
| 桌面模式（三协议） | 切桌面；应用集随协议自动过滤（SSH 全量；Telnet 缺文件/转发；Serial 进一步缺结构化 exec 的可靠保证） |
| exec 类应用（监控/日志/任务/包/防火墙…） | SSH 原生；Telnet 仿真(干净)；Serial 仿真(尽力而为) |
| 文件管理器/编辑器/传输 | 仅 SSH |
| 浏览器 | SSH 转发访问远端服务；Telnet/Serial 直连公网 |
| 重连 / 录制 / 命令历史 / 搜索 | 三协议一致 |
