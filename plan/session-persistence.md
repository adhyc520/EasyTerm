# 会话持久化：退出恢复、会话快照、命令历史

> 现状：应用退出后所有 SSH 连接断开，重新打开需要手动连接。`SessionTabsController` 管理会话标签页但无持久化。`WorkbenchSettingsStore` 保存 UI 设置但不管会话状态。用户每次重启应用都需要重新连接所有主机。

---

## 1. 现状评估

| 模块 | 文件 | 现状 |
|------|------|------|
| 会话标签 | `lib/services/session_tabs_controller.dart` | 管理标签页，`openTab` 创建新连接，无持久化 |
| 会话分屏 | `lib/services/session_pane.dart` | 分屏树结构，纯内存 |
| SSH 连接 | `lib/services/ssh_workspace_controller.dart` | 完整连接生命周期，连接参数（host/port/username/password/key）在 `connect()` 时传入 |
| 主机配置 | `lib/services/host_profiles_store.dart` | 已保存主机（JSON 文件持久化），密码存 `shared_preferences` |
| 设置 | `lib/services/workbench_settings_store.dart` | 全局设置（`shared_preferences`） |
| 桌面布局 | `lib/services/desktop_window_size_store.dart` | 仅记住窗口尺寸，不记住具体窗口布局 |

**关键缺口：**
1. 退出后无法恢复上次打开的所有标签页
2. 无法恢复分屏布局
3. 无法恢复桌面模式下的窗口布局
4. 无命令历史（跨会话）
5. 无会话快照/书签（保存当前会话状态）

---

## 2. 工作流 D1（P0）：退出时保存会话

### 2.1 会话快照数据结构

```dart
class SessionSnapshot {
  String version;           // 快照格式版本
  DateTime createdAt;
  List<TabSnapshot> tabs;
  int activeTabIndex;
}

class TabSnapshot {
  String host;
  int port;
  String username;
  String? savedProfileId; // 关联已保存主机配置
  String title;
  SessionViewMode viewMode; // terminal 或 desktop
  PaneTreeSnapshot? paneTree; // 分屏布局（terminal 模式）
  DesktopLayoutSnapshot? desktopLayout; // 窗口布局（desktop 模式）
}

class PaneTreeSnapshot {
  PaneSnapshot root;
}

class PaneSnapshot {
  PaneType type; // leaf 或 split
  // leaf
  String? paneId;
  // split
  SessionPaneAxis? axis;
  double? ratio;
  List<PaneSnapshot>? children;
}

class DesktopLayoutSnapshot {
  List<DesktopWindowSnapshot> windows;
  int activeWorkspaceIndex;
  List<WorkspaceSnapshot> workspaces;
}

class DesktopWindowSnapshot {
  String appType;
  String title;
  Rect rect;        // 窗口位置和大小
  WindowState state; // normal, minimized, maximized
  int zOrder;
  int workspaceIndex;
  Map<String, dynamic>? args; // 应用特定参数（如文件路径）
}

class WorkspaceSnapshot {
  int id;
  String name;
  List<String> windowIds;
}
```

### 2.2 会话保存时机

```dart
class SessionPersistenceService {
  // 应用退出前保存
  Future<void> saveCurrentSession(SessionTabsController tabs);
  
  // 每次标签变化时自动保存（防抖 5s）
  void autoSave(SessionTabsController tabs);
  
  // 加载上次会话
  Future<SessionSnapshot?> loadLastSession();
  
  // 手动保存命名快照
  Future<void> saveNamedSnapshot(String name, SessionTabsController tabs);
  
  // 列出所有命名快照
  Future<List<NamedSnapshot>> listNamedSnapshots();
  
  // 删除命名快照
  Future<void> deleteNamedSnapshot(String id);
}
```

### 2.3 存储位置

- 自动保存：`~/Library/Application Support/EasyTerm/sessions/autosave.json`（macOS）
- 命名快照：`~/Library/Application Support/EasyTerm/sessions/snapshots/<name>.json`
- 使用 `path_provider` 获取应用数据目录

### 2.4 敏感性处理

- **密码不保存**：快照中的 `password` 字段始终为 null
- 恢复时，如果关联了 `savedProfileId`，从 `HostProfilesStore` 中获取密码
- 如果没有关联配置，弹出连接表单让用户输入凭据

---

## 3. 工作流 D2（P0）：启动时恢复会话

### 3.1 恢复流程

```
应用启动
  ↓
检查 autosave.json 是否存在
  ↓ 存在
弹出「恢复上次会话」对话框
  ├─ [恢复全部] — 恢复所有标签页
  ├─ [选择恢复] — 选择要恢复的标签
  └─ [新建会话] — 不恢复
  ↓
逐标签恢复
  ├─ 从 savedProfileId 查找凭据
  ├─ 凭据存在 → 自动连接
  ├─ 凭据不存在 → 弹出连接表单
  └─ 连接成功 → 恢复分屏/桌面布局
  ↓
连接失败 → 保留标签页占位，显示「重新连接」按钮
```

### 3.2 恢复对话框

```dart
class SessionRestoreDialog extends StatelessWidget {
  // 显示上次会话的标签列表
  // 每个标签有复选框
  // 底部按钮：恢复所选 / 恢复全部 / 新建会话
}
```

### 3.3 分屏恢复

恢复分屏时，递归重建 `PaneTree`：
```dart
PaneTree restorePaneTree(PaneTreeSnapshot snap) {
  if (snap.root.type == PaneType.leaf) {
    return PaneTree.leaf(controller); // 已连接的 controller
  }
  return PaneTree.split(
    axis: snap.root.axis!,
    ratio: snap.root.ratio!,
    children: snap.root.children!.map(restorePaneTree).toList(),
  );
}
```

### 3.4 桌面布局恢复

恢复桌面模式时：

```dart
void restoreDesktopLayout(DesktopLayoutSnapshot snap, DesktopWindowManager wm) {
  // 1. 恢复工作区
  for (final ws in snap.workspaces) {
    wm.addWorkspace(ws.id, ws.name);
  }
  // 2. 恢复窗口
  for (final win in snap.windows) {
    final type = DesktopAppType.values.firstWhere((t) => t.name == win.appType);
    wm.open(type, args: win.args);
    // 恢复位置/大小/状态
    final w = wm.windows.last;
    wm.setWindowRect(w.id, win.rect);
    if (win.state == WindowState.minimized) wm.minimize(w.id);
    if (win.state == WindowState.maximized) wm.maximize(w.id);
  }
  // 3. 切换到活跃工作区
  wm.switchWorkspace(snap.activeWorkspaceIndex);
}
```

---

## 4. 工作流 D3（P1）：命令历史

### 4.1 命令历史收集

在 `SshWorkspaceController` 中监听终端输入，记录命令：

```dart
class CommandHistoryService {
  static const maxHistoryPerHost = 500;
  static const maxHistoryGlobal = 2000;
  
  // 记录命令
  Future<void> recordCommand(String hostKey, String command, String cwd, int exitCode);
  
  // 查询历史
  Future<List<CommandRecord>> getHistory(String hostKey, {int limit = 50, String? query});
  
  // 搜索历史（全文搜索）
  Future<List<CommandRecord>> searchHistory(String query);
  
  // 清除历史
  Future<void> clearHistory(String hostKey);
}

class CommandRecord {
  String id;
  String hostKey;
  String command;
  String cwd;
  int? exitCode;
  DateTime timestamp;
  int durationMs; // 命令执行耗时
}
```

### 4.2 命令历史 UI

- 终端内 `Ctrl+R` 搜索历史（类似 bash 反向搜索）
- 在命令面板中查看历史
- 命令书签可从历史中一键创建

### 4.3 命令历史搜索

```dart
class CommandHistorySearch extends StatelessWidget {
  // 类似终端底部弹出的小搜索框
  // Ctrl+R 打开，输入即搜索，Enter 执行，Esc 关闭
  // 显示匹配的命令列表（带时间戳）
  // 选中后填入终端输入行
}
```

---

## 5. 工作流 D4（P2）：跨设备同步

**暂不做**（P2 优先级低，需要后端服务支撑）。仅在设计上预留接口：

```dart
abstract class SessionSyncBackend {
  Future<void> uploadSnapshot(SessionSnapshot snap);
  Future<SessionSnapshot?> downloadSnapshot();
}
```

---

## 6. 文件清单

### 新建文件
| 文件 | 说明 |
|------|------|
| `lib/services/session_persistence_service.dart` | 会话快照保存/加载 |
| `lib/services/command_history_service.dart` | 命令历史收集与查询 |
| `lib/models/session_snapshot.dart` | 会话快照数据模型 |
| `lib/widgets/session_restore_dialog.dart` | 会话恢复对话框 |
| `lib/widgets/command_history_search.dart` | 命令历史搜索 UI |

### 修改文件
| 文件 | 改动 |
|------|------|
| `lib/services/session_tabs_controller.dart` | 生成/恢复快照的 toJson/fromJson |
| `lib/services/ssh_workspace_controller.dart` | 命令历史钩子、快照 connect 参数导出 |
| `lib/screens/main_shell_screen.dart` | 启动时检查 autosave + 弹出恢复对话框 |
| `lib/main.dart` | 退出前保存会话 |
| `lib/services/session_pane.dart` | 添加 toJson/fromJson 序列化 |
| `lib/desktop/desktop_window_manager.dart` | 添加 toJson/fromJson 序列化 |

---

## 7. 非目标

- 不保存密码/密钥到快照
- 不做跨设备同步（需要后端）
- 不做终端缓冲区内容保存（太大）
- 不做 SSH 隧道/转发状态恢复

---

## 8. 测试

- 单元测试：快照序列化/反序列化、命令历史 CRUD、分屏树 JSON 往返
- Widget 测试：恢复对话框交互、历史搜索 UI
- 集成测试：保存-退出-恢复往返、分屏恢复保真度

---

## 9. 风险

| 风险 | 缓解 |
|------|------|
| 快照文件损坏导致启动白屏 | try-catch 加载，失败时静默忽略 |
| 保存的凭据失效（密码更改） | 恢复时弹出重输凭据对话框 |
| 大快照文件（多窗口） | JSON 压缩 + 限制最大窗口数 |
| 版本升级导致快照不兼容 | 快照带 version 字段，支持迁移 |