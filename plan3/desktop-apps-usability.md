# 桌面应用可用性优化方案（Desktop Apps Usability Optimization）

> 目标：把远程桌面的 **16 个应用** 从「功能齐全但细节粗糙」提升为「安全、顺手、信息清晰」的专业工具集。本期聚焦**应用层可用性**，不改 SSH 连接模型、终端 PTY、xterm 渲染，对终端模式零回归。
>
> 基线：`plan/desktop-next-iteration.md`（流式/队列/外壳深度/应用深度已落地）与 `plan2/gnome-desktop-redesign.md`（外壳 GNOME 化，**仅改外壳与配色，不改应用业务逻辑**）。本方案与 plan2 **互补不冲突**：plan2 管外壳外观，plan3 管应用内里。两者唯一共享点是 `DesktopAppType` 注册表抽取（见 §B.1，由本方案落地，plan2 直接复用）。

---

## 0. 现状评估（已核实事实）

### 0.1 应用清单（`lib/desktop/apps/`，16 个）

| 类别 | 应用 | 行数 | 服务依赖 |
|---|---|---|---|
| **监控** | task_manager / monitor / disk_usage | 2253 / 734 / 287 | remote_process_list / remote_host_metrics / remote_network / remote_disk_usage / remote_gpu |
| **内容** | browser / editor | 1374 / 996 | browser_gateway / browser_history / browser_bookmarks / editor_highlight / editor_syntax |
| **管理** | containers / logs / packages / firewall / cron / users / forwards | 617 / 632 / 543 / 423 / 261 / 298 / 376 | remote_containers / remote_logs / remote_packages / remote_firewall / remote_cron / remote_users / remote_sudo / local_port_forwarder |
| **文件/终端** | terminal / file_manager(→sftp_browser) / transfers / run_command | 316 / 139(外+119KB sftp_browser) / 214 / 265 | terminal_surface / desktop_sftp_controller / sftp_upload_task_list / remote_stream |

### 0.2 架构层缺口（跨应用共性，本方案发力点）

| # | 事实 | 来源 | 影响 |
|---|---|---|---|
| 1 | **`DesktopAppType` switch 重复 4 处**（图标/标题/工厂/启动器各一份，共 ~120 行重复） | `desktop_window_manager.dart:240-281`、`desktop_window_frame.dart:31-62`、`remote_desktop_view.dart:553-663`、`desktop_taskbar.dart:442-473` | 新增/改应用要改 4 处；plan2 的应用网格也要再抄一份 |
| 2 | **无共享的 loading/empty/error 状态组件** | 各 app 自画：monitor `:` 卡、packages/firewall/cron/users 单行 muted `Text`、containers 较好(`345-355`)、sftp 静默空白 | 失败/无权限/未安装 傻傻分不清；重试按钮缺失；体验割裂 |
| 3 | **破坏性操作确认策略不一致** | 确认：packages 卸载(`177-197`)、firewall 启停/删规则(`232,245,414`)；**不确认**：firewall allow/deny(`269-304`)、container stop/restart/双击(`174-194,370-379`)、forward 删除(`186-193`)、cron 整表替换(`91-111`) | 误点可断 SSH / 停生产容器 / 丢转发 / 覆盖 crontab |
| 4 | **sudo 密码会话内全程复用，无过期/锁定** | `sudo_password_dialog.dart:28-75` 存 `controller.cachedSudoPassword`，对话框文案称「仅本次会话」却跨应用静默复用 | 权限范围超出用户预期；文案误导 |
| 5 | **跨应用联动基本单向**，仅 containers→logs 一条 | `wm.open(type,args)` 机制通用(`desktop_window_manager.dart:404`)，但只有 containers_app 用(`319-326`) | 进程→日志/端口、磁盘→文件管理器、终端→文件管理器 等都断 |
| 6 | **browser 与 editor 的 tab 条几乎一样**（横向 `ListView.builder`、14px 关闭图标、无拖拽重排、无键盘、8 上限）却各写一份 | `browser_app.dart:849-956`、`editor_app.dart:661-731` | 同类问题修两遍；命中区过小、无重排 |
| 7 | **监控三应用无键盘导航、无复制、无响应式**（全无 `Shortcuts`/`Clipboard`/`LayoutBuilder`） | task_manager / monitor / disk_usage 全文 | 鼠标独占；PID/端口/路径无法复制；窄窗列宽挤死 |
| 8 | **轮询无用户可控的暂停/间隔，无「上次更新」指示** | task_manager `_paused` 仅最小化(`129`)、monitor 同(`80`)；`_loading` 首次后恒 false | 想盯一个数只能最小化；SSH 静默卡顿时看不出数据多旧 |

### 0.3 应用层高严重度缺陷（已核实，详见各 detail 文件）

- **磁盘占用条形/颜色按「最大兄弟」归一** → 任何视图的最大项恒为红色，哪怕只占总量 2%。主动误导。`disk_usage_app.dart:137-139,211,263-275`
- **磁盘占用下钻每次开新窗口，无返回/上级/面包屑**。`disk_usage_app.dart:117-126`
- **编辑器「忽略远程变更」不生效**（3s 轮询重新置位），且**只看当前 tab** → 后台 tab 远程被改不告警，覆盖风险。`editor_app.dart:398-409,916-918`
- **编辑器硬编码 UTF-8**，非 UTF-8 文件（GBK 等）打开乱码、保存即损坏；不识别 BOM、不保留 CRLF。`editor_app.dart:373,416`
- **浏览器错误状态全局单字段**，A tab 报错切到健康 B tab 仍显示 A 的红条，无重试/关闭。`browser_app.dart:71,687-692,802-812`
- **编辑器切 tab 后查找命中偏移未重建** → `_selectFindHit` 选中新 tab 的错误区间。`editor_app.dart:675-679`
- **monitor 每 5s 重复探测 OS 三次**（network/gpu/snapshot 各 `detectRemoteOs`），task_manager 已缓存 `_os` 而 monitor 没有。`monitor_app.dart:109-111`
- **kill 恒 SIGKILL**，无优雅退出选项。`task_manager_app.dart:514`
- **传输「清空」不取消进行中任务**，UI 清空但上传后台继续（回调因 `idx<0` 早退），用户以为停了。`sftp_upload_task_list.dart:62-72`
- **SFTP 目录加载失败静默**（`catch→debugPrint`），失败只见空白无重试。`desktop_sftp_controller.dart:114-116,155-158,180-183`

---

## 1. 目标与范围

### 1.1 主题：**让应用「安全 · 顺手 · 清晰」—— 护栏 · 共享基建 · 数据正确 · 联动**

| 工作流 | 目标 | 优先级 | 详情 |
|---|---|---|---|
| **A. 安全护栏** | 统一破坏性操作确认策略；SSH 端口高危警告；cron/传输可撤销；sudo 会话锁定。 | P0 | §2 |
| **B. 共享基建** | App 注册表（消除 4×switch）、`RemoteStateView`（loading/empty/error/retry）、`DesktopTabStrip`、监控小组件（FilterField/PauseToggle/LastUpdated/Sparkline）、复制助手。 | P0/P1 | §3 + `shared-infrastructure.md` |
| **C. 数据正确性** | 磁盘条形按总量、磁盘就地导航、编辑器编码/远程变更、浏览器 per-tab 错误、monitor OS 缓存、kill 优雅选项。 | P0 | §4 |
| **D. 监控类应用** | task_manager / monitor / disk_usage：暂停/间隔、键盘+复制、跨 tab/跨应用联动、详情面板、响应式。 | P1 | §5 + `detail-monitoring.md` |
| **E. 内容类应用** | browser / editor：键盘快捷键、find-in-page、地址栏 select-all/安全指示、行号/Tab 缩进/打开文件、多 tab 重排。 | P1 | §6 + `detail-content.md` |
| **F. 管理类应用** | containers/logs/packages/firewall/cron/users/forwards：确认+错误、日志行数/级别/时间戳/导出、包升级/已装标识、cron 校验/备份/立即运行、用户写操作、转发健康/开浏览器。 | P1/P2 | §7 + `detail-management.md` |
| **G. 文件与终端** | sftp_browser：返回/上级、隐藏文件、列排序、go-to-path、书签、加载错误；terminal：搜索/字号/清屏/跳最新；transfers：速度/ETA/重试/暂停；run_command：历史/收藏/部分复制。 | P1 | §8 + `detail-file-terminal.md` |
| **H. 跨应用联动** | 双向打通：磁盘↔文件/终端、进程↔日志/端口/目录、终端↔文件管理器、编辑器↔终端、包↔文件、cron↔终端/日志、转发↔浏览器。 | P1 | §9 |
| **I. 键盘与可发现性** | 监控列表键盘导航、浏览器/编辑器快捷键、终端字号/搜索、快捷键速查表、命令面板补全窗口命令+快捷键提示。 | P2 | §10 |

### 1.2 本期不做（非目标）
- 不改 SSH 连接模型、终端 PTY、xterm 渲染抽取。
- 不做外壳 GNOME 化（归 plan2）；本方案仅触碰应用内 UI 与共享基建，外壳文件只在注册表/状态组件接入点最小改动。
- 不新增传输层；复用既有 `RemoteStream`/`RemoteCommandQueue`/`runQueued`/`snapshot()`。
- 不一次性重写 16 个应用；按「共享基建先行 → 按优先级逐应用接入」推进，每阶段可独立交付。
- 不引入新依赖（`ReorderableListView`/`LayoutBuilder`/`BackdropFilter` 均为 Flutter 内置）。

### 1.3 设计原则
1. **护栏优先**：任何能断 SSH / 停生产 / 丢数据的操作，先加确认，再做增强。
2. **共享先行**：先抽出注册表与状态组件，再逐应用接入，避免「修 16 遍同类问题」。
3. **应用归应用**：改动集中在 `lib/desktop/apps/`、`lib/widgets/`（sftp_browser/terminal_surface）、新增 `lib/desktop/desktop_app_registry.dart` 与 `lib/widgets/remote_state_view.dart`；外壳文件仅在接入点改。
4. **可回退**：新增组件为可选接入，旧 app 可渐进迁移；不删既有实现直到迁移完成。
5. **远程工具务实**：不照搬桌面 OS 的音量/蓝牙；聚焦远程管理场景（端口/进程/日志/包/转发）。

---

## 2. 工作流 A：安全护栏（P0）

> 详见 `detail-management.md` §安全 与 `detail-file-terminal.md` §transfers。本节给统一策略与共享助手。

### 2.1 统一破坏性操作确认策略

**现状**：确认与否全凭各 app 自觉（见 §0.2#3）。

**策略**（写入共享助手 `lib/widgets/destructive_action_dialog.dart` 新增）：

```dart
/// 任何影响「运行中服务 / 网络可达性 / 持久状态 / 数据」的变更必须确认。
Future<bool> confirmDestructiveAction(
  BuildContext context, {
  required String title,
  required String body,
  String confirmLabel = '确认',
  bool danger = true,                 // 红色确认按钮
  bool sshPortWarning = false,        // 触及活动 SSH 端口 → 强警告
  String? terminalFallback,           // 失败时给「在终端执行」命令
});
```

**接入清单**（逐一加 `confirm:`）：

| 应用 | 操作 | 现状 | 改为 |
|---|---|---|---|
| firewall | allow / deny（`firewall_app.dart:269-304`） | 无确认，deny 22/tcp 即断 SSH | **必确认**；若端口 == `controller.port` 或 22 → `sshPortWarning: true` 强警告「这可能断开你的 SSH 连接」；hint 改 `80/tcp`（现 `257` 是 22） |
| containers | stop / restart（`containers_app.dart:174-194`） + 双击重启（`370-379`） | 无确认；双击 = 重启 | stop/restart 确认；**双击改为打开日志/详情**而非重启 |
| forwards | 删除（`forwards_app.dart:186-193`） | 无确认且永久取消持久化 | 确认；保留一步撤销（见 §2.3） |
| cron | 整表替换（`cron_app.dart:91-111`） | 无备份 | 保存前校验（见 §7）；保留一步备份（见 §2.3） |
| task_manager | kill（`task_manager_app.dart:465-522`） | 已确认但恒 SIGKILL | 确认对话框加「结束(SIGTERM) / 强制结束(SIGKILL)」两按钮（见 §4.6） |
| packages | 卸载（`packages_app.dart:177-197`） | 已确认 | 增强：`apt -s` dry-run 列受影响依赖包（见 `detail-management.md` P5） |

### 2.2 错误可见化 + 内联重试（接 §B.2 `RemoteStateView`）

- 各 app 失败时由 `RemoteStateView.error` 统一渲染「图标 + 错误文案 + 重试按钮」，替代单行 `Text`。
- 区分状态：`未连接` / `命令未安装` / `权限不足` / `空结果` / `加载中` / `数据`。containers 已有较好区分（`345-355`），提为共享组件后其余 app 对齐。
- 服务层补退出码：`remote_containers.dart`/`remote_packages.dart` 等在命令末尾追加 `; echo __EC:$?`，用 `RemoteSudo.interpretExit` 判定，替代「输出含 error 字样」的脆弱判定（`containers_app.dart:186-192`）。

### 2.3 可撤销（cron / forwards / transfers）

- **cron**：`installCrontab`（`remote_cron.dart:100-117`）替换前，把当前全文存入内存 `_lastCrontab`；编辑器加「撤销上一次」按钮恢复。仅一步，够覆盖「手滑覆盖」。
- **forwards**：删除前存被删 spec 到 `_lastDeleted`，任务栏/列表区显示 SnackBar「已删除转发 X · 撤销」。
- **transfers**：「清空」改为只清 `failed`/已完成（成功已自动移除，故等价于清失败）；进行中禁用「清空」、改用「全部取消」。新增「清空失败」「全部重试」（见 `detail-file-terminal.md` §3.6）。

### 2.4 sudo 会话锁定（接 §0.2#4）

- `SshWorkspaceController.cachedSudoPassword` 增加「最后使用时间」与「超时（默认 15 分钟空闲）」；超时后下次 sudo 重新弹框。
- 桌面托盘/Quick Settings（plan2）增加「锁定 sudo」按钮立即清空缓存。
- 对话框文案改为「密码将在本次会话内复用（15 分钟空闲后失效），不会保存到本地」，消除误导。

### 2.5 验收（工作流 A）
- [ ] firewall `deny 22/tcp`（当 SSH 端口为 22）弹出强警告，取消不执行；`deny 80/tcp` 普通确认。
- [ ] container stop/restart 有确认；双击容器打开日志而非重启。
- [ ] forward 删除有确认，且 5s 内可点 SnackBar 撤销。
- [ ] cron 保存后可「撤销上一次」恢复前一份。
- [ ] transfers 进行中「清空」禁用；失败行有「重试」。
- [ ] sudo 空闲 15 分钟后再次 sudo 重新弹框；托盘可手动锁定。
- [ ] 各 app 失败显示错误文案 + 重试按钮（非空白/单行字）。

---

## 3. 工作流 B：共享基建（P0/P1）

> 详见 `shared-infrastructure.md`。本节给组件契约与接入点。

### 3.1 `DesktopAppRegistry`（消除 4×switch，P0，与 plan2 共享）

**文件**：`lib/desktop/desktop_app_registry.dart`（新增）

```dart
record AppMeta(DesktopAppType id, IconData icon, String label, List<String> keywords,
               {Size? defaultSize, bool favorite = false});
const kAllApps = <AppMeta>[ /* 16 条 */ ];
AppMeta metaFor(DesktopAppType t);
```

**接入**：`desktop_window_manager.dart:240-281`（defaultTitle）、`desktop_window_frame.dart:31-62`（图标）、`remote_desktop_view.dart:553-663`（工厂）、`desktop_taskbar.dart:442-473`（启动器）四处 switch 改读 registry。plan2 的 Dash/应用网格直接读同一 registry。

### 3.2 `RemoteStateView`（统一 loading/empty/error/retry，P0）

**文件**：`lib/widgets/remote_state_view.dart`（新增）

```dart
enum RemoteState { loading, empty, notInstalled, denied, disconnected, error, data }
class RemoteStateView extends StatelessWidget {
  final RemoteState state;
  final String? message;            // 错误/空文案
  final VoidCallback? onRetry;
  final Widget Function() data;     // data 态构建器
  // 渲染：loading→骨架/转圈；empty→图标+文案；notInstalled→「未安装 X，可在终端执行」；
  //      denied→「权限不足 · 以 sudo 重试」；disconnected→「未连接 · 重连」；error→文案+重试。
}
```

**接入**：packages/firewall/cron/users/forwards 的单行 `Text` 错误 → `RemoteStateView.error`；monitor 资源页 `-` 卡墙（`monitor_app.dart:236-352`）→ empty 态；sftp 加载失败（§8.2）→ error 态 + 重试。

### 3.3 `DesktopTabStrip`（browser + editor 共用，P1）

**文件**：`lib/desktop/desktop_tab_strip.dart`（新增）

抽出 `browser_app.dart:849-956` 与 `editor_app.dart:661-731` 的共同模式：`ReorderableListView`（横向拖拽重排）、关闭图标命中区 ≥28×28（现 14px）、hover 显隐关闭、`N/8` 计数、活动 tab 自动滚入视、可选右键菜单（固定/复制/关闭其他/关闭右侧）。

### 3.4 监控小组件（P1）

**文件**：`lib/desktop/desktop/widgets/`（新增目录或并入现有）
- `FilterField`：task_manager 已有内嵌版（提炼复用），monitor/disk_usage 复用。
- `PauseToggle`：暂停/恢复 + 间隔下拉（1s/3s/10s/30s），接入 task_manager/monitor/logs/containers。
- `LastUpdatedChip`：「更新于 3s 前」+ 活动呼吸点，接入所有轮询 app。
- `SparklineCard`：统一 CPU/MEM/网络/GPU 趋势卡；网络 rx/tx **共享刻度**（现各自归一无法比较，`task_manager_app.dart:1505-1513`）。
- `confirmDestructiveAction`（§2.1）、`copyableText`/`CopyMenuItem`（§I）。

### 3.5 验收（工作流 B）
- [ ] 新增 `DesktopAppType` 只改 registry 一处，4 个旧 switch 删除。
- [ ] 任意 app 失败渲染统一错误组件 + 重试。
- [ ] browser/editor tab 关闭命中区 ≥28px，可拖拽重排。
- [ ] 监控 app 顶部有暂停按钮 + 「更新于 N s 前」。

---

## 4. 工作流 C：数据正确性修复（P0）

> 这些是「显示错 / 会丢数据」的硬伤，优先于体验增强。

| # | 缺陷 | 修复 |
|---|---|---|
| C1 | 磁盘条形/颜色按最大兄弟归一（`disk_usage_app.dart:137-139,211,263-275`） | 条形 value 与颜色阈值改用 `ofTotal`（bytes/total），保留「相对最大」仅作可选副可视化并标注 |
| C2 | 磁盘下钻每次开新窗、无返回/上级/面包屑（`117-126`） | **就地导航**：点条目更新 `_path` 重载同窗；加面包屑（每段可点跳祖先）+「上级」按钮；标题用全路径（现仅叶名 `95-102`） |
| C3 | 编辑器「忽略远程变更」不生效 + 只看当前 tab（`editor_app.dart:398-409,916-918`） | 「忽略」时 `tab.remoteMtime = t` 作基线 + 记 `ignoredMtime`，进一步变更仍告警；`_checkRemote` 遍历所有 tab（节流），非仅 active |
| C4 | 编辑器硬编码 UTF-8，损坏非 UTF-8 文件（`373,416`） | 检测编码（BOM/启发）；状态栏显编码；「重新以编码打开」「保存为编码」；保留 CRLF/LF；去 BOM |
| C5 | 浏览器错误全局单字段，跨 tab 串味（`browser_app.dart:71,687-692,802-812`） | `error` 移入 `_BrowserTab`，只渲染活动 tab 错误；错误条加「重试」「关闭」 |
| C6 | 编辑器切 tab 查找偏移未重建（`editor_app.dart:675-679`） | 切 tab 后若查找栏开 → 调 `_rebuildFindHits()`+`_selectFindHit()` |
| C7 | monitor 每 5s 探测 OS 三次（`monitor_app.dart:109-111`） | 缓存 `_os`，三处 fetch 传 `osHint: _os`（对齐 task_manager） |
| C8 | kill 恒 SIGKILL（`task_manager_app.dart:514`） | 确认框两按钮：结束=SIGTERM（`taskkill` 不加 `/F`）/ 强制结束=SIGKILL；默认优雅 |

### 4.1 验收（工作流 C）
- [ ] 磁盘：占总量 2% 的最大项不再显示红色；下钻同窗、可返回上级；标题全路径。
- [ ] 编辑器：远程改文件后「忽略」不再每 3s 复现；后台 tab 远程被改也告警；切 tab 查找不选错区间；GBK 文件打开不乱码、保存不损坏。
- [ ] 浏览器：A tab 报错切 B tab 不显示 A 错误；错误条有重试。
- [ ] monitor 刷新不再重复探测 OS（debug 计数）。
- [ ] kill 默认 SIGTERM，可选强制。

---

## 5. 工作流 D：监控类应用（P1）→ `detail-monitoring.md`

**task_manager**（2253 行，最大）：暂停/间隔（A1/B1）；上次更新指示（A2）；kill 优雅选项（C8/A3）；**去掉双击杀进程**，双击改开详情（A4）；进程详情面板：cmdline/PPID/启动时间/监听端口（A5/A6）；UDP 监听也给「复制端点/查看进程」菜单（A7）；全局复制（A8）；服务控制成败反馈（A9）；键盘导航（A10）；800 截断提示（A11）；Windows 列缺失说明（A12）；网络 rx/tx 共享刻度（A13）；重连清 `_netPrev` 防速率尖峰（A14）；断线可重试（A15）；响应式（A16）。

**monitor**（734 行）：暂停/间隔（B1）；**OS 缓存**（C7/B2）；网络 tab 补 FilterField + 隐藏回环 chip（B3/B4，对齐 task_manager）；监听器双击开浏览器加 Tooltip/图标（B5）；`take(8/40/10)` 截断提示（B6）；资源页 `-` 卡墙改 empty 态（B7）；**与 task_manager 性能页去重**：抽共享 `SparklineCard`/资源组件，二者择一为唯一资源视图或共享实现（B8）；GPU 趋势线（B9）。

**disk_usage**（287 行）：**条形按总量**（C1）；**就地导航+面包屑+上级**（C2）；**加文件管理器/终端联动**（C3/H）；FilterField（C4）；排序（C5）；60 截断 + `-x` 跨文件系统提示（C6）；大目录 `du` 取消按钮 + 超时（C7）；放宽路径校验（`remote_disk_usage.dart:39-43`，已有 `_shellSingleQuote` 无需那么严）（C8）；标题全路径（C9）；权限不足 vs 不存在区分 + sudo 重试（C10）。

---

## 6. 工作流 E：内容类应用（P1）→ `detail-content.md`

**browser**（1374 行）：**键盘快捷键** Ctrl+T/W/R/L、Ctrl+Tab、Ctrl+1..8（B1）；tab 拖拽重排/右键菜单/溢出计数（B2/B3，接 `DesktopTabStrip`）；关闭命中区（B4）；末 tab 关闭行为统一（B5）；弹窗达上限提示（B6）；地址栏 **聚焦全选**（B7）；**安全指示**（锁/网关/直连，B8）；inline 自动补全（B9）；粘贴并跳/复制 URL（B10）；断线仍可输 URL（B11）；**per-tab 错误** + 重试 + 真错误页（C5/B13/B14）；加载指示与地址栏解耦（B15）；**find-in-page** Ctrl+F（B16）；缩放/持久（B17）；下载处理（B18）；DevTools 入口（B19）；新标签页/常用站点（B20）；历史逐项删除（B21）；书签带标题/分组（B22）；自签证书指示（B23）；模式切换加 tooltip+图标（B24）；JS 提示改一次性（B25）。

**editor**（996 行）：**行号**（E1）；**Tab 缩进/Shift+Tab 反缩进/Enter 继承缩进**（E2）；HTML/TS/CSS/Py 等高亮补全（E3/E4）；换行开关（E5）；**编码检测/重开/保存为**（C4/E6）；查找命中全量高亮（E7）；「无匹配」反馈（E8）；大小写/正则/整词（E9）；**切 tab 重建查找**（C6/E10）；Esc 关查找/Shift+Enter 上一个（E11）；Cmd+F 与图标行为统一（E12）；跳行对话框给当前/总行（E13）；语法错误条可点跳行（E14）；**「打开」按钮**（远端路径选择，E15）；另存为/新草稿（E16）；末 tab 关闭回空态而非关窗（E17）；**远程变更忽略生效 + 全 tab 轮询**（C3/E18/E19）；tab 重排+键盘（E20，接 `DesktopTabStrip`）；关闭命中区（E21）；删死代码 `|| true`（E22）；状态栏行:列/选区数（E23）；保存失败用持久条+重试（E24）；只读文件标识（E25）。

---

## 7. 工作流 F：管理类应用（P1/P2）→ `detail-management.md`

**containers**：stop/restart/双击确认（§2.1/C1-C2）；错误用退出码非字符串匹配（C3）；补 exec/inspect/删除（C4）；暂停刷新（C5）；消失容器详情给提示（C6）。

**logs**：**行数选择器** 100/300/1000/2000（现硬编码 300，L1）；**级别过滤 UI**（service 有 `priority` 但 UI 未接，L2）；**时间戳列**（已解析未渲染，L3）；导出全量（L4）；换行/清空/跳时间（L5）；上滚可选暂停跟随（L6）；错误内联重试（L7）。

**packages**：**升级(update-all)**（P1）；搜索结果标「已安装」禁用安装（P2）；**400 截断提示**（P3）；包详情 dpkg -L/rpm -ql + 跳文件管理器（P4，接 H）；卸载 dry-run 列依赖（P5）；版本选择（P6）；失败提示的命令带正确 install 标志（P7）。

**firewall**：**allow/deny 确认 + SSH 端口强警告**（§2.1/F1，最高优先）；非 UFW 后端给「暂不支持可视化编辑 + 可复制命令」提示（F2）；常用预设（SSH/HTTP/HTTPS，F3）；规则编辑（F4）；firewalld zone/service/reload（F5）；hint 改非 SSH 端口（F6）。

**cron**：**保存前语法校验**（CR1，service 有 `parseCrontab`）；**一步备份撤销**（§2.3/CR2）；「立即运行」（CR3，接 H）；逐项启用/禁用 + 语法帮助 + 下次运行预览（CR4）；crond 服务状态（CR5）；编辑器加行号/高亮畸形行（CR6）。

**users**：**写操作** 增/删/锁定/改密（U1，sudo 已就绪）；组名 + 组成员（U2）；踢出会话（U3）；失败登录 lastb/auth.log（U4）；系统用户阈值可配/读 login.defs（U5）。

**forwards**：**删除确认 + 撤销**（§2.3/FW1）；本地端口冲突检测+建议下一个空闲端口（FW2）；编辑（FW3）；**开浏览器/复制 URL**（FW4，接 H）；健康探测/字节计数（FW5）；恢复转发 toast（FW6）；转发中断可选自动重连（FW7）。

---

## 8. 工作流 G：文件与终端（P1）→ `detail-file-terminal.md`

**sftp_browser / file_manager**：**返回/前进/上级** + 历史栈（2.1）；隐藏文件开关（2.2）；**列排序**（名/大小/修改，2.3）；**go-to-path**（⌘L，2.4）；书签 + 最近（2.5）；详情视图含权限/属主列（2.6）；工具栏窄窗溢出 → 横滚/溢出菜单（2.7）；**加载错误状态 + 重试**（2.8，接 `RemoteStateView`）；「复制路径」菜单项（2.9）；面包屑当前段非链接样式（2.10）；搜索可取消 + 截断提示 + 可选内容搜索（2.11）。

**terminal**：**搜索**（Cmd+F，theme 已有高亮色未接，4.1）；**清空缓冲区/重置**菜单（4.2）；**字号快捷键** Cmd+/-/0（4.3）；窗口内 tab/分屏（4.4，P2）；滚动离开底部时「↓ 跳最新」按钮（4.5）。

**transfers**：**「清空」只清失败/完成 + 进行中禁用**（§2.3/3.2）；**失败行重试**（3.1）；速度 + ETA（3.3）；暂停/恢复（3.4，P2）；队列优先级/重排（3.5，P2）；「清空失败」「全部重试」（3.6）；头部三态汇总「成功 X · 失败 Z · 进行中 N」（7.2）。

**run_command**：**命令历史**（持久 + ↑↓ 召回 + 下拉，5.1）；**收藏/预设**（5.2）；**部分复制**（整段单 `SelectableText`，5.3）；多次运行保留分隔追加（5.4）；长行换行/横滚（8.3）。

---

## 9. 工作流 H：跨应用联动（P1）

> 机制 `wm.open(DesktopAppType, args)` 已通用，补双向链。每条标注「→方向 / 触发点 / 目标 args」。

| 源 | 动作 | 目标 | 触发点 | args |
|---|---|---|---|---|
| disk_usage | 在文件管理器打开 / 在终端打开 | files / terminal | 条目右键/工具栏（`disk_usage_app.dart` 新增） | `{'path'/'cwd': childPath}` |
| process | 查看日志 / 查看监听端口 / 打开所在目录 | logs / tasks(Network) / files | 进程行右键（`task_manager_app.dart` A6） | logs:`{'pid':p}`；files:`{'cwd':'/proc/pid/cwd'}` |
| network listener | 查看进程 | tasks(Processes) | 监听行 PID 可点（A7） | 选 PID 跳进程 tab |
| terminal | 在文件管理器打开 | files | 终端右键/命令面板（`terminal_app.dart` 新增） | `{'cwd': bestEffortPwd}` |
| editor | 在终端打开（文件所在目录） | terminal | 编辑器工具栏/右键（`editor_app.dart` 新增） | `{'cwd': parentDir(path)}` |
| package | 查看安装的文件 | files | 包详情（packages P4） | 逐项跳文件管理器 |
| cron | 立即运行 / 查看日志 | terminal / logs | 任务行右键（cron CR3） | terminal 注入命令；logs 过滤 |
| forward | 在浏览器打开 / 复制 URL | browser / 剪贴板 | 转发行按钮（forwards FW4） | browser:`{'url':'http://localhost:port'}` |
| desktop 右键 | 「在此」措辞修正 | — | `remote_desktop_view.dart:86-98,362,728` | 空桌面无「此」，改「打开终端」「打开文件管理器」；label「打开文件」→「文件管理器」 |

**服务侧补强**：logs 支持 `journalctl _PID=<pid>` 过滤（process→logs 需要）；files/terminal 已支持 `cwd`/`inject` args。

---

## 10. 工作流 I：键盘与可发现性（P2）

- **监控列表键盘导航**：`Focus`+`Shortcuts`，↑↓ 移选、Enter 开详情、Delete 杀进程、`/`或 Ctrl+F 聚焦过滤、Esc 清选（task_manager/monitor/disk_usage）。
- **浏览器快捷键**（§6 B1）、**编辑器快捷键**（§6 E2/E11/E20）、**终端字号/搜索**（§8 4.1/4.3）。
- **快捷键速查表**：命令面板加「键盘快捷键」命令 + 托盘菜单项，弹参考对话框（现无任何罗列，`remote_desktop_view.dart:195-344` 富快捷键集不可发现）。
- **命令面板补全**：补 minimize/maximize/tile/move-to-workspace/show-desktop/cycle 窗口命令；每行尾显示绑定快捷键提示（现无，`desktop_command_palette.dart:51-237`）。
- **工作区快捷键 macOS 一致**：`Ctrl+1..9` 改 `workbenchMetaOrControl`（现仅 Ctrl，macOS Cmd+1 无效，`remote_desktop_view.dart:276-299`）。
- **snap 布局可发现性**：补悬停 snap 网格（tooltip 已承诺）或改 tooltip 为「右键/长按选布局」+ 最大化按钮加小箭头（`desktop_window_frame.dart:524-583`）。

---

## 11. 实施阶段

> 每阶段独立可交付；护栏与正确性先行，基建铺路，再逐应用接入。

### 阶段 1 · 安全护栏 + 数据正确性（P0，1 周）
- [ ] `destructive_action_dialog.dart` + 接入 firewall allow/deny（SSH 端口警告）、containers stop/restart/双击、forwards 删除、cron 备份撤销、transfers 清空语义。
- [ ] 数据正确性 C1-C8（磁盘条形/导航、编辑器编码/远程变更/查找、浏览器 per-tab 错误、monitor OS 缓存、kill 优雅）。
- [ ] sudo 会话锁定 + 文案修正。
- [ ] **验收**：§2.5 + §4.1 全过；终端模式零回归。

### 阶段 2 · 共享基建（P0/P1，1 周）
- [ ] `desktop_app_registry.dart` + 四处 switch 迁移。
- [ ] `remote_state_view.dart` + 监控/管理 app 错误态迁移。
- [ ] `desktop_tab_strip.dart` + browser/editor tab 条接入。
- [ ] 监控小组件（FilterField/PauseToggle/LastUpdatedChip/SparklineCard）。
- [ ] **验收**：§3.5 全过；新增 app 只改一处。

### 阶段 3 · 监控类应用深化（P1，1–2 周）
- [ ] task_manager：暂停/键盘/复制/进程详情/跨 tab 联动/响应式。
- [ ] monitor：对齐 task_manager（Filter/隐藏回环/截断提示/资源去重/GPU 趋势）。
- [ ] disk_usage：就地导航/联动/排序/取消/路径校验。
- [ ] **验收**：`detail-monitoring.md` 各项。

### 阶段 4 · 内容类应用深化（P1，1–2 周）
- [ ] browser：快捷键/find-in-page/地址栏/错误页/tab 重排/下载。
- [ ] editor：行号/Tab 缩进/打开文件/查找增强/状态栏。
- [ ] **验收**：`detail-content.md` 各项。

### 阶段 5 · 管理类 + 文件终端深化（P1/P2，2 周）
- [ ] logs（行数/级别/时间戳/导出）、packages（升级/已装标识/详情）、firewall（预设/编辑/后端提示）、cron（校验/立即运行/状态）、users（写操作/组/失败登录）、forwards（冲突/编辑/健康/开浏览器）。
- [ ] sftp_browser（返回/上级/隐藏/排序/go-to-path/书签/错误态）、terminal（搜索/字号/清屏/跳最新）、transfers（速度/ETA/重试/清空失败）、run_command（历史/收藏/部分复制）。
- [ ] **验收**：`detail-management.md` + `detail-file-terminal.md` 各项。

### 阶段 6 · 联动 + 键盘可发现性 + 收尾（P1/P2，1 周）
- [ ] 跨应用联动全量接线（§9）。
- [ ] 键盘导航 + 快捷键速查表 + 命令面板补全 + macOS 工作区键 + snap 可发现性。
- [ ] 本地化：新增字符串补 `app_localizations_*.dart`。
- [ ] **验收**：§9 + §10 全过；终端模式零回归。

---

## 12. 风险与回归

| 风险 | 影响 | 对策 |
|---|---|---|
| 破坏性确认增加摩擦，老用户嫌烦 | 中 | 高危必确认（防火墙/容器/转发/cron）；低危（package 查询、文件刷新）不加；可设「本次会话不再确认」临时开关（仅非 SSH 端口类） |
| 编辑器编码检测误判 | 中 | 默认仍 UTF-8；启发不确定时弹「检测到 X 编码，是否以此打开」；保留「以 UTF-8 打开」兜底 |
| 磁盘就地导航改动 `args['path']` 语义，影响 file_manager→disk_usage 入参 | 低 | args 键统一 `path`（disk_usage）/`cwd`（files/terminal）；兼容旧 `cwd` 传 disk_usage 的调用并迁移 |
| `RemoteStateView` 接入面广，迁移期双态并存 | 低 | 组件可选接入；未迁移 app 保持原样；按阶段逐步替换，不一次性全改 |
| `DesktopTabStrip` 抽取影响 browser/editor 现有 tab 状态机 | 中 | 先抽 UI 层（渲染+重排+命中区），tab 数据模型仍各持有；行为对齐用单测护栏 |
| 跨应用联动依赖服务侧新命令（journalctl _PID、dpkg -L） | 低 | 远端无该命令时联动项降级为「复制命令到终端」；不静默失败 |
| 工作区快捷键改 meta，与浏览器 tab Ctrl+1..8 冲突 | 中 | 桌面层用 `workbenchMetaOrControl`；应用内 tab 切换仅在窗口聚焦且非桌面快捷键上下文时响应；优先级测试 |
| sudo 超时打断长操作 | 中 | 超时仅清缓存，进行中命令不中断；下次 sudo 才重新弹框 |
| 与 plan2（外壳 GNOME 化）并发改动外壳文件 | 中 | 注册表由 plan3 落地、plan2 复用；其余外壳文件 plan3 仅最小接入点，大改归 plan2；两方案分文件、分阶段避免冲突 |

---

## 13. 验收标准

1. **安全**：所有影响运行服务/网络/持久状态/数据的操作有确认；触及 SSH 端口的防火墙操作有强警告；cron/forwards 可撤销；transfers 不再后台孤儿上传。
2. **正确**：磁盘条形按总量着色；编辑器不损坏非 UTF-8 文件、远程变更告警准确；浏览器错误不跨 tab；监控数据不因重复探测拖慢。
3. **基建**：新增应用改一处注册表；任意失败有统一错误组件 + 重试；browser/editor tab 可重排、命中区达标。
4. **顺手**：监控可暂停、有「上次更新」；文件管理器有返回/上级/排序/go-to-path；终端可搜索/缩字号；run_command 有历史；transfers 有速度/ETA/重试。
5. **联动**：磁盘↔文件/终端、进程↔日志/端口/目录、终端↔文件管理器、转发↔浏览器 双向可达。
6. **键盘**：监控列表可键盘导航；浏览器/编辑器/终端标准快捷键可用；快捷键速查表可查；macOS 工作区键一致。
7. **零回归**：终端模式选择/拖选/拖出/上传/编辑/断线重连逐项回归；16 应用业务逻辑无意外行为变化。

---

## 14. 主优先级清单（跨应用 Top 30）

| # | 项 | 应用 | 类别 | 阶段 |
|---|---|---|---|---|
| 1 | firewall allow/deny 无确认，deny 22/tcp 断 SSH | firewall | 安全·关键 | 1 |
| 2 | container stop/restart/双击无确认 | containers | 安全 | 1 |
| 3 | forward 删除无确认且永久 | forwards | 安全 | 1 |
| 4 | cron 整表替换无备份 | cron | 安全 | 1 |
| 5 | transfers「清空」孤儿进行中上传 | transfers | 安全·数据 | 1 |
| 6 | 编辑器「忽略远程变更」不生效 + 只看当前 tab | editor | 正确性·数据 | 1 |
| 7 | 编辑器硬编码 UTF-8 损坏文件 | editor | 正确性·数据 | 1 |
| 8 | 磁盘条形按兄弟归一，误导 | disk_usage | 正确性 | 1 |
| 9 | 磁盘下钻每次开新窗无返回 | disk_usage | 正确性·摩擦 | 1 |
| 10 | 浏览器错误跨 tab 串味 | browser | 正确性 | 1 |
| 11 | monitor 重复探测 OS 三次 | monitor | 正确性·性能 | 1 |
| 12 | kill 恒 SIGKILL | task_manager | 正确性·安全 | 1 |
| 13 | 编辑器切 tab 查找偏移错 | editor | 正确性 | 1 |
| 14 | sudo 会话全程复用 + 文案误导 | 跨应用 | 安全 | 1 |
| 15 | App 注册表（消除 4×switch） | 跨应用 | 基建 | 2 |
| 16 | RemoteStateView（统一错误/重试） | 跨应用 | 基建 | 2 |
| 17 | DesktopTabStrip（browser+editor） | 跨应用 | 基建 | 2 |
| 18 | 监控暂停/间隔 + 上次更新指示 | task/monitor | 体验 | 2/3 |
| 19 | 文件管理器返回/上级/排序/go-to-path | sftp_browser | 体验 | 5 |
| 20 | 终端搜索 + 字号快捷键 | terminal | 体验 | 5 |
| 21 | run_command 历史/收藏 | run_command | 体验 | 5 |
| 22 | transfers 速度/ETA/重试 | transfers | 体验 | 5 |
| 23 | logs 行数/级别/时间戳/导出 | logs | 体验 | 5 |
| 24 | 浏览器键盘快捷键 + find-in-page | browser | 体验 | 4 |
| 25 | 编辑器行号 + Tab 缩进 + 打开文件 | editor | 体验 | 4 |
| 26 | 跨应用联动双向打通 | 跨应用 | 联动 | 6 |
| 27 | 监控键盘导航 + 复制 | task/monitor/disk | 键盘 | 6 |
| 28 | 快捷键速查表 + 命令面板补全 | 外壳 | 可发现 | 6 |
| 29 | macOS 工作区快捷键一致 | 外壳 | 键盘 | 6 |
| 30 | snap 布局可发现性 | 外壳 | 可发现 | 6 |

---

## 附件

- `shared-infrastructure.md` — 工作流 B 共享组件契约与接入细节。
- `detail-monitoring.md` — task_manager / monitor / disk_usage 全量发现（file:line + 修复）。
- `detail-content.md` — browser / editor 全量发现。
- `detail-management.md` — containers / logs / packages / firewall / cron / users / forwards 全量发现。
- `detail-file-terminal.md` — sftp_browser / terminal / transfers / run_command 全量发现。
