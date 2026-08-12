# 多主机协同：批量执行、主机分组、SSH Config 导入、跳板机

> 现状：应用支持多标签页连接不同主机，但每个标签完全独立，无法跨主机批量操作。`HostProfilesStore` 管理已保存主机列表，扁平结构无分组/标签。连接方式仅支持直连，无跳板机/代理。SSH config 文件解析已存在（`dartssh2` 支持），但应用未集成导入。

---

## 1. 现状评估

| 模块 | 文件 | 现状 |
|------|------|------|
| 主机配置 | `lib/services/host_profiles_store.dart` | 扁平列表，JSON 文件存储，无分组/标签 |
| 主机模型 | `lib/models/saved_host_profile.dart` | 基本字段：host/port/username/label/password/keyPath |
| SSH 连接 | `lib/services/ssh_workspace_controller.dart` | `SSHClient.connect()` 直连，无跳板机 |
| dartssh2 | 第三方包 `dartssh2: ^2.17.1` | 支持 SSH 协议，支持 `SSHForwarder`（端口转发） |
| 会话标签 | `lib/services/session_tabs_controller.dart` | 多标签管理，独立连接 |

**关键缺口：**
1. 无法同时在多台主机上执行相同命令
2. 主机列表无分组/标签/搜索（仅线性列表）
3. 无法导入 `~/.ssh/config` 已有配置
4. 无跳板机/代理连接支持
5. 无法跨主机比较文件/配置

---

## 2. 工作流 E1（P1）：主机分组与标签

### 2.1 分组模型

```dart
class HostGroup {
  String id;
  String name;
  String? icon;       // emoji 或 Material icon name
  String? color;      // 分组颜色
  List<String> profileIds; // 成员主机 ID
  bool expanded;      // UI 展开状态
  DateTime createdAt;
}

class HostTag {
  String id;
  String name;
  String? color;
}
```

### 2.2 分组存储

扩展 `HostProfilesStore`：

```dart
class HostProfilesStore extends ChangeNotifier {
  // 现有
  List<SavedHostProfile> profiles;
  
  // 新增
  List<HostGroup> groups;
  List<HostTag> tags;
  
  // 分组操作
  Future<void> createGroup(String name);
  Future<void> deleteGroup(String id);
  Future<void> addToGroup(String profileId, String groupId);
  Future<void> removeFromGroup(String profileId, String groupId);
  
  // 标签操作
  Future<void> addTag(String profileId, String tagId);
  Future<void> removeTag(String profileId, String tagId);
  
  // 搜索
  List<SavedHostProfile> search(String query); // 搜索 label/host/username/tag
}
```

### 2.3 侧栏 UI 更新

在 `_ConnectionsRail` 中显示分组：

```
┌──────────────────────────┐
│ 🔍 搜索主机...            │
│ ──────────────────────── │
│ 📁 生产环境 (3)      ▼   │
│   🟢 web-01  root@10.0.1│
│   🟢 web-02  root@10.0.2│
│   ⚪ db-01   root@10.0.3│
│ 📁 测试环境 (2)      ▶   │
│ 📁 个人服务器 (1)    ▶   │
│ ──────────────────────── │
│ 未分组 (2)               │
│   🟢 pi      pi@192.168 │
│   ⚪ vps     root@vps.ex│
└──────────────────────────┘
```

---

## 3. 工作流 E2（P1）：批量执行

### 3.1 批量命令执行

```dart
class BulkCommandExecutor {
  Future<List<BulkCommandResult>> executeOnHosts({
    required List<SshWorkspaceController> hosts,
    required String command,
    required int timeoutSec,
    bool parallel = true, // 并行/串行
    int maxConcurrency = 10,
  });
}

class BulkCommandResult {
  String host;
  int? exitCode;
  String stdout;
  String stderr;
  Duration duration;
  bool timedOut;
  String? error;
}
```

### 3.2 批量执行 UI

在侧栏底部新增「批量操作」按钮，点击后弹出批量操作面板：

```
┌──────────────────────────────────────┐
│ 批量执行命令                           │
│ ──────────────────────────────────── │
│ 目标主机: ☑ web-01  ☑ web-02  ☐ db-01 │
│                                      │
│ 命令:                                 │
│ ┌──────────────────────────────────┐ │
│ │ uptime && free -h                │ │
│ └──────────────────────────────────┘ │
│                                      │
│ □ 并行执行  □ 超时: 30s               │
│                                      │
│ [执行]  [取消]                        │
│                                      │
│ 结果:                                 │
│ ┌ web-01 ──────────────────────────┐ │
│ │ 14:32:15 up 30 days, 2 users     │ │
│ │ total  used  free  shared  buff  │ │
│ │ 7.6G  3.2G  4.4G  0.1G   0.5G   │ │
│ └──────────────────────────────────┘ │
│ ┌ web-02 ──────────────────────────┐ │
│ │ 14:32:16 up 28 days, 1 user      │ │
│ │ ...                              │ │
│ └──────────────────────────────────┘ │
└──────────────────────────────────────┘
```

### 3.3 批量操作面板

```dart
class BulkOperationSheet extends StatefulWidget {
  final SessionTabsController tabs;
  final HostProfilesStore profiles;
  
  // 四种批量操作模式:
  // 1. 执行命令
  // 2. 上传文件
  // 3. 下载文件
  // 4. 检查服务状态
}
```

---

## 4. 工作流 E3（P1）：SSH Config 导入

### 4.1 SSH Config 解析

dartssh2 已支持 SSH config 解析（`SSHConfig` 类），利用它：

```dart
class SshConfigImporter {
  /// 解析 ~/.ssh/config 文件
  Future<List<SshConfigEntry>> parseConfig(String path);
  
  /// 将解析结果转为 SavedHostProfile
  List<SavedHostProfile> toProfiles(List<SshConfigEntry> entries);
  
  /// 导入到 HostProfilesStore
  /// - 冲突处理：跳过同名 / 覆盖 / 创建副本
  Future<ImportResult> importTo(HostProfilesStore store, {
    ConflictResolution conflict = ConflictResolution.skip,
  });
}

class SshConfigEntry {
  String host;
  String hostname;
  int port;
  String user;
  String? identityFile;
  String? proxyJump;
  // ...
}
```

### 4.2 导入 UI

```
┌──────────────────────────────────────────┐
│ 导入 SSH Config                           │
│ ──────────────────────────────────────── │
│ 源文件: ~/.ssh/config                     │
│ 发现 12 个主机配置                         │
│                                          │
│ ☑ web-prod (3 个)                        │
│   ☑ web-01  root@10.0.1.1                │
│   ☑ web-02  root@10.0.1.2                │
│   ☑ web-03  root@10.0.1.3                │
│ ☑ db-prod (2 个)                         │
│   ☑ db-master  admin@10.0.2.1            │
│   ☑ db-slave   admin@10.0.2.2            │
│ ☐ dev (7 个)                             │
│                                          │
│ 冲突处理: ○ 跳过  ○ 覆盖  ● 创建副本       │
│                                          │
│ [导入选中]  [导入全部]  [取消]             │
└──────────────────────────────────────────┘
```

### 4.3 自动发现

每次启动时，如果 `HostProfilesStore` 为空（首次使用），自动提示导入 `~/.ssh/config`。

---

## 5. 工作流 E4（P2）：跳板机/代理

### 5.1 跳板机连接模型

```dart
class ProxyConfig {
  ProxyType type;
  String host;
  int port;
  String username;
  String? password;
  String? privateKeyPem;
}

enum ProxyType {
  sshJump,      // SSH 跳板机 (ProxyJump)
  sshTunnel,    // SSH 隧道 (ProxyCommand)
  socks5,       // SOCKS5 代理
  http,         // HTTP 代理
}
```

### 5.2 SSH 跳板机实现

利用 dartssh2 的端口转发能力：

```dart
Future<SSHClient> connectViaJumpHost({
  required String targetHost,
  required int targetPort,
  required ProxyConfig jumpHost,
}) async {
  // 1. 连接跳板机
  final jumpClient = await SSHClient.connect(
    jumpHost.host,
    jumpHost.port,
    username: jumpHost.username,
    onPasswordRequest: () => jumpHost.password ?? '',
  );
  
  // 2. 通过跳板机建立到目标主机的 TCP 转发
  final forward = await jumpClient.forwardTo(targetHost, targetPort);
  
  // 3. 通过转发通道建立 SSH 连接
  final targetClient = await SSHClient.connect(
    'localhost',
    0, // 通过 forward 连接
    username: username,
    onPasswordRequest: () => password ?? '',
  );
  
  return targetClient;
}
```

### 5.3 连接表单更新

在 `ConnectionSheet` 中新增「高级」折叠区域：

```
┌──────────────────────────────────────┐
│ 基本                                  │
│ 主机: [            ]  端口: [22]      │
│ 用户: [            ]                  │
│ 密码: [            ]                  │
│ 密钥: [选择文件  ]                    │
│                                      │
│ ▶ 高级                                │
│   跳板机: [无 ▼]                      │
│   代理: [无 ▼]                        │
│   连接超时: [30]s                     │
│   重试次数: [3]                       │
└──────────────────────────────────────┘
```

---

## 6. 工作流 E5（P2）：跨主机文件比较

### 6.1 文件比较

```dart
class CrossHostFileComparer {
  /// 比较两台主机上的文件
  Future<FileDiffResult> compareFiles({
    required SshWorkspaceController hostA,
    required String pathA,
    required SshWorkspaceController hostB,
    required String pathB,
  });
}
```

### 6.2 比较 UI

在 SFTP 文件浏览器中，右键文件 → 「与另一主机比较」→ 选择目标主机和路径 → 在 diff 视图中显示。

**暂做简版：** 仅显示 unified diff 文本，不做语法高亮的并排 diff 视图。

---

## 7. 文件清单

### 新建文件
| 文件 | 说明 |
|------|------|
| `lib/services/bulk_command_executor.dart` | 批量命令执行器 |
| `lib/services/ssh_config_importer.dart` | SSH config 解析与导入 |
| `lib/services/proxy_connector.dart` | 跳板机/代理连接 |
| `lib/widgets/bulk_operation_sheet.dart` | 批量操作面板 |
| `lib/widgets/ssh_config_import_dialog.dart` | SSH config 导入对话框 |
| `lib/widgets/host_group_editor.dart` | 主机分组编辑 |
| `lib/widgets/cross_host_diff_view.dart` | 跨主机文件比较 |

### 修改文件
| 文件 | 改动 |
|------|------|
| `lib/services/host_profiles_store.dart` | 新增分组/标签/搜索 |
| `lib/models/saved_host_profile.dart` | 新增 proxyConfig、tags 字段 |
| `lib/widgets/connection_sheet.dart` | 新增高级选项（跳板机/代理） |
| `lib/screens/main_shell_screen.dart` | 侧栏分组 UI + 批量操作入口 |
| `lib/services/ssh_workspace_controller.dart` | 支持跳板机连接流程 |

---

## 8. 非目标

- 不做集群管理（Kubernetes/Docker Swarm）
- 不做自动化运维（Ansible 风格 playbook）
- 不做实时同步（rsync 风格）
- 不做配置管理数据库（CMDB）

---

## 9. 测试

- 单元测试：SSH config 解析、分组 CRUD、批量执行结果收集
- Widget 测试：导入对话框、批量操作面板、分组 UI
- 集成测试：跳板机连接（需要测试环境）

---

## 10. 风险

| 风险 | 缓解 |
|------|------|
| SSH config 解析与 dartssh2 不兼容 | 先做兼容解析，不支持的指令静默跳过 |
| 跳板机连接不稳定 | 与普通连接相同的重试机制 |
| 批量执行输出过长 | 限制每个主机输出最大 1000 行，可展开查看完整输出 |
| 密码/密钥在跳板机上传递 | 不在日志中打印凭据，跳板机连接仅转发 TCP 流量 |