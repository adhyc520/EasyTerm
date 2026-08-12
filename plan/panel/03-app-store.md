# 03 · 应用商店

> 对标 1Panel「应用商店」。新建 `DesktopAppType.appStore`。基于 **Docker Compose**：客户端内置目录（compose 模板），一键安装到远端 `~/terminall-apps/<name>/`，支持启停/日志/卸载/升级。Agentless：纯 `docker compose` CLI 驱动。

---

## 1. 目标

- 浏览内置应用目录（分类/搜索）。
- 一键安装：填参数 -> 生成 compose.yml -> `docker compose up -d`。
- 管理已装：列表 + 启停/重启/卸载/查日志/看端口。
- 升级：`docker compose pull && up -d`。
- 已装实例按主机持久化（`panel_apps_store`），重连还原 + 用 `docker compose ps` 自愈状态。

## 2. Docker/Compose 探测

```sh
echo __DK__; command -v docker; docker version --format '{{.Server.Version}}' 2>&1
echo __CMP_V2__; docker compose version 2>&1
echo __CMP_V1__; command -v docker-compose; docker-compose version 2>&1
```

`PanelEnv`：`hasDocker` / `composeV2`（优先 `docker compose`）/ `composeV1`（回退 `docker-compose`）。二者皆无 -> 引导「服务器需安装 Docker」。

> Compose 命令统一封装：`composeCmd(installDir, args)` -> v2 返回 `docker compose --project-directory <dir> <args>`，v1 返回 `docker-compose -f <dir>/docker-compose.yml <args>`。

## 3. 目录资产（assets/appstore/catalog.json）

见 [00-shared-infra.md §3](./00-shared-infra.md)。一期 8 个：`mysql` `redis` `postgresql` `nginx` `wordpress` `minio` `gitea` `vaultwarden`。每条含 `compose` 模板字符串 + `params` schema + `ports`。

### compose 模板示例（mysql）
```yaml
version: "3.8"
services:
  mysql:
    image: mysql:{{version}}
    container_name: terminall-{{name}}
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: {{rootPassword}}
    ports:
      - "{{port}}:3306"
    volumes:
      - ./data:/var/lib/mysql
```

`{{name}}` = 实例名；`{{version}}` = 目录版本；其余来自参数表单。

## 4. 安装流程

```
表单(填参数) 
  -> 客户端渲染 compose.yml（替换 {{}}）
  -> 确保远端目录：sudo -n mkdir -p ~/terminall-apps/<name> && sudo -n chown $USER ~/terminall-apps/<name>
  -> 写 docker-compose.yml（tee / SFTP）
  -> compose up -d（startRemoteStream，流式显示拉镜像/起容器）
  -> 成功: store.add(state=running); 失败: store.add(state=failed) + 保留日志
```

> 目录用 `$HOME` 下，`chown` 当前用户，**避免容器数据卷用 root 持久化导致后续难清理**。若 `$USER` 不可用则回退 `sudo` 全程。

## 5. 控制命令

| 操作 | 命令 |
|------|------|
| 状态 | `compose -f <dir>/docker-compose.yml ps -a --format json` |
| 启动 | `compose ... start` |
| 停止 | `compose ... stop` |
| 重启 | `compose ... restart` |
| 日志 | `compose ... logs --tail=300 -f`（startRemoteStream） |
| 升级 | `compose ... pull && compose ... up -d` |
| 卸载 | `compose ... down -v` + `rm -rf <dir>`（**破坏性**，确认弹窗 + `terminalFallback`） |

端口映射从 `compose ps` 或目录 `ports` 字段读，点击可「加入端口转发」（联动 `forwards_app`：`wm.open(DesktopAppType.forwards, args:{'host':'127.0.0.1','port':port})`）。

## 6. 状态自愈

SSH 中断 / App 重开时：
1. 读 `panel_apps_store` 得本地已装清单。
2. 对每条 `compose ps` 探测真实状态。
3. 不在远端（被外部删除）-> 标记 `orphaned`，提示清理本地记录。
4. 远端有但本地无 -> 可「导入」（解析 compose.yml 回填 store）。

## 7. UI 布局

```
┌─ 应用商店 · user@host ──────────────────────────────────────┐
│ [目录] [已装]   🔍 搜索          Docker 27.0 · compose v2   │
│ ┌─ 目录（分类: 数据库 / Web / 工具 / 博客）─────────────────┐ │
│ │ [MySQL] [Redis] [PostgreSQL] [Nginx]                      │ │
│ │ [WordPress] [Minio] [Gitea] [Vaultwarden]                │ │
│ │ 点卡片 -> 右侧详情/安装表单                                │ │
│ └──────────────────────────────────────────────────────────┘ │
│ ┌─ 详情 ───────────────────────────────────────────────────┐ │
│ │ MySQL 8.4  关系型数据库                                  │ │
│ │ 参数: root密码[___] 端口[3306] 实例名[mysql1]            │ │
│ │ [安装]   预览 compose.yml                                │ │
│ └──────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### 已装视图
```
┌─ 已装 ─────────────────────────────────────────────────────┐
│ ● mysql1   MySQL 8.4   :3306   running   [日志][停止][升级][卸载] │
│ ● redis1   Redis 7     :6379   running   [日志][停止][升级][卸载] │
│ ○ gitea1   Gitea       :3000   stopped   [日志][启动][升级][卸载] │
└────────────────────────────────────────────────────────────┘
```

安装中 -> 流式日志面板（`startRemoteStream` 输出，复用 `logs_app` 流式视图风格）。

## 8. AppMeta 注册

```dart
AppMeta(
  DesktopAppType.appStore,
  Icons.store_rounded,
  '应用商店',
  ['app store', 'apps', 'docker', 'compose', '应用商店', '安装'],
  defaultSize: Size(900, 600),
  needs: {RemoteCapability.exec},
),
```

## 9. 与其他模块联动

- **网站管理**：装 Nginx/WordPress 后，网站管理可建反代到其端口。
- **端口转发**：应用端口一键加入本地转发（`wm.open(DesktopAppType.forwards, ...)`）。
- **容器**：进阶用户可跳「容器」App 直接操作底层容器（`wm.open(DesktopAppType.containers)`）。
- **服务器面板**：Dashboard 显示已装应用数，卡片跳应用商店。

## 10. 实现 checklist

- [ ] `remote_appstore.dart`：探测、compose 命令封装、装卸/控制/日志/升级。
- [ ] `panel_apps_store.dart`。
- [ ] `assets/appstore/catalog.json`（8 条）+ pubspec 声明。
- [ ] `app_store_app.dart`：目录/已装两栏、安装表单、流式日志、状态自愈。
- [ ] 破坏性卸载确认 + `terminalFallback`。
- [ ] 注册 enum + `AppMeta` + `_buildContent` case。
- [ ] `dart analyze lib` 零 error。

## 11. 非目标

- 不做应用备份/迁移（需打包数据卷 + 传输，二期）。
- 不做应用配置可视化编辑（一期靠编辑 compose.yml，可复用编辑器打开 `~/terminall-apps/<name>/docker-compose.yml`）。
- 不做第三方应用源/在线市场（一期内置目录）。
- 不做资源配额模板（用户自行编辑 compose 的 deploy.resources）。
- 不替代「容器」App（应用商店是高层编排；容器 App 仍是底层直操作）。
