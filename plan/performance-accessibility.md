# 性能与可及性：大输出优化、懒加载、无障碍、触控手势

> 现状：应用在中等规模数据下表现良好，但存在已知性能隐患：终端大输出时 xterm 渲染卡顿、桌面 16 个应用一次性加载、无无障碍支持、无触控手势（平板上不可用）。此计划为质量工程，不新增功能。

---

## 1. 现状评估

| 模块 | 文件 | 现状 |
|------|------|------|
| 终端渲染 | `lib/widgets/terminal_surface.dart` | xterm TerminalView 渲染，无虚拟滚动，大量输出时全量渲染 |
| 桌面应用 | `lib/desktop/apps/*.dart` | 16 个应用在 `remote_desktop_view.dart` 一次性 import 并构建 |
| 无障碍 | 全局 | 无任何 `Semantics` widget、`aria-label`、屏幕阅读器支持 |
| 键盘导航 | `lib/services/workbench_desktop_shortcuts.dart` | 桌面快捷键，但无 Tab 键导航 |
| 触控 | 全局 | 无触控手势（双指缩放、滑动切换标签等） |
| 文本缩放 | `lib/main.dart` (:94-107) | 全局 `uiScaleFactor`，通过 `MediaQuery.textScaler` 实现 |
| 内存 | 全局 | 无内存监控或限制，长时间运行可能泄漏 |

**关键缺口：**
1. 终端大输出（>10000 行）时渲染卡顿
2. 桌面应用全部 import 导致启动慢
3. 无无障碍支持，屏幕阅读器无法使用
4. 无触控手势支持
5. 无内存/性能监控

---

## 2. 工作流 F1（P1）：终端大输出优化

### 2.1 虚拟滚动

xterm 4.0.0 的 `Terminal` 类内部使用 `Buffer` 管理所有行。当缓冲区超过 `terminalMaxLines`（默认 1000）时，旧行被丢弃，但 1000 行仍然需要全量渲染。

**优化方案：仅渲染可见行 + 上下各 50 行缓冲**

```dart
class TerminalViewportOptimizer {
  final Terminal terminal;
  final ScrollController scrollController;
  
  // 计算可见行范围
  VisibleRange get visibleRange {
    final firstVisible = (scrollController.offset / lineHeight).floor();
    final visibleCount = (viewportHeight / lineHeight).ceil();
    return VisibleRange(
      start: max(0, firstVisible - 50),  // 上缓冲
      end: min(totalLines, firstVisible + visibleCount + 50), // 下缓冲
    );
  }
}
```

**注意：** xterm 的 `TerminalView` 是第三方 widget，无法直接修改其渲染逻辑。替代方案：

1. **限制渲染行数**：在 `term.write` 之后，检查 buffer 长度，超过阈值时截断
2. **帧率控制**：使用 `AnimatedBuilder` 限制重绘频率（debounce 16ms）
3. **输出分片**：大批量输出时，分片写入 terminal（每帧最多 200 行）

### 2.2 输出分片写入

```dart
class TermWriteBatcher {
  static const _maxLinesPerFrame = 200;
  
  Future<void> writeBatched(Terminal terminal, String data) async {
    final lines = data.split('\n');
    for (var i = 0; i < lines.length; i += _maxLinesPerFrame) {
      final chunk = lines.skip(i).take(_maxLinesPerFrame).join('\n');
      terminal.write(chunk);
      if (i + _maxLinesPerFrame < lines.length) {
        await Future.delayed(const Duration(milliseconds: 16)); // 等一帧
      }
    }
  }
}
```

### 2.3 缓冲区限制

在 `WorkbenchSettingsStore` 中，`terminalMaxLines` 默认 1000。建议改为 2000 并提供 UI 滑块调整。

---

## 3. 工作流 F2（P1）：桌面应用懒加载

### 3.1 现状问题

`remote_desktop_view.dart` 顶部 import 了全部 16 个应用：

```dart
import 'apps/browser_app.dart';
import 'apps/containers_app.dart';
// ... 14 more
```

即使当前桌面只有一个终端窗口，所有应用代码都在内存中。

### 3.2 懒加载方案

```dart
// 应用工厂注册表（替换静态 import）
class DesktopAppFactory {
  static final Map<DesktopAppType, Widget Function(Map<String, dynamic>?)> _factories = {};
  
  static void register(DesktopAppType type, Widget Function(Map<String, dynamic>?) builder) {
    _factories[type] = builder;
  }
  
  static Widget? build(DesktopAppType type, Map<String, dynamic>? args) {
    return _factories[type]?.call(args);
  }
}
```

**但由于 Flutter 不支持真正的动态 import，替代方案：**

1. **延迟初始化**：使用 `late` 关键字延迟创建应用 widget
2. **窗口预创建**：仅创建可见窗口的 widget，其他窗口用占位符
3. **应用内缓存**：已创建的应用 widget 保持，不重复创建

### 3.3 窗口占位符

非活跃窗口不渲染实际内容，显示标题栏 + 加载占位符：

```dart
class DesktopWindowContent extends StatelessWidget {
  final DesktopWindow window;
  final bool isActive;
  
  Widget build(BuildContext context) {
    if (!isActive && !window.contentCreated) {
      return _WindowPlaceholder(title: window.title);
    }
    return _buildAppContent(window);
  }
}
```

---

## 4. 工作流 F3（P2）：无障碍

### 4.1 语义标注

为关键 UI 组件添加 `Semantics`：

```dart
// 连接按钮
Semantics(
  label: l10n.newConnection,
  hint: l10n.newConnectionHint,
  button: true,
  child: FilledButton.icon(...),
)

// 终端
Semantics(
  label: 'SSH Terminal - ${c.username}@${c.host}',
  value: 'Connected',
  child: TerminalSurface(...),
)

// 状态栏
Semantics(
  label: 'System Status',
  value: 'CPU ${cpuPercent}%, Memory ${memPercent}%',
  child: WorkbenchStatusBar(...),
)
```

### 4.2 Tab 键导航

在桌面模式中，`Tab` 键在窗口之间切换焦点：

```dart
// 在 RemoteDesktopView 中
FocusTraversalGroup(
  policy: OrderedTraversalPolicy(),
  child: Stack(
    children: windows.map((w) => _buildWindow(w)),
  ),
)
```

### 4.3 屏幕阅读器支持

- 所有 `IconButton` 必须有 `tooltip`（已有大部分）
- 关键状态变化使用 `SemanticsService.announce()` 通知
- 错误消息使用 `SnackBar` + `Semantics` 双重通知

---

## 5. 工作流 F4（P2）：触控手势

### 5.1 手势支持

```dart
// 标签页切换：双指左右滑动
GestureDetector(
  onHorizontalDragEnd: (details) {
    if (details.primaryVelocity! > 0) {
      tabs.selectPrev();
    } else if (details.primaryVelocity! < 0) {
      tabs.selectNext();
    }
  },
  child: tabBar,
)

// 终端缩放：双指缩放
GestureDetector(
  onScaleUpdate: (details) {
    final newScale = (currentScale * details.scale).clamp(0.5, 3.0);
    settings.setTerminalFontScale(newScale);
  },
  child: terminalSurface,
)
```

### 5.2 触控工具栏

当检测到触控设备时，在终端底部显示辅助工具栏：

```
┌──────────────────────────────────────────┐
│ [Esc] [Tab] [Ctrl] [↑] [↓] [←] [→] [⌫] │  ← 可自定义
└──────────────────────────────────────────┘
```

```dart
class TouchAssistBar extends StatelessWidget {
  // 仅在触控设备上显示
  // 包含常用特殊键
  // 可配置显示/隐藏
}
```

### 5.3 触控优化

- 增大触控目标（最小 44x44 pt）
- 右键菜单改长按触发
- 拖拽调整为长按 + 拖拽

---

## 6. 工作流 F5（P2）：性能监控

### 6.1 帧率监控

```dart
class PerformanceOverlay {
  // 开发模式下显示 FPS 计数器
  // 在设置中开启：显示 → 性能叠加层
  
  static void showFpsCounter(OverlayEntry entry);
  static void hideFpsCounter();
}
```

### 6.2 内存监控

```dart
class MemoryMonitor {
  // 定期检查内存使用
  // 超过阈值（如 500MB）时提示用户关闭不用的标签页
  
  static Future<int> getCurrentMemoryMB(); // 平台相关
  static void checkAndWarn(BuildContext context);
}
```

### 6.3 连接池管理

```dart
class ConnectionPoolManager {
  // 限制最大并发连接数（默认 50）
  // 空闲连接超时自动关闭（默认 30min）
  // 连接泄漏检测（连接打开超过 10min 无活动）
}
```

---

## 7. 文件清单

### 新建文件
| 文件 | 说明 |
|------|------|
| `lib/services/term_write_batcher.dart` | 终端输出分片写入 |
| `lib/services/performance_monitor.dart` | 性能监控（FPS/内存/连接池） |
| `lib/widgets/touch_assist_bar.dart` | 触控辅助工具栏 |
| `lib/util/accessibility.dart` | 无障碍辅助函数 |

### 修改文件
| 文件 | 改动 |
|------|------|
| `lib/widgets/terminal_surface.dart` | 集成输出分片 + 语义标注 |
| `lib/desktop/remote_desktop_view.dart` | 窗口懒加载 + Tab 键导航 + 语义标注 |
| `lib/screens/main_shell_screen.dart` | 触控手势 + 语义标注 |
| `lib/main.dart` | 性能监控初始化 |
| `lib/services/workbench_settings_store.dart` | 新增 terminalMaxLines 滑块、触控工具栏开关 |
| `lib/desktop/desktop_window_frame.dart` | 增大触控模式下的 resize 手柄 |

---

## 8. 非目标

- 不做 Flutter Engine 级别优化（那是框架的事）
- 不做原生渲染（Metal/DirectX）
- 不做 Web 版本性能优化
- 不做 profiler 集成（使用 Flutter DevTools 即可）

---

## 9. 测试

- 性能测试：10000 行终端输出帧率测试、16 窗口同时打开内存测试
- Widget 测试：语义标签正确性、Tab 键导航顺序
- 手动测试：触控手势在触控板/平板上验证

---

## 10. 风险

| 风险 | 缓解 |
|------|------|
| 输出分片导致终端显示延迟 | 小输出（<200 行）不分片，直接写入 |
| 窗口懒加载导致切换时闪烁 | 保持最近 5 个窗口的 widget 树不销毁 |
| 无障碍标注不完整 | 优先覆盖核心路径（连接、终端、设置），逐步完善 |
| 触控与现有鼠标手势冲突 | 触控手势仅在 `Platform.isIOS || Platform.isAndroid` 时启用 |