# 00 · 共享基础设施

> 三个面板模块共用的底层能力。先落地本章，M2–M4 直接消费。

---

## 1. 特权执行封装：`panelSudoRun`

现有 `RemoteSudo` 是纯工具（命令改写 + 退出码判读），`firewall_app` 在 UI 层手动串了「`sudo -n` → 密码弹窗 → `sudo -S` 重试」。面板写操作很多，抽成统一函数，避免每个模块各写一遍。

**新增** `lib/services/panel_sudo_run.dart`：

```dart
/// 面板特权执行：sudo -n 失败 → 弹密码 → sudo -S 重试 → 判 __EC。
/// [mutateCmd] 已含 `sudo -n ...`；[terminalHint] 用于确认弹窗透明展示。
/// 返回 null=成功，否则错误信息（含 RemoteSudo.authFailed/cancelled 哨兵）。
Future<String?> panelSudoRun(
  BuildContext context,
  RemoteExecCapable exec,
  String mutateCmd, {
  String? terminalHint,
  String? confirmTitle,
  String? confirmContent,
  String? confirmLabel,
}) async {
  if (confirmTitle != null) {
    final ok = await confirmDestructiveAction(
      context,
      title: confirmTitle,
      content: confirmContent,
      confirmLabel: confirmLabel ?? '执行',
      terminalFallback: terminalHint ?? mutateCmd,
    );
    if (!ok) return RemoteSudo.cancelled;
  }
  // 1) 先 sudo -n
  var out = await exec.runQueued(mutateCmd, timeout: const Duration(seconds: 20));
  var err = RemoteSudo.interpretExit(out, usedPassword: false, terminalHint: terminalHint);
  if (err == RemoteSudo.passwordRequired) {
    // 2) 弹密码 → sudo -S 重试
    final pw = await showSudoPasswordDialog(context);
    if (pw == null) return RemoteSudo.cancelled;
    final stdinCmd = RemoteSudo.toStdinCommand(mutateCmd);
    out = await exec.runQueued(stdinCmd,
        timeout: const Duration(seconds: 20),
        stdinBytes: RemoteSudo.passwordStdin(pw));
    err = RemoteSudo.interpretExit(out, usedPassword: true, terminalHint: terminalHint);
  }
  return err;
}
```

> 与 `runFirewallMutate` 同构，但抽到服务层、参数化确认弹窗。`firewall_app` 后续也可迁过来（非本方案强制）。

**复用既有**：`RemoteSudo`、`showSudoPasswordDialog`（`widgets/sudo_password_dialog.dart`）、`confirmDestructiveAction`（`widgets/destructive_action_dialog.dart`）。

---

## 2. 按主机持久化 Store

仿 `DesktopForwardsStore`（`lib/services/desktop_forwards_store.dart`）：用 `SharedPreferences`，key 带主机指纹，重连后按主机还原。

**`panel_websites_store.dart`**：

```dart
class PanelWebsiteDef {
  final String name;          // 站点 id，同时是 conf 文件名
  final List<String> domains; // server_name
  final WebsiteKind kind;     // static | reverseProxy | php
  final String? upstream;     // 反代：http://127.0.0.1:PORT
  final String? root;         // 静态/PHP：/var/www/<name>
  final bool ssl;
  final bool enabled;
  final String confPath;      // /etc/nginx/conf.d/<name>.conf
}
// store: 按 hostKey 存 List<PanelWebsiteDef> JSON
```

**`panel_apps_store.dart`**：

```dart
class PanelAppInstall {
  final String appId;         // catalog.json 里的 id
  final String name;          // 实例名（用户起，唯一）
  final String installDir;    // ~/terminall-apps/<name>/
  final int? port;
  final String version;
  final Map<String, String> params; // 安装时填的参数
  final PanelAppState state;  // installing | running | stopped | failed
}
```

两个 store API 与 `DesktopForwardsStore` 一致：`load(hostKey)` / `save(hostKey, list)` / 增删改。hostKey 复用 forwards store 既有算法（`user@host:port` + protocol）。

---

## 3. 应用目录资产

**`assets/appstore/catalog.json`**（一期内置 ~8 个高频应用）：

```jsonc
[
  {
    "id": "mysql",
    "name": "MySQL",
    "icon": "database",          // 映射 IconData
    "category": "database",
    "version": "8.4",
    "description": "关系型数据库",
    "compose": "version: \"3.8\"\nservices:\n  mysql:\n    image: mysql:{{version}}\n    ...",
    "params": [
      {"key": "rootPassword", "label": "root 密码", "type": "password", "required": true},
      {"key": "port", "label": "端口", "type": "int", "default": 3306}
    ],
    "ports": ["{{port}}:3306"]
  },
  { "id": "redis", ... },
  { "id": "postgresql", ... },
  { "id": "nginx", ... },
  { "id": "wordpress", ... },
  { "id": "minio", ... },
  { "id": "gitea", ... },
  { "id": "vaultwarden", ... }
]
```

模板用 `{{param}}` 占位，安装时替换。`pubspec.yaml` 声明：

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/appstore/catalog.json
    - assets/nginx/
```

---

## 4. Nginx 站点模板资产

`assets/nginx/`：
- `static.conf.tpl` — `root` + `index`
- `reverse_proxy.conf.tpl` — `location / { proxy_pass {{upstream}}; proxy_set_header ...; }`
- `php.conf.tpl` — `location ~ \.php$ { fastcgi_pass unix:/run/php/php-fpm.sock; ... }`

每个模板含 `server { listen 80; server_name {{domains}}; ... }`，渲染时填域名/端口/根目录/SSL 段。

---

## 5. 复用编辑器编辑远端配置

既有 `wm.open(DesktopAppType.editor, args: {'path': '/abs/path'})` 已支持打开远端文件（`EditorApp` 读 `window.args['path']`，经 SFTP 加载）。网站管理「编辑配置」直接调用，无需新建编辑器。

```dart
wm.open(DesktopAppType.editor, args: {'path': site.confPath});
```

---

## 6. 能力探测缓存

三个模块都要先探测远端环境（nginx 在哪、docker 在不在、os 是什么）。抽 `EnvProbe`：

```dart
class PanelEnv {
  final bool hasNginx; final String? nginxVersion; final NginxLayout nginxLayout;
  final bool hasDocker; final bool composeV2; final bool hasCertbot;
  final RemoteOsKind os;
}
// 缓存到 exec（或 store），maxAge 60s，避免每次开窗都探测
```

探测命令见各模块文档。`RemoteOsKind` 复用 `remote_process_list.dart` 既有枚举。

---

## 7. UI 一致性

- 视觉常量统一用 `DesktopUi`（圆角/间距/阴影）、`DesktopGlass`（毛玻璃工具条）。
- 列表/详情/空/错/加载态统一用 `RemoteStateView`（`widgets/remote_state_view.dart`）。
- 破坏性按钮统一红色 + `confirmDestructiveAction`。
- App 入口在 `kAllApps` 注册后自动进入命令面板与任务栏，无需额外接线。
