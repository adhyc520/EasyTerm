# 02 · 网站管理（反代管理）

> 对标 1Panel「网站」。新建 `DesktopAppType.websites`。基于 **Nginx**（含 OpenResty）做站点生命周期：静态托管 / 反向代理 / PHP-FPM，含 SSL（certbot/自签）与配置编辑。Agentless：配置经 `sudo tee` 写入，`nginx -t && nginx -s reload` 生效。

---

## 1. 目标

- 探测 Nginx 布局，列出既有站点（server_name / 类型 / SSL / 状态）。
- 创建站点：三种类型（静态 / 反向代理 / PHP）。
- 操作：启用/停用、编辑配置（复用编辑器）、删除、申请 SSL、查访问日志。
- 站点定义按主机持久化（`panel_websites_store`），重连还原。

## 2. Nginx 布局探测

```sh
# 一次 runQueued
echo __NGX_BIN__; command -v nginx; command -v openresty
echo __NGX_VER__; (nginx -v 2>&1 || openresty -v 2>&1)
echo __NGX_CONF__; nginx -T 2>&1 | head -n 1   # 测试可读性（可能需 sudo）
ls -d /etc/nginx/conf.d /etc/nginx/sites-enabled /www/server/panel/vhost/nginx 2>/dev/null
```

`PanelEnv.nginxLayout` 归一为：

| 布局 | 写入路径 | 说明 |
|------|----------|------|
| `confD` | `/etc/nginx/conf.d/<name>.conf` | Debian/Ubuntu/Alpine 通用，默认选择 |
| `sitesEnabled` | `/etc/nginx/sites-available/<name>.conf` + 软链 `sites-enabled` | Debian 旧式 |
| `openResty` | `/usr/local/openresty/nginx/conf/conf.d/<name>.conf` | OpenResty |
| `none` | - | 未装 Nginx，引导「去应用商店安装 Nginx」 |

> 一期统一写 `conf.d`（兼容性最好，`nginx.conf` 默认 `include conf.d/*.conf`）。探测到 `sites-enabled` 也仅作展示，不强制切换。

## 3. 站点列表：解析 `nginx -T`

`nginx -T` dump 全量配置（含 include 的 vhost），是最稳的列表来源（1Panel 同思路）。

```sh
sudo -n nginx -T 2>/dev/null || nginx -T 2>/dev/null
```

解析每个 `server { ... }` 块，提取：
- `server_name` -> 域名（多域名空格分隔）
- `listen` -> 80 / 443 ssl
- `proxy_pass` 存在 -> `reverseProxy`，取 upstream
- `root` 存在 + `fastcgi_pass` -> `php`；仅 `root` -> `static`
- 配置文件路径（`# configuration file /etc/nginx/conf.d/x.conf:` 行）

解析用正则 + 大括号配平（不引完整 nginx 语法树，过度工程）。与 `remote_firewall.dart` 的行解析风格一致。

## 4. 站点模板（assets/nginx/）

### `reverse_proxy.conf.tpl`
```nginx
server {
    listen 80;
    server_name {{domains}};
    location / {
        proxy_pass {{upstream}};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    access_log /var/log/nginx/{{name}}.access.log;
    error_log  /var/log/nginx/{{name}}.error.log;
}
```

`static.conf.tpl`（`root {{root}}; index index.html;`）与 `php.conf.tpl`（追加 `location ~ \.php$ { fastcgi_pass ...; }`）同理。

渲染：客户端读资产 -> 替换 `{{domains}}/{{upstream}}/{{root}}/{{name}}` -> 经 `panelSudoRun` 写入。

## 5. 写操作命令

### 创建 / 编辑站点
```sh
# 1) 写配置（sudo tee，stdin 传内容）
sudo -n tee /etc/nginx/conf.d/<name>.conf > /dev/null <<'PANEL_EOF'
<渲染后的 conf>
PANEL_EOF
# 2) 测试配置
sudo -n nginx -t 2>&1; echo __EC:$?
# 3) 失败回滚：备份旧 conf（写前 cat 备份到 /tmp），失败则恢复
# 4) 成功 reload
sudo -n nginx -s reload 2>&1; echo __EC:$?
```

> **写前备份**：`sudo -n cat /etc/nginx/conf.d/<name>.conf > /tmp/<name>.conf.bak`（存在则备份）。`nginx -t` 失败自动恢复备份并提示，避免把 Nginx 搞挂。

### 启用/停用
- 停用：`sudo -n mv <conf> <conf>.disabled && sudo -n nginx -s reload`（`.disabled` 不被 `include *.conf` 匹配）。
- 启用：反向 mv。

### 删除
```sh
sudo -n rm /etc/nginx/conf.d/<name>.conf && sudo -n nginx -s reload
```
前置 `confirmDestructiveAction`，`terminalFallback` 透明展示。

### SSL
- **certbot**（推荐）：`sudo -n certbot --nginx -d <domain> -n --redirect --agree-tos -m <email> 2>&1`；探测 `command -v certbot`，未装则提示。
- **自签**（无域名/内网）：`sudo -n openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/nginx/ssl/<name>.key -out /etc/nginx/ssl/<name>.crt -subj "/CN=<domain>"` + 改 conf 加 `listen 443 ssl; ssl_certificate ...;`。

### 查日志
`startRemoteStream('sudo -n tail -n 200 -f /var/log/nginx/<name>.access.log')`，UI 复用既有流式日志视图（`logs_app` 同款）。

## 6. 数据流

```
列表: nginx -T 解析 ──merge──> panel_websites_store(本地备注: 类型/备注)
                                      │
创建: 表单 -> 渲染模板 -> panelSudoRun(tee) -> nginx -t -> reload -> store.add
编辑: editor App 打开 confPath ──保存──> nginx -t -> reload（编辑器已有保存；面板提供「校验&重载」按钮）
删除: confirmDestructiveAction -> rm -> reload -> store.remove
```

> store 与 `nginx -T` 真值对账：开窗时以 `nginx -T` 为准，store 仅存本地备注（如自定义标签），站点被外部删除则自动剔除 store 条目。

## 7. UI 布局

```
┌─ 网站管理 · user@host ───────────────────── [+ 建站] [刷新] ┐
│ ┌─ 站点列表 ────────────┐ ┌─ 详情 / 操作 ────────────────┐ │
│ │ ● site-a  反代 :3000   │ │ 域名: a.example.com          │ │
│ │   a.example.com  SSL   │ │ 类型: 反向代理 -> :3000      │ │
│ │ ● site-b  静态         │ │ SSL: ✅ certbot              │ │
│ │   b.example.com        │ │ 配置: /etc/nginx/conf.d/...  │ │
│ │ ○ site-c  (停用)       │ │ [编辑配置] [启用/停用]       │ │
│ │                        │ │ [申请SSL] [查日志] [删除]    │ │
│ └────────────────────────┘ └──────────────────────────────┘ │
│ Nginx 8.1 · conf.d 布局 · [去应用商店安装 Nginx](未装时)     │
└──────────────────────────────────────────────────────────────┘
```

### 建站表单
- 站点名（英文 id，作文件名）
- 域名（多行/逗号）
- 类型选择：静态 / 反向代理 / PHP
  - 反向代理：upstream（`http://127.0.0.1:PORT`，端口可联动「端口转发」已有列表提示）
  - 静态/PHP：根目录（默认 `/var/www/<name>`，可用文件管理器选）
- SSL：无 / certbot / 自签
- 预览生成的配置（只读）-> 确认创建

## 8. AppMeta 注册

```dart
AppMeta(
  DesktopAppType.websites,
  Icons.language_rounded,        // 或 web_rounded
  '网站管理',
  ['website', 'nginx', 'reverse proxy', '反代', '站点'],
  defaultSize: Size(860, 580),
  needs: {RemoteCapability.exec},
),
```

> `needs` 只要求 `exec`（`tee`/`nginx` 经 sudo 即可）；若会话带 `file` 能力，建站表单的「选目录」可用 SFTP 文件管理器，否则手填路径。

## 9. 实现 checklist

- [ ] `remote_websites.dart`：探测、`nginx -T` 解析、建/删/启停/SSL 命令构造。
- [ ] `panel_websites_store.dart`。
- [ ] `assets/nginx/*.tpl` + pubspec 声明。
- [ ] `websites_app.dart`：列表/详情/建站表单/日志流/编辑器联动。
- [ ] 写前备份 + `nginx -t` 失败回滚。
- [ ] 注册 enum + `AppMeta` + `_buildContent` case。
- [ ] `dart analyze lib` 零 error。

## 10. 非目标

- 不支持 Apache/LiteSpeed/Caddy（一期仅 Nginx；Caddy 可二期，自动 HTTPS 更省心）。
- 不做伪静态规则库 UI（直接编辑配置更灵活，规则库可二期）。
- 不做流量统计（agentless 限制）。
- 不托管 PHP 版本切换（由应用商店装 PHP-FPM，配置里手填 fastcgi 路径）。
