# 01 · 服务器面板（概览 Dashboard）

> 对标 1Panel「概览」。新建 `DesktopAppType.panel`，作为主机首屏：聚合指标 + 跨 App 跳转卡片。**最大化复用既有 `RemoteHostSnapshot`**，仅补网络 IO 与 Top 进程。

---

## 1. 目标

- 一屏看到：主机信息、CPU/内存/磁盘/负载/运行时长、磁盘分区、网络 IO、Top 进程。
- 卡片式跳转：监控、任务管理器、容器、网站管理、应用商店、防火墙、日志。
- 手动刷新为主 + 可选低频自动刷新（≥10s，受 `RemoteCommandQueue` 节流）。

## 2. 数据来源

| 指标 | 来源 | 说明 |
|------|------|------|
| CPU/内存/磁盘/inode/负载/运行时长/主机/分区 | `exec.snapshot(maxAge: 5s)` | **直接复用** `RemoteHostSnapshot`（已解析 Linux+Windows） |
| 网络 IO（每接口 rx/tx） | 新增 `panel_dashboard_snapshot.dart` | `cat /proc/net/dev`（Linux）/ PowerShell `Get-NetAdapterStatistics`（Windows） |
| Top 进程（CPU/内存 Top5） | 新增 | `ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu \| head -n 6`（Linux）/ `Get-Process`（Windows） |
| 容器数 / 站点数 / 已装应用数 | 轻探测 | `docker ps -q \| wc -l`；站点数读 `panel_websites_store`；应用数读 `panel_apps_store`（纯本地，不请求远端） |

> 复用既有 snapshot 的多段标记解析范式（`__A__..__Z__`），网络/进程段追加独立标记，避免改坏既有解析。

## 3. 命令清单

```sh
# 概览聚合（一次 runQueued，拼接；Linux）
echo __NET__; cat /proc/net/dev 2>/dev/null
echo __TOP__; ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -n 6
```

Windows 分支沿用既有 PowerShell 模式（`__WA__..__WZ__` 风格），见 `remote_host_metrics.dart` 既有实现。

## 4. UI 布局

```
┌─ 服务器面板 · user@host ──────────────────────────────── [刷新] ┐
│ ┌─ 主机信息 ───────────┐ ┌─ 运行时长 / 负载 ──────────────────┐ │
│ │ hostInfoLine         │ │ uptimeLine   loadLine              │ │
│ │ kernel · os · arch   │ │ loadPressure 进度条                │ │
│ └──────────────────────┘ └────────────────────────────────────┘ │
│ ┌─ CPU ──────┐ ┌─ 内存 ─────┐ ┌─ 磁盘 ─────┐ ┌─ inode ────┐    │
│ │ 环形  cpu% │ │ 环形 mem%  │ │ 环形 disk% │ │ 环形 ino%  │    │
│ └────────────┘ └────────────┘ └────────────┘ └────────────┘    │
│ ┌─ 磁盘分区 ────────────────┐ ┌─ 网络 IO ────────────────────┐ │
│ │ mounts: dev size used%    │ │ eth0 rx/tx  lo rx/tx         │ │
│ └───────────────────────────┘ └──────────────────────────────┘ │
│ ┌─ Top 进程 ─────────────────────────────────────────────────┐ │
│ │ PID  USER  %CPU  %MEM  COMMAND                            │ │
│ └────────────────────────────────────────────────────────────┘ │
│ ┌─ 快捷入口 ─────────────────────────────────────────────────┐ │
│ │ [监控] [任务管理器] [容器] [网站管理] [应用商店] [防火墙]    │ │
│ │ [日志] [磁盘占用] [计划任务] [用户与组] [端口转发]           │ │
│ └────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

- 环形图用 `CustomPainter`（轻量，不引第三方）；颜色取 `WorkbenchColors`。
- 卡片用 `DesktopUi.rMd` + `softShadow`。
- 快捷入口点击 -> `wm.open(DesktopAppType.xxx)`；不可用（capability 不足）置灰。
- 掉线/连接中 -> `RemoteStateView` 占位（与既有 App 一致）。

## 5. 跨 App 联动

```dart
wm.open(DesktopAppType.monitor);
wm.open(DesktopAppType.websites);
wm.open(DesktopAppType.appStore);
// 容器/防火墙/日志 等已有，直接跳
```

Dashboard 本身只读、无破坏性操作，**无需 sudo**。

## 6. AppMeta 注册

```dart
AppMeta(
  DesktopAppType.panel,
  Icons.dashboard_rounded,
  '服务器面板',
  ['panel', 'dashboard', 'overview', '概览', '面板'],
  defaultSize: Size(880, 620),
  needs: {RemoteCapability.exec},
),
```

## 7. 实现 checklist

- [ ] `panel_dashboard_snapshot.dart`：网络 IO + Top 进程解析（Linux/Windows）。
- [ ] `panel_dashboard_app.dart`：状态管理（`_loading/_error/_snap/_net/_top`）、刷新、自动刷新开关。
- [ ] 环形指标卡片 + 分区表 + 网络表 + 进程表。
- [ ] 快捷入口网格（按 `appsForCapabilities(controller.capabilities)` 过滤可用项）。
- [ ] 注册 enum + `AppMeta` + `_buildContent` case。
- [ ] `dart analyze lib` 零 error。

## 8. 非目标

- 不做历史曲线/长期采集（需 agent，与 agentless 冲突）；实时环形图即可。
- 不做告警/阈值通知。
- 不替代「监控」App（监控是连续流式；面板概览是快照 + 入口）。
