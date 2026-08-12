# 服务器面板方案（参考 1Panel，agentless 适配）

> 写在 2026-08-12。目标：在桌面模式中新增「服务器面板」能力——**服务器概览 / 网站管理（反代）/ 应用商店**，对标 1Panel 的核心模块，但完全 **agentless**：不向远端安装任何守护进程，所有操作通过既有 SSH 会话的 `RemoteExecCapable` + SFTP + sudo 完成。

---

## 1. 与 1Panel 的根本差异：Agentless

| 维度 | 1Panel | 本方案（terminall） |
|------|--------|---------------------|
| 架构 | Go agent + SQLite 装在服务器上，Web 前端连 agent | 无 agent；客户端经 SSH 直接驱动 |
| 状态 | 服务端 SQLite | 客户端按主机持久化（SharedPreferences，沿用 `DesktopForwardsStore` 范式） |
| 站点 | Nginx/OpenResty 配置由 agent 读写 | 经 `sudo tee` / SFTP 写 `nginx` 配置，`nginx -t && nginx -s reload` 生效 |
| 应用商店 | agent 内置 compose 仓库 + 安装编排 | 客户端内置目录 JSON（compose 模板），`docker compose up -d` 远端执行 |
| 特权 | agent 以 root 跑 | `RemoteSudo`（`sudo -n` → `sudo -S`）+ 密码弹窗 |
| 反向代理 | Nginx 配置托管 | 同；额外可复用既有「端口转发」做本地预览 |

**结论**：体验对标 1Panel，实现走 SSH 既有通道。优势是零侵入、即开即用、天然多主机；代价是高并发轮询要节制（已有 `RemoteCommandQueue` 串行化兜底），且无后台任务（安装等长操作用流式输出 + 前台窗口承载）。

---

## 2. 模块总览

| 优先级 | 模块 | 对应 1Panel | 桌面 AppType（新增） | 文档 |
|--------|------|-------------|----------------------|------|
| **P0** | 服务器面板（概览） | 概览 / 主机 | `DesktopAppType.panel` | [01-server-dashboard.md](./01-server-dashboard.md) |
| **P0** | 网站管理（反代） | 网站 | `DesktopAppType.websites` | [02-websites.md](./02-websites.md) |
| **P1** | 应用商店 | 应用商店 | `DesktopAppType.appStore` | [03-app-store.md](./03-app-store.md) |
| — | 共享基础设施 | — | — | [00-shared-infra.md](./00-shared-infra.md) |

> 数据库管理（MySQL/PostgreSQL/Redis）一期不单独建模块，作为应用商店目录中的条目安装后，用「容器」/「运行命令」App 管理；二期再评估独立 `DesktopAppType.database`（见各文档「非目标」）。

---

## 3. 架构与数据流

```
┌─────────────────────────── 桌面进程（客户端） ───────────────────────────┐
│                                                                          │
│  panel_dashboard_app  websites_app  app_store_app                        │
│         │                  │                │                            │
│         └────────┬─────────┴────────┬───────┘                            │
│                  ▼                  ▼                                    │
│   remote_host_metrics     remote_websites   remote_appstore   ← 服务层  │
│   (复用 snapshot)         (nginx -T 解析)   (docker compose)             │
│                  │                  │                │                    │
│         ┌────────┴──────────────────┴────────────────┘                   │
│         ▼                                                               │
│   RemoteExecCapable（runQueued / startRemoteStream / snapshot）          │
│   RemoteSudo + sudo_password_dialog + confirmDestructiveAction           │
│         │                                                               │
│   panel_websites_store / panel_apps_store  ← 按主机持久化（SharedPreferences）│
│   assets/appstore/catalog.json             ← 客户端内置目录              │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ SSH（既有会话）
                               ▼
                 远端：nginx / docker / certbot / sudo
```

**执行模型**：
- 读类操作（列表、状态、指标）→ `runQueued`，带 `maxAge` 缓存（复用 `snapshot()` 思路）。
- 流式输出（安装日志、`nginx -t`、`docker compose up`）→ `startRemoteStream`。
- 写/特权类（建站、装卸应用、reload）→ `RemoteSudo` 封装，`__EC:N` 判退出码，失败按 `passwordRequired / authFailed` 走密码弹窗重试，破坏性操作前置 `confirmDestructiveAction`。

---

## 4. 桌面集成点（全部沿用既有机制）

| 集成 | 位置 | 改动 |
|------|------|------|
| 注册 AppType | `desktop_window_manager.dart` `enum DesktopAppType` | +`panel` / `websites` / `appStore` |
| 元数据 | `desktop_app_registry.dart` `kAllApps` | +3 条 `AppMeta`（icon/label/keywords/defaultSize/needs=`{exec}`） |
| 内容工厂 | `remote_desktop_view.dart` `_buildContent` switch | +3 个 case，实例化对应 App |
| 能力过滤 | `appsForCapabilities` | 自动满足（needs 仅 `exec`） |
| 启动入口 | `desktop_taskbar.dart` / `desktop_command_palette.dart` | 随 `kAllApps` 自动出现；面板 Dashboard 作为「主机首屏卡片」推荐入口 |
| 跨 App 联动 | `wm.open(type, args:)` | Dashboard 卡片跳 monitor/tasks/containers/websites/appStore；Websites「编辑配置」→ `wm.open(editor, args:{'path':...})` |
| 资源声明 | `pubspec.yaml` `assets:` | 新增 `assets/appstore/catalog.json` 及 nginx 模板片段 |

---

## 5. 文件清单（预估）

**新建（服务层）**
- `lib/services/remote_websites.dart` — Nginx 探测 / `nginx -T` 解析 / 建站 / SSL / reload
- `lib/services/remote_appstore.dart` — Docker/Compose 探测 / 装卸 / 控制 / 日志
- `lib/services/panel_websites_store.dart` — 按主机持久化站点定义（仿 `DesktopForwardsStore`）
- `lib/services/panel_apps_store.dart` — 按主机持久化已装应用
- `lib/services/panel_dashboard_snapshot.dart` — 概览聚合（网络 IO + Top 进程，扩展 `RemoteHostSnapshot`）

**新建（桌面 App）**
- `lib/desktop/apps/panel_dashboard_app.dart`
- `lib/desktop/apps/websites_app.dart`
- `lib/desktop/apps/app_store_app.dart`

**新建（资源）**
- `assets/appstore/catalog.json` — 应用目录（compose 模板 + 参数 schema）
- `assets/nginx/static.conf.tpl` / `reverse_proxy.conf.tpl` / `php.conf.tpl` — 站点模板

**修改**
- `lib/desktop/desktop_window_manager.dart`（enum）
- `lib/desktop/desktop_app_registry.dart`（kAllApps）
- `lib/desktop/remote_desktop_view.dart`（_buildContent）
- `pubspec.yaml`（assets）

**总计：~8 新建 + 4 修改，约 3500–4500 行。**

---

## 6. 优先级与里程碑

| 里程碑 | 内容 | 依赖 |
|--------|------|------|
| M1 共享地基 | `00-shared-infra`：sudo 封装、持久化 store、目录资产、nginx 编辑器复用 | — |
| M2 服务器面板 | 概览 Dashboard，复用 + 扩展指标，跨 App 卡片 | M1 |
| M3 网站管理 | Nginx 探测 / 建站（静态/反代/PHP）/ SSL / reload / 配置编辑 | M1 |
| M4 应用商店 | 目录 / 一键安装 / 控制 / 日志 / 卸载 | M1 |
| M5 收口 | 命令面板关键词、任务栏图标、错误态统一、`dart analyze` 零 error | M2–M4 |

---

## 7. 非目标（一期不做）

- 不安装任何远端守护进程 / agent / Web 服务（坚持 agentless）。
- 不做面板自身的 Web 入口（这是桌面 App，不是 Web 面板）。
- 不做数据库可视化管理（phpMyAdmin 风格）——经应用商店装 MySQL 后用「运行命令」/「容器」管理。
- 不做面板多用户/权限/审计（由 OS 账号与 sudo 策略承担）。
- 不做站点流量统计（需 agent 长期采集，与 agentless 冲突）。
- 不做集群编排（多主机仅指「多台独立主机各自开面板」，非调度）。

---

## 8. 风险

| 风险 | 缓解 |
|------|------|
| `nginx -T` 在无 sudo 时可能拒读部分 include | 先 `sudo -n nginx -T`，失败走 `RemoteSudo` 密码链路 |
| 不同发行版 Nginx 路径差异（conf.d vs sites-enabled） | 探测阶段识别布局；统一写入 `conf.d/<name>.conf`，兼容性最好 |
| Docker Compose v1(`docker-compose`) vs v2(`docker compose`) | 探测后能力化：优先 v2，回退 v1，UI 标注 |
| 长安装任务 SSH 中断 | 流式输出 + 客户端 store 记录「安装中」态；重连后用 `docker compose ps` 自愈 |
| 高频轮询拥塞 SSH | 沿用 `RemoteCommandQueue`（maxConcurrent=2）+ `maxAge` 缓存 + 手动刷新为主 |
| 破坏性操作误删站点/应用 | 一律 `confirmDestructiveAction` + `terminalFallback` 透明展示命令 |

---

## 详细方案

- [00 共享基础设施](./00-shared-infra.md) — sudo/持久化/确认/目录资产/nginx 编辑器复用
- [01 服务器面板（概览）](./01-server-dashboard.md) — 仪表盘 + 跨 App 跳转
- [02 网站管理（反代）](./02-websites.md) — Nginx 建站 / 反代 / SSL / 配置
- [03 应用商店](./03-app-store.md) — Docker Compose 目录 / 装卸 / 控制
