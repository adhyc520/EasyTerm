# 附件：共享基建细节（Shared Infrastructure）

> 工作流 B 的组件契约、接入点与迁移清单。对应主方案 §3。

---

## B.1 `DesktopAppRegistry`

**文件**：`lib/desktop/desktop_app_registry.dart`（新增）

### 契约
```dart
import 'package:flutter/material.dart';
import 'desktop_window_manager.dart' show DesktopAppType;

class AppMeta {
  final DesktopAppType id;
  final IconData icon;
  final String label;            // 中文标题（后续迁本地化 key）
  final List<String> keywords;   // 命令面板/搜索用，含英文缩写
  final Size? defaultSize;       // 按类型记忆尺寸的兜底（与 desktop_window_size_store 协同）
  const AppMeta(this.id, this.icon, this.label, this.keywords, {this.defaultSize});
}

const kAllApps = <AppMeta>[
  AppMeta(DesktopAppType.terminal, Icons.terminal, '终端', ['terminal','shell','ssh'], defaultSize: Size(720,460)),
  AppMeta(DesktopAppType.files, Icons.folder_outlined, '文件管理器', ['files','sftp','file manager'], defaultSize: Size(820,540)),
  AppMeta(DesktopAppType.browser, Icons.language, '浏览器', ['browser','web'], defaultSize: Size(900,600)),
  AppMeta(DesktopAppType.monitor, Icons.monitor_heart_outlined, '监控', ['monitor','metrics','system'], defaultSize: Size(760,560)),
  AppMeta(DesktopAppType.tasks, Icons.memory, '任务管理器', ['tasks','task manager','process','top'], defaultSize: Size(820,560)),
  AppMeta(DesktopAppType.logs, Icons.article_outlined, '日志', ['logs','journal','tail'], defaultSize: Size(780,520)),
  AppMeta(DesktopAppType.containers, Icons.inventory_2_outlined, '容器', ['containers','docker'], defaultSize: Size(820,560)),
  AppMeta(DesktopAppType.diskUsage, Icons.donut_small_outlined, '磁盘占用', ['disk','du','usage'], defaultSize: Size(640,520)),
  AppMeta(DesktopAppType.transfers, Icons.swap_vert, '传输', ['transfers','upload','download'], defaultSize: Size(560,420)),
  AppMeta(DesktopAppType.editor, Icons.edit_note, '编辑器', ['editor','edit'], defaultSize: Size(780,560)),
  AppMeta(DesktopAppType.forwards, Icons.alt_route, '端口转发', ['forwards','tunnel','port forward'], defaultSize: Size(620,460)),
  AppMeta(DesktopAppType.runCommand, Icons.terminal_outlined, '运行命令', ['run','command'], defaultSize: Size(600,420)),
  AppMeta(DesktopAppType.cron, Icons.schedule_outlined, '计划任务', ['cron','crontab','schedule'], defaultSize: Size(640,480)),
  AppMeta(DesktopAppType.users, Icons.group_outlined, '用户', ['users','who','last'], defaultSize: Size(640,480)),
  AppMeta(DesktopAppType.packages, Icons.extension_outlined, '软件包', ['packages','apt','dnf','pacman'], defaultSize: Size(760,540)),
  AppMeta(DesktopAppType.firewall, Icons.security_outlined, '防火墙', ['firewall','ufw','iptables'], defaultSize: Size(680,520)),
];

AppMeta metaFor(DesktopAppType t) => kAllApps.firstWhere((m) => m.id == t);
```

### 接入点（4 处 switch 删除）
| 文件 | 行 | 现状 | 改为 |
|---|---|---|---|
| `desktop_window_manager.dart` | 238-282 | `defaultTitle` switch 16 case | `metaFor(type).label` |
| `desktop_window_frame.dart` | 31-62 | 图标 switch | `metaFor(type).icon` |
| `remote_desktop_view.dart` | 553-663 | 工厂 switch（构建 widget） | 保留工厂（widget 构造各不同），但图标/标题读 registry；后续可按类型->builder 映射进一步收拢 |
| `desktop_taskbar.dart` | 442-473 | 启动器菜单项 switch | 遍历 `kAllApps` 生成 PopupMenuItem |

> 注：`remote_desktop_view.dart` 的工厂 switch 因每个 app 构造参数不同，无法纯数据化；本期仅把图标/标题/启动器三处纯数据 switch 迁移到 registry，工厂 switch 保留但加注释「新增 app 在此注册 builder」。plan2 的 Dash/应用网格直接读 `kAllApps`。

---

## B.2 `RemoteStateView`

**文件**：`lib/widgets/remote_state_view.dart`（新增）

### 契约
```dart
enum RemoteState { loading, empty, notInstalled, denied, disconnected, error, data }

class RemoteStateView extends StatelessWidget {
  const RemoteStateView({
    super.key,
    required this.state,
    this.message,
    this.detail,            // 额外说明（如建议的终端命令）
    this.onRetry,
    this.retryLabel,
    required this.data,
  });
  final RemoteState state;
  final String? message;
  final String? detail;
  final VoidCallback? onRetry;
  final String? retryLabel;   // '重试' / '重连' / '以 sudo 重试'
  final Widget data;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      RemoteState.loading      => _Loading(),
      RemoteState.empty        => _Placeholder(icon: Icons.inbox_outlined, text: message ?? '暂无数据'),
      RemoteState.notInstalled => _Placeholder(icon: Icons.download_outlined, text: message ?? '未安装',
                                  detail: detail, onRetry: onRetry, retryLabel: '复制安装命令'),
      RemoteState.denied       => _Placeholder(icon: Icons.lock_outline, text: '权限不足',
                                  detail: detail, onRetry: onRetry, retryLabel: retryLabel ?? '以 sudo 重试'),
      RemoteState.disconnected => _Placeholder(icon: Icons.cloud_off, text: '未连接',
                                  onRetry: onRetry, retryLabel: '重连'),
      RemoteState.error        => _Placeholder(icon: Icons.error_outline, text: message ?? '加载失败',
                                  detail: detail, onRetry: onRetry, retryLabel: '重试'),
      RemoteState.data         => data,
    };
  }
}
```

### 状态判定约定（各 app 据命令输出映射）
- `notInstalled`：命令退出码 127 / 输出含 `command not found` / `not installed`。
- `denied`：退出码非 0 且输出含 `Permission denied` / `access denied` / `requires root`。
- `disconnected`：`controller.connectionState != connected` 或 `runQueued` 返回 null 且未连接。
- `empty`：命令成功但结果列表为空。
- `error`：其它非 0 退出 / 解析失败 / 超时。

### 迁移清单
| app | 现状 | 目标状态 |
|---|---|---|
| monitor 资源页 `-` 卡墙（`monitor_app.dart:236-352`） | `_snap==null && _error==null` 静默 | `RemoteStateView(empty)` |
| packages 错误单行（`packages_app.dart:298-305`） | muted Text | `RemoteStateView(error, onRetry)` |
| firewall 错误单行（`firewall_app.dart:308-315`） | muted Text | `RemoteStateView(error)` + 非 UFW 后端 `notInstalled`/提示 |
| cron 错误单行（`cron_app.dart:181-185`） | muted Text | `RemoteStateView(error)` |
| users 错误单行（`users_app.dart:150-154`） | muted Text | `RemoteStateView(error)` |
| forwards 错误单行（`forwards_app.dart:298-302`） | muted Text | `RemoteStateView(error)` |
| sftp 加载失败（`desktop_sftp_controller.dart:114-116`） | 静默空白 | controller 暴露 `loadError` -> `RemoteStateView(error, onRetry: refresh)` |
| containers（`containers_app.dart:345-355` 已较好） | 已区分 | 提炼进 `RemoteStateView` 后对齐 |

---

## B.3 `DesktopTabStrip`

**文件**：`lib/desktop/desktop_tab_strip.dart`（新增）

### 契约
```dart
class DesktopTabStrip<T> extends StatelessWidget {
  const DesktopTabStrip({
    required this.tabs,            // List<TabModel>
    required this.activeIndex,
    required this.onSelect,
    required this.onClose,
    this.onReorder,                // 拖拽重排（可选）
    this.onContextMenu,            // 右键菜单（固定/复制/关闭其他/关闭右侧）
    this.maxTabs = 8,
    this.buildLabel,               // (T)->Widget
    this.buildIcon,
  });
}

abstract class TabModel {
  String get title;
  bool get dirty;        // 标题前显 ●（editor 未保存）
  bool get pinned;       // 固定 tab 收窄
}
```

### 行为
- `ReorderableListView`（横向），拖拽重排（`onReorder` 非空时）。
- 关闭图标：`Icon(Icons.close, size: 16)` 包 `InkWell(constraints: BoxConstraints(minWidth:28,minHeight:28))`，hover/active 时渐显，命中区 ≥28px（修复 `browser_app.dart:924` / `editor_app.dart:713` 的 14px）。
- 溢出：横向滚动 + 右侧淡出渐变；活动 tab 选中时 `Scrollable.ensureVisible` 滚入视；`N/maxTabs` 计数。
- 右键菜单：固定/复制/关闭其他/关闭右侧（各 app 按需启用）。

### 接入
- browser `_TabStrip`（`849-956`）-> `DesktopTabStrip`；editor `_EditorTab`（`661-731`）-> 同。两边数据模型各持，仅 UI 共用。

---

## B.4 监控小组件

**文件**：`lib/desktop/desktop/widgets/`（新增）

### `FilterField`
- 提炼自 task_manager 内嵌过滤框；`ValueChanged<String>` + 清除按钮；`/` 或 Ctrl+F 聚焦（接键盘导航）。
- 接入：task_manager（已有，改引用）、monitor 网络页（`monitor_app.dart:354` 无过滤）、disk_usage（`128-286` 无过滤）。

### `PauseToggle`
- `bool paused` + 间隔下拉（1s/3s/10s/30s，默认各 app 现值）；暂停时取消 Timer，显「已暂停」chip。
- 接入：task_manager（`_armTimer:147`）、monitor（`:88`）、logs（`_autoRefresh:36`）、containers（`:90`）。

### `LastUpdatedChip`
- 接收 `DateTime? lastTickAt` + `bool live`；显示「更新于 3s 前」+ 活动呼吸点；`live=false`（暂停/断线）置灰。
- 接入：所有轮询 app（task_manager `_loading:165`、monitor 等）。修复「首次后 `_loading` 恒 false，刷新无信号」。

### `SparklineCard`
- 统一 CPU/MEM/网络/GPU 趋势卡：`title` + 当前值 + `List<double> history` + 可选峰值副标题。
- **网络 rx/tx 共享刻度**：`normalize jointly`（max(rx∪tx)），修复 `task_manager_app.dart:1505-1513` 各自归一无法比较。
- 接入：task_manager 性能页/网络页、monitor 资源页、GPU 块（补趋势，`monitor_app.dart:282-294` 现无 history）。

### `confirmDestructiveAction`
见主方案 §2.1。`lib/widgets/destructive_action_dialog.dart`。

### `copyableText` / `CopyMenuItem`
- `CopyMenuItem(label, valueBuilder)` 生成右键菜单「复制」项，`Clipboard.setData`。
- 接入：监控 PID/端口/端点/挂载点（task_manager A8）、sftp 路径（`detail-file-terminal.md` 2.9）。
