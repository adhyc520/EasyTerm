# Windows 高分辨率显示优化方案

> 目标：让应用在 Windows 高 DPI（4K / 150% / 200% 缩放、多显示器混合 DPI）下「不小、不糊、不跳」。
>
> 现状结论（已核实）：Windows runner manifest 已声明 `PerMonitorV2`（`windows/runner/runner.exe.manifest`），Flutter 以原生分辨率渲染--**不会糊**。全代码用逻辑像素、窗口尺寸以分数存储--**架构上 DPI 安全**。真正缺口是：① **无全局 UI 缩放**（高 DPI 下一切偏小，仅终端字号可调）；② **多显示器 DPI 切换未验证**；③ **终端默认字号偏小**；④ **Menlo 等字体在 Windows 缺失回退**。本方案对症下药，不做无谓改造。

---

## 0. 现状评估（已核实，含行号）

### 0.1 DPI 感知已正确配置

- `windows/runner/runner.exe.manifest`：
  ```xml
  <dpiAwareness>PerMonitorV2</dpiAwareness>
  ```
  -> Windows 不做位图拉伸，Flutter 按 `devicePixelRatio` 原生渲染。**无模糊问题**。
- `windows/runner/main.cpp`：标准 Flutter 模板，`Win32Window::Size(1280, 720)`，无额外 DPI 代码（PerMonitorV2 manifest 已足够）。

### 0.2 全代码逻辑像素 + 分数尺寸（DPI 安全的架构）

- `lib/main.dart:27-29`：`WindowOptions(size: 1280x800, minimumSize: 900x560)`--逻辑像素，window_manager 按 DPR 换算物理。
- `lib/services/desktop_window_size_store.dart`：桌面窗口尺寸存为 `0..1` 分数（`wFrac/hFrac`，`:36-40`），跨 DPI / 窗口缩放天然正确。
- `lib/desktop/desktop_window_frame.dart:455`：拖拽用 `onPanUpdate(d.delta)`--`d.delta` 是逻辑像素增量，DPI 安全。
- `lib/widgets/sftp_folder_delayed_draggable.dart:393`：唯一显式用 `devicePixelRatio` 的地方，做拖拽坐标对齐，已正确。
- 桌面窗口（`desktop_window_manager.dart`）是 Flutter 画布内虚拟窗口，纯逻辑像素，DPI 无关。

### 0.3 缺口 1：无全局 UI 缩放

- `grep devicePixelRatio lib/` 仅 1 处（拖拽，§0.2）；`grep textScaler/textScaleFactor lib/` **0 处**--应用完全不响应系统文字缩放，也无自带 zoom。
- 硬编码小尺寸遍布外壳：标题栏 `width:28,height:24`（`desktop_window_frame.dart:698-699`）、`fontSize:10/11/12`（`:297,299,479,583,761`）、按钮 `height:22`（`:653,664`）。逻辑像素下这些在高 DPR 屏（如 4K@100% 或 28" 4K@150%）显得偏小，且**用户无法整体放大**。
- 唯一可调字号的是终端（`terminalFontSize`，默认 14，`workbench_settings_store.dart:69`），通过 `WorkbenchTerminalSettingsDialog` 改（`:335`）。非终端 UI（标题栏、菜单、SFTP、状态栏）无缩放入口。
- OS 标题栏按钮用 `WindowCaptionButton`（window_manager，`workbench_window_controls.dart`），其自带尺寸由 window_manager 处理，DPI 安全，但视觉上与自定义小字号不协调。

### 0.4 缺口 2：多显示器 DPI 切换未验证

- 跨 DPI 显示器拖窗：Windows 发 `WM_DPICHANGED`，Flutter 重建 `MediaQuery`（`devicePixelRatio` 变）。
- 风险点：
  - 终端 `autoResize: true`（`terminal_surface.dart:736`）依赖 `TerminalView` 尺寸重算行列；DPI 变导致字号物理大小变 -> 行列应重算 -> 触发 `onResize`（`ssh_workspace_controller.dart:710`）-> `resizeTerminal`。**需实测这条链是否在 DPI 变化时触发**（`onResize` 现只在尺寸像素变时触发，DPI 变但逻辑尺寸不变时可能不触发）。
  - 桌面虚拟窗口位置存为绝对 `Rect`（`desktop_window_manager.dart` 内存中），逻辑像素跨屏一致，应无漂移；但窗口物理尺寸随 DPR 变，需确认无溢出。

### 0.5 缺口 3：终端默认字号 14 偏小

- 高 DPI 屏上 14px 逻辑 = 14×DPR 物理；4K@150% 下 21px 物理，可读；但 4K@100%（用户手动设 100%）下 14px 偏小。
- 用户可调（6-48，`:122`），但默认值未考虑 DPR。

### 0.6 缺口 4：字体回退

- `TerminalSurface` 默认 `fontFamily: 'Menlo'`（`terminal_surface.dart:28`）--**Windows 无 Menlo**，回退到系统默认 monospace（可能 Consolas 或劣化）。
- 实际终端模式 / 桌面终端都传 `settings.terminalFontFamily`（默认 `'Courier New'`，`workbench_settings_store.dart:71`），Windows 有。故 `:28` 的 `'Menlo'` 默认只在未传参时生效--当前调用点都传了，**实际无问题**，但默认值不一致是隐患。
- `fontFamilyChoices`（`:98-107`）含 `Menlo/Monaco/SF Mono`（macOS 专属）与 `Consolas`（Windows），跨平台无过滤。

---

## 1. 目标与范围

| 工作流 | 目标 | 优先级 |
|---|---|---|
| **A. 全局 UI 缩放因子** | 新增 `uiScaleFactor` 设置；经 `MaterialApp.builder` 用 `textScaler` 放大全部文本；终端字号联动；非文本热点的尺寸接入缩放。 | P0 |
| **B. 高 DPI 默认值** | 首次启动按 `devicePixelRatio` 给 `uiScaleFactor` / 终端字号合理默认；字体列表按平台过滤。 | P1 |
| **C. 多显示器 DPI 切换** | 监听窗口跨屏，确保终端行列重算、虚拟窗口不溢出；实测并补缺口。 | P1 |
| **D. 验证与测试** | 高 DPI 手动核对矩阵 + 缩放单测。 | P1 |

### 非目标
- 不改 PerMonitorV2 manifest（已正确）。
- 不引入 `Transform.scale` 全局位图缩放（会糊，违背 PerMonitorV2 初衷）。
- 不做每控件像素级重设计--仅通过 `textScaler` + 缩放令牌覆盖热点。
- 不改 in-app 虚拟窗口的分数尺寸存储。

---

## 2. 工作流 A：全局 UI 缩放因子（P0）

### 2.1 设置项

`lib/services/workbench_settings_store.dart` 加：

```dart
static const _kUiScale = 'wb_ui_scale';
double uiScaleFactor = 1.0;          // 0.8 / 0.9 / 1.0 / 1.1 / 1.25 / 1.5
// load(): uiScaleFactor = (p.getDouble(_kUiScale) ?? _defaultUiScale()).clamp(0.75, 2.0);
// persist(): p.setDouble(_kUiScale, uiScaleFactor);
```

- 范围 0.75-2.0，档位与 VS Code `window.zoomLevel` 类似（用户可细调）。
- `_defaultUiScale()`：见 §3，按 DPR 给默认。

### 2.2 注入 `textScaler`（覆盖所有文本）

`lib/main.dart` 的 `MaterialApp.builder`（`:89-100`）扩为：

```dart
builder: (context, child) {
  if (child == null) return const SizedBox.shrink();
  final scale = _settings.uiScaleFactor;
  Widget wrapped = child;
  if (scale != 1.0) {
    wrapped = MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
      ),
      child: child,
    );
  }
  if (!workbenchDesktopShortcutsEnabled()) return wrapped;
  return Shortcuts(
    shortcuts: workbenchGlobalShortcutIntents(),
    child: Actions(
      actions: workbenchGlobalShortcutActions(),
      child: wrapped,
    ),
  );
},
```

- `TextScaler.linear(scale)` 让所有 `Text` / `TextStyle.fontSize` 自动按 scale 放大--**这是高 DPI 下「字太小」的最大收益，零侵入**。
- 注意：`MediaQuery` 重写要放在 `builder` 内、`child` 外；`Shortcuts` 包最外层保持现有快捷键。

### 2.3 终端字号联动

- `TerminalStyle(fontSize: widget.fontSize)`（`terminal_surface.dart:701-705`）不走 `textScaler`（xterm 自己渲染），需手动乘：
  ```dart
  final effectiveFontSize = widget.fontSize * settings.uiScaleFactor;
  final textStyle = TerminalStyle(fontSize: effectiveFontSize, fontFamily: ..., height: 1.0);
  ```
- 终端模式 `session_workspace.dart:140` 与桌面终端 `terminal_app.dart:335` 传入 `fontSize` 时，或在 `TerminalSurface` 内部统一乘 `uiScaleFactor`（推荐后者，单点修改）。
- `TerminalSurface` 需拿到 `uiScaleFactor`：经构造参数传入或 `Provider`/`context.read`。现有 `TerminalSurface` 不依赖 `WorkbenchSettingsStore`，最小侵入是加一个 `uiScale` 参数（默认 1.0），调用方传 `settings.uiScaleFactor`。

### 2.4 非文本热点缩放令牌（P1，渐进）

`textScaler` 只管文本。图标 / 间距 / 按钮高度仍是硬编码。引入缩放令牌到 `lib/theme/workbench_theme.dart`（已有 `context.wb` 扩展）：

```dart
extension WbScale on WorkbenchColors {
  double get wbIconSm => 14 * _scale;
  double get wbIconMd => 18 * _scale;
  double get wbControlH => 28 * _scale;
  // ...
}
```

- 但 `context.wb` 是 `WorkbenchColors`（颜色），加尺寸需新建 `WorkbenchMetrics` InheritedWidget 或在 theme 里挂。
- **务实策略**：本期只把**最显眼的几处**（标题栏控件 `:698-699`、状态栏字号 `:761`、桌面窗口标题 `:479`）改为读 `uiScaleFactor`；其余靠 `textScaler` 覆盖文本，图标尺寸留待后续。文档里标注「全量迁移非文本尺寸」为后续工作。

---

## 3. 工作流 B：高 DPI 默认值（P1）

### 3.1 `uiScaleFactor` 默认

```dart
double _defaultUiScale() {
  // 首次启动（prefs 未设 _kUiScale）时按主屏 DPR 给默认。
  // 逻辑像素下 Flutter 已按 DPR 渲染，这里只补「默认偏小」的体感。
  final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
  if (dpr >= 2.0) return 1.1;   // 4K / Retina：略放大
  if (dpr >= 1.5) return 1.0;
  return 1.0;
}
```

- 用 `containsKey(_kUiScale)` 判是否首次；仅首次给默认，老用户保留 1.0。
- 保守：默认不激进放大（1.1 封顶），用户可在设置里调高。

### 3.2 终端默认字号按 DPR

- 现默认 14（`workbench_settings_store.dart:69`）。首启按 DPR 给 15-16（dpr>=2 时 16）。同样仅首启、`containsKey(_kFontSize)` 判定。

### 3.3 字体列表平台过滤

- `fontFamilyChoices`（`:98-107`）按平台过滤：Windows 优先 `Consolas`/`Courier New`/`JetBrains Mono`；macOS 优先 `Menlo`/`Monaco`/`SF Mono`。
- `TerminalSurface` 默认 `fontFamily`（`:28` `'Menlo'`）改为平台化默认：`defaultTargetPlatform == windows ? 'Consolas' : 'Menlo'`，消除隐患。
- 用 `defaultTargetPlatform`（已在 `workbench_desktop_shortcuts.dart` 用过）。

---

## 4. 工作流 C：多显示器 DPI 切换（P1）

### 4.1 实测链路

跨 DPI 屏拖窗时核对：

1. `MediaQuery.devicePixelRatio` 变化 -> `MaterialApp` 重建 -> `textScaler` 仍生效（`uiScaleFactor` 不变，文本不跳）。
2. 终端 `TerminalView` 逻辑尺寸可能变（DPR 变 -> 同物理窗的物理像素变 -> Flutter 逻辑尺寸变）-> `autoResize` 重算行列 -> `onResize` -> `resizeTerminal`。**若逻辑尺寸不变（窗物理像素被 Windows 同步调整），`onResize` 可能不触发**，导致 PTY 行列与显示不符。
3. 桌面虚拟窗口 `Rect`（逻辑像素）应不漂移；但物理尺寸变可能导致虚拟窗口相对桌面背景比例变--分数存储的是「上次尺寸」，运行时是绝对 Rect，需确认不溢出桌面。

### 4.2 补缺口

- **终端行列重算**：在 `TerminalSurface` 监听 `MediaQuery.devicePixelRatio` 变化（`didChangeDependencies` 或 `WidgetsBindingObserver.didChangeMetrics`），DPR 变时强制触发一次 `terminal.resize`/`autoResize` 校准：
  ```dart
  // TerminalSurfaceState 加 WidgetsBindingObserver
  @override
  void didChangeMetrics() {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (dpr != _lastDpr) { _lastDpr = dpr; /* 触发 TerminalView 重算 */ }
  }
  ```
  xterm `TerminalView` 的 `autoResize` 通常在 layout 变化时重算；DPR 变若 layout 变会自然走通。实测确认，必要时手动 `widget.terminal.resize(...)`。
- **窗口跨屏尺寸**：window_manager 的 `onWindowResized` 在 `WM_DPICHANGED` 时会被调用；建议在 `EasyTermApp` / `MainShellScreen` 加 `WindowListener`，`onWindowResized` 时 log 一次尺寸用于核对（不强制改）。
- **`uiScaleFactor` 不随屏变**：用户设的缩放是全局的，跨屏保持。这是预期（VS Code 同此）。

### 4.3 标题栏 hit-test

`WindowCaptionButton`（window_manager）自带 DPI 适配；自定义标题栏拖拽区 `desktop_window_frame.dart` 用 `d.delta`（逻辑像素），DPI 安全。无需改，但需在高 DPI 实测「点关闭/最大化按钮不偏」。

---

## 5. 工作流 D：验证与测试（P1）

### 5.1 手动核对矩阵

| 环境 | 核对 | 期望 |
|---|---|---|
| 1080p @100% | 默认 UI | 不放大（uiScale=1.0），与现状一致 |
| 4K @150% | 默认 UI | 文本略放大（uiScale=1.1），可读 |
| 4K @100% | 设 uiScale=1.5 | 全部文本放大，终端字号×1.5，无溢出 |
| 1080p -> 4K 拖窗 | 终端行列 | 切屏后终端行列与显示匹配，PTY 不串行 |
| 4K -> 1080p 拖窗 | 虚拟窗口 | 桌面虚拟窗口不溢出、不丢失 |
| 高 DPI 关闭按钮 | hit-test | 点关闭/最大化命中准确 |
| uiScale=2.0 | 对话框 | 设置对话框 / SFTP 侧栏不溢出、可滚动 |

### 5.2 单测 `test/ui_scale_test.dart`

- `MaterialApp.builder` 注入 `textScaler` 后，子树 `Text` 的 `textScaler` 等于 `TextScaler.linear(scale)`。
- `uiScaleFactor` clamp 边界（0.75 / 2.0 / 越界）。
- 首启默认：`_defaultUiScale()` 对 dpr 2.0 -> 1.1；老用户（`containsKey=true`）不覆盖。
- 终端 `effectiveFontSize = fontSize * uiScaleFactor`。

### 5.3 回归

- `test/desktop_window_manager_test.dart` / `test/desktop_drop_paths_test.dart` 不受影响（分数尺寸 / 逻辑像素未改）。
- 终端测试（若有）确认 `TerminalStyle.fontSize` 传入值正确。

---

## 6. 风险与回退

| 风险 | 缓解 |
|---|---|
| `textScaler` 放大后对话框 / 窄面板溢出 | 对话框本就 `SingleChildScrollView`（如 `:201`）；窄面板加 `overflow: clip`；测试矩阵覆盖 uiScale=2.0。 |
| 终端字号乘 uiScale 后与 PTY 行列失配 | `TerminalView.autoResize` 会按新字号重算行列并 `onResize` -> `resizeTerminal`；首屏可能闪一次，可接受。 |
| 非文本尺寸未缩放导致「字大图标小」不协调 | 本期改最显眼 3-4 处；文档标注后续全量迁移；用户体感主要痛点（字小）已解。 |
| 多显示器 DPI 切换 `onResize` 不触发 | §4.2 `didChangeMetrics` 兜底强制校准。 |
| 首启默认改老用户设置 | 一律 `containsKey` 判定，仅首启生效。 |
| `devicePixelRatio` 在多屏取首屏不准 | `_defaultUiScale` 仅首启默认，用户可调；非关键路径。 |

---

## 7. 涉及文件清单

| 文件 | 动作 |
|---|---|
| `lib/services/workbench_settings_store.dart` | 改：加 `uiScaleFactor`；首启 DPR 默认；字体列表平台过滤 |
| `lib/main.dart` | 改：`MaterialApp.builder` 注入 `textScaler` |
| `lib/widgets/terminal_surface.dart` | 改：`fontSize` 乘 `uiScale`；默认 fontFamily 平台化；`didChangeMetrics` 校准 |
| `lib/widgets/session_workspace.dart` | 改：传 `uiScale` 给 `TerminalSurface` |
| `lib/desktop/apps/terminal_app.dart` | 改：传 `uiScale` |
| `lib/theme/workbench_theme.dart` | 改（P1）：加缩放令牌（最显眼处） |
| `lib/desktop/desktop_window_frame.dart` | 改（P1）：标题栏控件 / 字号接缩放令牌 |
| `lib/widgets/workbench_interface_settings_dialog.dart` | 改：加 `uiScaleFactor` 滑块 / 档位 |
| `lib/widgets/workbench_terminal_settings_dialog.dart` | 改（可选）：字号提示「受 UI 缩放联动」 |
| `test/ui_scale_test.dart` | 新增 |

---

## 8. 与其它方案的关系

- 与 `windows-nano-copy.md` 无耦合（选择坐标逻辑像素，D6 已核对 DPI 无关）。
- 与 `terminal-follow-folder.md` 无耦合。
- 与 `editor-find-replace.md` 无耦合；但编辑器字号同样受 `textScaler` 自动放大，无需额外处理。
- 终端 `uiScale` 与 nano 方案的鼠标模式拦截器互不影响。

---

## 9. 优先级裁剪建议（若工期紧）

只做最高收益三件，即可覆盖大部分痛点：
1. **A.2 `textScaler` 注入 + A.3 终端字号联动**（半天）--解决「字小」，零侵入。
2. **B.3 字体平台过滤 + `TerminalSurface` 默认 fontFamily 平台化**（1 小时）--消除 Windows 字体回退隐患。
3. **C 多显示器 DPI 实测 + `didChangeMetrics` 兜底**（半天）--防切换串行。

`uiScaleFactor` 设置 UI（A.1 对话框滑块）与非文本令牌（A.4）可延后：先以首启 DPR 默认值静默生效，用户无感即好用；需要细调时再补设置入口。
