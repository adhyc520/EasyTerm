# 桌面完形：工作区动画、Exposé、桌面小部件、Snap 布局

> 现状：`DesktopWindowManager` 支持窗口打开/关闭/拖拽/缩放/8 区平铺/snap 预览/循环聚焦/最小化/最大化/还原。`DesktopTaskbar` 有启动器和窗口按钮，无时钟/托盘/显示桌面。工作区配置存在 `DesktopSettingsStore` 但运行时行为不完整。计划 1 提出但未完成：always-on-top、工作区、Exposé、托盘、桌面右键菜单。

---

## 1. 现状评估

| 模块 | 文件 | 现状 |
|------|------|------|
| 窗口管理器 | `lib/desktop/desktop_window_manager.dart` | 完整的窗口生命周期，但 `DesktopWorkspace` 仅存 ID/name，切换逻辑未实现 |
| 任务栏 | `lib/desktop/desktop_taskbar.dart` | 启动器 + 窗口按钮，无时钟/托盘/显示桌面/右键菜单 |
| 桌面视图 | `lib/desktop/remote_desktop_view.dart` | 背景 + 窗口层 + 任务栏，有桌面右键菜单骨架 |
| 桌面设置 | `lib/services/desktop_settings_store.dart` | 工作区数/snap/网格/壁纸/任务栏自动隐藏，但 `trayShowClock`、`trayShowMetrics` 未被使用 |
| 命令面板 | `lib/desktop/desktop_command_palette.dart` | 应用启动器，已实现 |
| 窗口框架 | `lib/desktop/desktop_window_frame.dart` | 标题栏 + 调整大小手柄 |

**关键缺口：**
1. 工作区创建/切换/移动窗口无实际行为
2. 无窗口 Exposé/概览（所有窗口缩略图平铺）
3. 任务栏无时钟、系统托盘、一键显示桌面
4. 无 Snap 布局选择器（拖到顶部最大化，拖到侧边半屏 —— 已有 snap 预览，无反选布局 UI）
5. 桌面右键菜单仅骨架（:87-94）
6. 无桌面小部件（时钟、系统监控、快捷操作）

---

## 2. 工作流 C1（P0）：工作区运行时

### 2.1 工作区数据结构

扩展 `DesktopWorkspace`：

```dart
class DesktopWorkspace {
  final int id;
  String name;
  final List<DesktopWindow> windows = [];
  
  // 工作区专用背景（可选）
  String? wallpaper;
  
  // 工作区最后活跃时间
  DateTime lastActive;
}
```

### 2.2 工作区切换

```dart
// DesktopWindowManager
int _activeWorkspaceIndex = 0;

void switchWorkspace(int index) {
  if (index < 0 || index >= workspaces.length) return;
  _activeWorkspaceIndex = index;
  notifyListeners();
}

void moveWindowToWorkspace(String windowId, int targetWorkspaceIndex) {
  final win = findWindow(windowId);
  if (win == null) return;
  final source = _workspaceOf(win);
  source.windows.remove(win);
  workspaces[targetWorkspaceIndex].windows.add(win);
  notifyListeners();
}
```

### 2.3 切换动画

在 `RemoteDesktopView` 中实现工作区切换过渡动画：

```dart
// 滑动切换（左右滑动 300ms）
AnimatedSwitcher / SlideTransition
// 或淡入淡出（200ms）
FadeTransition
```

### 2.4 快捷键

- `Cmd+1..9` — 切换到工作区 1-9
- `Cmd+Shift+1..9` — 移动当前窗口到工作区 1-9
- `Ctrl+←/→` — 切换到上一个/下一个工作区

**注意：** macOS 上 `Cmd+1..9` 被系统占用（切换标签页），改为 `Ctrl+1..9`。

---

## 3. 工作流 C2（P1）：窗口 Exposé

### 3.1 触发方式

- 热角（鼠标移到屏幕左上角）—— 暂不做，太复杂
- 快捷键 `Cmd+E`（macOS 风格）或 `Ctrl+↑`
- 任务栏按钮「显示桌面」

### 3.2 Exposé 视图

```
┌──────────────────────────────────────────────────┐
│  ┌──────────┐ ┌──────────┐ ┌──────────┐         │
│  │ Terminal  │ │  Files   │ │  Editor  │         │
│  │ ~/projects│ │  /etc    │ │ nginx.cnf│         │
│  └──────────┘ └──────────┘ └──────────┘         │
│  ┌──────────┐ ┌──────────┐                       │
│  │ Monitor  │ │  Logs    │                       │
│  │ CPU 45%  │ │ nginx    │                       │
│  └──────────┘ └──────────┘                       │
│                                                    │
│  工作区 1: 默认  [1] [2] [3]                       │
└──────────────────────────────────────────────────┘
```

每个窗口渲染为缩略图卡片（实时内容或截图），点击切换到该窗口，底部显示工作区列表。

### 3.3 实现方案

```dart
class DesktopExposeOverlay extends StatefulWidget {
  final DesktopWindowManager wm;
  final VoidCallback onClose;
  
  // 为每个窗口生成缩略图
  // 使用 RepaintBoundary + 截图
  // 或直接缩放渲染窗口内容
}
```

**简化方案：** 不取实时截图，用窗口标题 + 应用类型图标 + 窗口尺寸描述作为缩略图卡片。这样实现简单且性能好。

---

## 4. 工作流 C3（P1）：任务栏完形

### 4.1 系统托盘（右侧）

```
┌──────────────────────────────────────────────────────────┐
│ [🚀] [Term] [Files] [Mon] [Logs] ...  🕐 14:32  [📊] [🗔] │
└──────────────────────────────────────────────────────────┘
```

- **时钟**：显示当前时间（HH:MM），点击显示完整日期
- **系统指标**：小图标显示 CPU/内存状态（仅在 `trayShowMetrics=true` 时）
- **显示桌面**：点击最小化所有窗口，再点恢复

### 4.2 任务栏自动隐藏

```dart
// 当 taskbarAutohide=true 时
// 任务栏默认隐藏，鼠标移到屏幕底部边缘时滑出
AnimatedContainer(
  height: _visible ? 48 : 0,
  duration: Duration(milliseconds: 200),
  curve: Curves.easeOutCubic,
)
```

### 4.3 窗口按钮右键菜单

```dart
// 右键窗口按钮弹出菜单
PopupMenuButton:
  - 关闭
  - 最小化
  - 最大化
  - 移动到工作区 →
  - 始终置顶
```

---

## 5. 工作流 C4（P1）：Snap 布局选择器

### 5.1 触发方式

窗口拖到屏幕顶部边缘 → 显示 Snap 布局选择器（Windows 11 风格）：

```
┌──────────────────────────────────────┐
│  ┌──────┬──────┐  ┌──────┬──────┬──┐ │
│  │      │      │  │      │      │  │ │
│  │  ½   │  ½   │  │  ⅓   │  ⅓   │⅓ │ │
│  └──────┴──────┘  └──────┴──────┴──┘ │
│  ┌──────┬──────┐  ┌──────┬──────────┐│
│  │      │      │  │      │          ││
│  │  ⅔   │  ⅓   │  │  ⅓   │    ⅔     ││
│  └──────┴──────┘  └──────┴──────────┘│
└──────────────────────────────────────┘
```

### 5.2 实现方案

```dart
class SnapLayoutPicker extends StatelessWidget {
  // 显示在屏幕顶部中央
  // 鼠标悬停高亮对应区域
  // 点击选择布局
  // 当前窗口填充到选中区域
}

enum SnapLayout {
  halfLeft, halfRight,
  halfTop, halfBottom,
  thirdLeft, thirdCenter, thirdRight,
  twoThirdsLeft, oneThirdRight,
  oneThirdLeft, twoThirdsRight,
  quarterTopLeft, quarterTopRight, quarterBottomLeft, quarterBottomRight,
}
```

### 5.3 现有 Snap 集成

当前 `DesktopWindowManager` 已有 8 区 snap 逻辑（`snapToZone`）。Snap 布局选择器是 UI 层增强，复用现有 snap 逻辑。

---

## 6. 工作流 C5（P2）：桌面小部件

### 6.1 小部件系统

```dart
abstract class DesktopWidget {
  String get id;
  String get name;
  Widget build(BuildContext context, DesktopWidgetConfig config);
  DesktopWidgetConfig defaultConfig();
}

class DesktopWidgetConfig {
  Offset position;
  Size size;
  bool visible;
}
```

### 6.2 首批小部件

- **时钟**：模拟时钟或数字时钟
- **系统监控**：CPU、内存、磁盘小条形图
- **快捷操作**：一键打开终端、文件管理器等
- **便签**：可编辑文本便签

### 6.3 小部件管理

- 桌面右键菜单 → 「添加小部件」
- 小部件可拖拽移动
- 小部件右键 → 删除/配置
- 小部件状态持久化

---

## 7. 桌面右键菜单完形

扩展 `remote_desktop_view.dart` 中 `_showDesktopMenu`：

```dart
PopupMenuItems:
  ── 新建 ──
  打开终端
  文件管理器
  浏览器
  ── 视图 ──
  显示/隐藏桌面图标
  显示/隐藏小部件
  切换壁纸
  ── 工作区 ──
  新建工作区
  工作区概览
  ── 设置 ──
  桌面设置
```

---

## 8. 文件清单

### 新建文件
| 文件 | 说明 |
|------|------|
| `lib/desktop/desktop_expose_overlay.dart` | 窗口 Exposé 概览 |
| `lib/desktop/desktop_snap_picker.dart` | Snap 布局选择器 |
| `lib/desktop/desktop_widgets/` | 桌面小部件目录 |
| `lib/desktop/desktop_widgets/desktop_widget.dart` | 小部件抽象基类 |
| `lib/desktop/desktop_widgets/clock_widget.dart` | 时钟小部件 |
| `lib/desktop/desktop_widgets/monitor_widget.dart` | 系统监控小部件 |
| `lib/desktop/desktop_widgets/quick_actions_widget.dart` | 快捷操作小部件 |
| `lib/desktop/desktop_widgets/sticky_note_widget.dart` | 便签小部件 |
| `lib/desktop/desktop_widget_manager.dart` | 小部件管理器 |

### 修改文件
| 文件 | 改动 |
|------|------|
| `lib/desktop/desktop_window_manager.dart` | 工作区运行时、移动窗口到工作区、窗口置顶 |
| `lib/desktop/desktop_taskbar.dart` | 时钟、系统托盘、显示桌面、自动隐藏、右键菜单 |
| `lib/desktop/remote_desktop_view.dart` | 工作区切换动画、Exposé 集成、Snap 选择器集成、桌面右键菜单完形 |
| `lib/desktop/desktop_command_palette.dart` | 新增工作区操作命令 |
| `lib/services/workbench_desktop_shortcuts.dart` | 新增工作区、Exposé 快捷键 |
| `lib/services/desktop_settings_store.dart` | 新增小部件配置持久化 |

---

## 9. 非目标

- 不做 GNOME Shell 重设计（计划 2 已覆盖）
- 不做热角触发（实现复杂度高，先做快捷键）
- 不做窗口动画引擎（保持简单过渡动画）
- 不做小部件市场/下载

---

## 10. 测试

- 单元测试：工作区切换逻辑、Snap 布局计算、窗口置顶 Z 序
- Widget 测试：Exposé 缩略图列表、Snap 选择器交互、任务栏自动隐藏
- 集成测试：工作区切换动画、窗口移动跨工作区

---

## 11. 风险

| 风险 | 缓解 |
|------|------|
| 工作区切换时窗口状态丢失 | 窗口状态完全在工作区数据结构内，切换不丢失 |
| 大量窗口时 Exposé 性能差 | 限制最大缩略图数（20），超出时使用滚动列表 |
| 小部件与窗口重叠 | 小部件始终在窗口层之下（wallpaper 层之上） |
| Snap 布局与现有 8 区 snap 冲突 | 布局选择器仅在选择时生效，不改变现有拖拽 snap 行为 |