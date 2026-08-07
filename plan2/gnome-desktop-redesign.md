# 桌面模式 GNOME 风格优化方案（Desktop GNOME Shell Redesign）

> 目标：把当前偏 Windows/macOS 风格的远程桌面外壳，重塑为对标 **GNOME Shell** 的现代桌面体验——**顶栏（Top Bar）+ Activities 概览 + Dash + 垂直工作区 + 融合式窗口装饰（HeaderBar）+ Adwaita 暗色美学**。本期聚焦**布局与 UI**，不改 SSH 连接模型、终端模式与既有应用业务逻辑，对终端模式零回归。
>
> 基线：`plan/desktop-next-iteration.md` 已落地的外壳能力（虚拟工作区、命令面板、系统托盘、桌面右键、窗口置顶、Win11 snap 布局选择器、桌面设置）全部保留并在此基础上**重塑外观与交互范式**。

---

## 0. 现状评估（已核实事实，含行号）

### 0.1 当前外壳架构

- **桌面表面**（`lib/desktop/remote_desktop_view.dart`，872 行）：`Stack` 三层——背景层（渐变 + 网格 + 左上 16 个桌面快捷方式 `_DesktopBackground` 699-797）／窗口层（`top:0 .. bottom: taskbarH` 374-427）／**底部任务栏**（428-433）。掉线浮层 + 重连（443-509）。`CallbackShortcuts` 快捷键（195-343）。
- **底部任务栏**（`lib/desktop/desktop_taskbar.dart`，605 行，高 44px `taskbarH`）：左侧启动器 `PopupMenuButton`（`_LauncherButton` 297-405，17 项下拉菜单）+ 横向窗口按钮列表（`_TaskbarWindowButton` 427-605）+ 工作区圆点指示器（`_WorkspaceIndicator` 66-124）+ 系统托盘（`_TrayArea` 126-295：连接状态点 / CPU·MEM 文本 / 时钟 / 显示桌面 / 设置）。这是典型的 **Windows 风格底栏**。
- **窗口装饰**（`lib/desktop/desktop_window_frame.dart`，621 行）：`_TitleBar`（345-540，高 30px `titleBarH`）——左侧图标 + 标题，**右侧三按钮**（最小化 `_TitleBtn` / 最大化-贴边 `_SnapMaximizeBtn` / 关闭 `_TitleBtn danger` 519-534）。圆角 8px（最大化 0）。聚焦时蓝边 + 强阴影。8 向缩放手柄（180-277）。这是 **Windows/macOS 混合标题栏**。
- **窗口管理器**（`lib/desktop/desktop_window_manager.dart`，1051 行）：几何 / z 序 / 状态 / 工作区 / 贴边吸附 / 尺寸记忆。工作区为水平列表（`_workspaces`），切换靠 Ctrl+数字 或底部圆点。
- **命令面板**（`lib/desktop/desktop_command_palette.dart`，420 行）：Ctrl/Cmd+Shift+P 唤起，模糊搜索。这是已有的「类 GNOME 搜索」雏形，但不是全屏概览。
- **桌面设置**（`lib/services/desktop_settings_store.dart` + `lib/widgets/desktop_settings_dialog.dart`）：工作区数 / snap / 网格 / 壁纸 / 默认窗口尺寸 / 托盘时钟·指标 / 实时日志。注意：`taskbarAutohide`（store:25,39,57）**设置项存在但 UI 未暴露、外壳未消费——死开关**。
- **配色**（`lib/theme/workbench_theme.dart`）：`WorkbenchColors.dark`——bg `#111113`、topBar `#1B1B1F`、panel `#16171A`、panelElevated `#202126`、border `#303139`、accentBlue `#0A84FF`（苹果蓝）。整体是**偏冷的黑灰 + iOS 蓝**，非 Adwaita 调性。
- **应用层**（`lib/desktop/apps/*.dart`，16 个应用）：每个 app 内部为 `ColoredBox(color: wb.panel)` + 自身内容组件（如 `FileManagerApp.build` 123-138 直接放 `SftpBrowser`），**窗口标题栏由 `DesktopWindowFrame` 统一提供，apps 不自画标题栏**。这是利好：GNOME 窗口装饰改造主战场集中在 `DesktopWindowFrame`，对 16 个 app 几乎零侵入。
- **配色侵入性已核验**：apps 中硬编码 `Color(0x..)`/`Colors.` 共 35 处，使用主题色 `context.wb`/`Theme.of` 共 46 处。硬编码集中在 `task_manager_app`(12)、`monitor_app`(5)、`browser_app`(3)，且绝大多数是 **CPU/连接/状态等语义色**（绿/黄/红/橙），属数据语义不应随配色方案变化；chrome 色（背景/面板/边框/文字）已统一走 `wb`。结论：**Adwaita 配色切换对 apps 零侵入**，仅 `workbench_theme.dart` + 设置层改动即可。

### 0.2 与 GNOME Shell 的差距矩阵

| # | 维度 | 现状（行号） | GNOME Shell | 差距 / 影响 |
|---|---|---|---|---|
| 1 | **外壳栏位置** | 底部任务栏 44px（`desktop_taskbar.dart:29`） | 顶栏 32px，全宽 | 视觉重心在下，不符 GNOME 习惯；占去底部空间 |
| 2 | **启动入口** | 启动器 `PopupMenuButton` 下拉菜单（`desktop_taskbar.dart:305`） | Activities 概览 + Dash + 应用网格 | 17 个应用挤在一个下拉里，无视觉锚点，无搜索启动 |
| 3 | **窗口切换/exposé** | 任务栏横向窗口按钮（`desktop_taskbar.dart:427`） | Activities 概览：窗口缩略图网格 | 窗口多时按钮挤、无全局一览 |
| 4 | **工作区切换器** | 底部圆点（`desktop_taskbar.dart:66`） | 概览右侧**垂直**工作区缩略图列表 | 圆点无预览、方向不符、>4 个难辨认 |
| 5 | **窗口标题栏** | 30px，左图标标题 + 右三按钮，8px 圆角（`desktop_window_frame.dart:345-540`） | HeaderBar：与内容**同色融合**、12px 圆角、右侧仅关闭（+可选最大化） | 标题栏与内容强对比（panelElevated vs bg）、按钮多、圆角小，不像 GNOME |
| 6 | **配色** | 苹果蓝 `#0A84FF` + 冷黑灰（`workbench_theme.dart:43-58`） | Adwaita 暗色：`#1d1d20`/`#303034` + 蓝 `#3584e4` | 调性偏 iOS，非 GNOME |
| 7 | **桌面图标** | 左上 16 个快捷方式常驻（`remote_desktop_view.dart:712-729`） | GNOME 默认**无桌面图标**，靠 Dash/应用网格 | 桌面拥挤，偏离 GNOME 极简 |
| 8 | **搜索** | 命令面板弹窗（`desktop_command_palette.dart`） | 概览顶部搜索框，统一入口 | 搜索与概览割裂 |
| 9 | **顶栏系统菜单** | 托盘散落：状态点/指标/时钟/显示桌面/设置（`desktop_taskbar.dart:225-293`） | 右侧聚合 Quick Settings 面板 | 信息散乱，无聚合面板 |
| 10 | **毛玻璃/动画** | 无 BackdropFilter，无概览过渡动画 | 顶栏与概览背景模糊，进入有缩放过渡 | 质感扁平，缺现代感 |
| 11 | **taskbarAutohide** | 死开关（store 有、UI 无、消费无） | 顶栏可自动隐藏 | 设置项遗留未实现 |

---

## 1. 目标与范围

### 1.1 主题：**桌面外壳 GNOME Shell 化——顶栏 · 概览 · Dash · 融合窗口 · Adwaita 美学**

| 工作流 | 目标 | 优先级 |
|---|---|---|
| **A. 顶栏 Top Bar** | 底部任务栏 → 顶部 32px 顶栏：左 Activities、中远端时钟+日期+连接态、右聚合 Quick Settings。 | P0 |
| **B. Activities 概览** | Super / 点 Activities / 点时钟 唤起全屏概览：搜索 + 窗口缩略图网格 + 垂直工作区 + Dash。 | P0 |
| **C. Dash 与应用网格** | 概览底部 Dash（收藏 + 运行中应用），点网格进全屏应用网格。 | P0 |
| **D. 窗口装饰 GNOME 化** | HeaderBar 风格：12px 圆角、标题栏与内容同色融合、右侧关闭按钮（圆）、最大化/最小化可配、柔和阴影。 | P0 |
| **E. Adwaita 配色** | 新增 GNOME 暗色色板（可切回原配色），强调色蓝 `#3584e4`。 | P1 |
| **F. 工作区垂直化** | 概览右侧垂直工作区缩略图；横向切换保留。 | P1 |
| **G. 动画与毛玻璃** | 概览进入缩放+淡入、顶栏/概览 BackdropFilter 模糊。 | P1 |
| **H. 桌面图标策略** | 默认隐藏桌面快捷方式（更 GNOME），设置可开；启动改走 Dash/应用网格。 | P2 |
| **I. 设置与快捷键** | 补全 taskbarAutohide、桌面图标开关、顶栏密度；快捷键对齐 GNOME（Super 进概览）。 | P2 |

### 1.2 本期不做（非目标）
- 不改 SSH 连接模型、终端 PTY、xterm 渲染。
- 不改 16 个应用的业务逻辑（仅窗口装饰层与配色透传）。
- 不做 VNC/RDP/X11 投屏。
- 不替换既有命令面板（复用其搜索逻辑作为概览搜索后端）。
- 不引入新依赖（BackdropFilter、AnimatedSwitcher 均为 Flutter 内置）。

### 1.3 设计原则
1. **外壳归外壳，应用归应用**：GNOME 化集中在 `desktop_*` 外壳文件与 `workbench_theme`；apps 零侵入。
2. **可回退**：新配色/新外壳作为可选项，保留原 Windows 风格开关（至少过渡期）。
3. **远程工具的务实取舍**：不照搬 GNOME 的音量/蓝牙/电池，顶栏右侧改为「连接状态 + 资源指标 + 显示桌面 + 设置 + 重连」的远程管理 Quick Settings。
4. **性能不退步**：概览用 `RepaintBoundary` 隔离；窗口缩略图用 `RepaintBoundary` 截图缓存，避免每帧重绘 16 个 app。

---

## 2. 工作流 A：顶栏 Top Bar（P0）

### 2.1 布局

```
┌──────────────────────────────────────────────────────────────────┐
│  Activities          周三 08-07  14:32          ●  CPU 12%  ⚙  │  32px
└──────────────────────────────────────────────────────────────────┘
```

- **高度**：`DesktopWindowManager.taskbarH: 44 → 32`（GNOME 实测 32px）。窗口层 `bottom` 改 `top: topBarH`（顶栏在上，窗口工作区 = 顶栏下方到桌面底）。
- **左**：`Activities` 文字按钮（点击 → 进概览）。悬停高亮。
- **中**：远端时钟 + 日期（复用 `_TrayArea._tick` 的 `date '+%H:%M'`，新增 `date '+%m-%d %a'`）。点击 → 进概览（GNOME 点时钟进日历，此处复用为概览入口）。左侧带连接状态点（绿/黄/红）。
- **右**：聚合指标 + Quick Settings 触发按钮（齿轮/状态点）。CPU/MEM 文本（可配开关）。

### 2.2 Quick Settings 面板

点顶栏右侧触发，从右上角下拉的圆角面板（宽 320）：
- 连接状态行 + 「重连」按钮
- CPU / MEM 迷你进度条（复用 `RemoteHostSnapshot`）
- 「显示桌面」开关
- 「桌面设置」入口
- 托盘时钟/指标显隐开关（迁移自设置对话框）

### 2.3 改动点
- 新建 `lib/desktop/desktop_top_bar.dart`（由 `desktop_taskbar.dart` 重构而来，保留窗口按钮逻辑移入概览）。
- `remote_desktop_view.dart`：`DesktopTaskbar`（428-433）→ `DesktopTopBar`；窗口层 `Positioned(bottom: taskbarH)` → `Positioned(top: topBarH)`。
- `desktop_window_manager.dart`：`taskbarH` 改 32；`displayRect`/`rectForTileZone`/`_clampNormalRect`/`_detectSnapHint` 中 `desktopSize.height - taskbarH` 的语义从「减底部」变「减顶部」，统一改用 `workAreaHeight()` 与 `workAreaTop()` 辅助方法。
- `taskbarAutohide` 接线：顶栏鼠标离开后延时 1s 滑出，触及顶边唤回（设置开关）。

---

## 3. 工作流 B：Activities 概览（P0）

### 3.1 布局

```
┌────────────────────────────────────────────────────────────┐
│                    🔍 搜索应用 / 窗口 / 命令…                │  顶部搜索
│                                                            │
│   ┌──────┐ ┌──────┐ ┌──────┐          ┌─────────┐         │
│   │ 窗口 │ │ 窗口 │ │ 窗口 │          │ 工作区 1 │         │
│   │ 缩略 │ │ 缩略 │ │ 缩略 │          │ 缩略图   │         │
│   └──────┘ └──────┘ └──────┘          ├─────────┤         │
│      (当前工作区窗口网格)              │ 工作区 2 │         │
│                                        │ 缩略图   │ ←垂直   │
│   ┌────────────────────────────┐       └─────────┘         │
│   │  Dash: 📁 🌐 📊 🗒 🐳 …  ⊞  │  底部 dock            │
│   └────────────────────────────┘                           │
└────────────────────────────────────────────────────┘
```

- **唤起**：Super 键（meta 单独按下）/ 点 Activities / 点时钟 / 快捷键 `Super` 或保留 `Ctrl+Shift+P`（复用）。Esc / 点空白 / 再按 Super 退出。
- **搜索框**：复用 `desktop_command_palette.dart` 的 `_Cmd` + `_refilter` 逻辑（51-237），抽出为共享 `DesktopSearchEngine`。输入即过滤：应用、窗口、命令、工作区切换。
- **窗口缩略图**：当前工作区非最小化窗口的实时缩略图。用 `RepaintBoundary` + `BoundaryLayer.toImage`（或对 `_DesktopWindowHost` 子树截图）缓存，窗口几何变化时失效重截。点击聚焦并退出概览；右键关闭/移到工作区。
- **垂直工作区列表**：右侧每个工作区一张缩略图（含其窗口缩略），当前高亮；点击切换；悬停显「+」新增、「×」删除（动态工作区）。
- **Dash**：见工作流 C。

### 3.2 状态机
- `DesktopWindowManager` 新增 `bool _overviewOpen` + `notifyListeners`。`RemoteDesktopView` 在 `Stack` 顶层叠加 `DesktopOverview`（`Positioned.fill`），背景 `BackdropFilter` 模糊 + 半透明黑。
- 概览打开时窗口层不重建（仍 `Offstage` 保活），仅叠加缩略图层。

### 3.3 改动点
- 新建 `lib/desktop/desktop_overview.dart`。
- `desktop_window_manager.dart`：新增 `overviewOpen` getter / `toggleOverview()` / `enterOverview()` / `exitOverview()`。
- `remote_desktop_view.dart`：`_paletteOpen` 逻辑（62-73）泛化为 `_overviewOpen`，叠加 `DesktopOverview`。
- 抽 `DesktopSearchEngine`（从 `desktop_command_palette.dart` 迁移 `_buildCommands` 51-237），命令面板与概览搜索共用。

---

## 4. 工作流 C：Dash 与应用网格（P0）

### 4.1 Dash
- 概览底部水平胶囊 dock（圆角 18，半透明 panelElevated + 模糊）。
- **收藏应用**：终端 / 文件 / 浏览器 / 监控 / 日志 / 容器（可在设置配）。
- **运行中应用**：去重显示，运行中应用图标下加小圆点指示。
- 点击：已运行则聚焦（多开时聚焦最近），未运行则 `wm.open(type)`；右键菜单：新窗口 / 关闭全部。
- 右端「⊞」应用网格按钮 → 进应用网格页。

### 4.2 应用网格
- 全屏图标网格（`GridView` 6 列），含全部 16 个 `DesktopAppType`，分页。
- 点击启动并退出概览。
- 复用 `_DesktopBackground._shortcuts`（712-729）的图标/标签映射，抽为 `desktop_app_registry.dart` 单一数据源（消除当前 taskbar/launcher/shortcut 三处重复的图标 switch）。

### 4.3 改动点
- 新建 `lib/desktop/desktop_app_registry.dart`：`record AppMeta(id, icon, label, keywords)`，集中 16 个应用元数据。
- `desktop_taskbar.dart` `_LauncherButton._item` / `desktop_command_palette.dart` `_buildCommands` / `remote_desktop_view.dart` `_shortcuts` 三处 switch 全部改读 registry（消除 ~120 行重复）。
- Dash / 应用网格 widget 在 `desktop_overview.dart` 内。

---

## 5. 工作流 D：窗口装饰 GNOME 化（P0）

### 5.1 HeaderBar 视觉

| 项 | 现状 | 改为（GNOME） |
|---|---|---|
| 圆角 | 8px（`desktop_window_frame.dart:73`） | **12px**（最大化 0） |
| 标题栏背景 | `panelElevated`（强对比，`:496`） | **与内容同色 `panel`**（融合） |
| 标题栏高度 | 30px | **36px**（HeaderBar 更舒展） |
| 标题位置 | 左 | **居中**（或保留左，可配） |
| 按钮 | 左→右：最小化/最大化/关闭（右侧三按钮） | **右侧仅关闭**（圆按钮，红悬停）；最大化/最小化可选（设置开关），默认隐藏以贴 GNOME |
| 标题栏图标 | 左侧应用图标 16px | 保留（可选关） |
| 边框 | 聚焦蓝 1.5px | 聚焦时**极淡白边** + 更强阴影，非聚焦无边框 |
| 阴影 | 聚焦 blur18 / 非聚焦 blur10 | 聚焦 blur24 offset(0,12) alpha0.4 / 非聚焦 blur8 alpha0.18 |

### 5.2 按钮交互
- **关闭**：圆形（直径 20），默认 `textMuted`，悬停 `#E6614C`（GNOME close-hover 红偏橘）。点击 `requestClose`（保留 `onWillClose` 未保存拦截）。
- **最大化**（可选）：仅在悬停标题栏时渐显，避免常驻噪音；双击标题栏最大化保留。
- **右键标题栏**：保留现有 `_showTileMenu`（388-451）作为高级布局入口。
- **贴边/snap**：保留 `_SnapMaximizeBtn` 的长按/右键 snap 选择器，但视觉并入标题栏右键菜单，减少常驻按钮。

### 5.3 HeaderBar 动作注入（可选增强，P2）
- 允许 app 向 HeaderBar 注入自定义动作按钮（如文件管理器的「上级目录」、编辑器的「保存」）。`DesktopWindow` 增 `List<HeaderAction>? headerActions`，`DesktopWindowFrame._TitleBar` 在标题左侧（或关闭按钮左侧）渲染。本期可仅留接口、不强制各 app 接入。

### 5.4 改动点
- `desktop_window_frame.dart`：`_TitleBar` 重写（345-540）；`titleBarH: 30 → 36`；圆角 `8 → 12`；`build`（66-178）调整背景与阴影。
- `desktop_window_manager.dart`：`titleBarH: 30 → 36`；`_clampDragRect`（1039-1050）`maxTop` 用新 `titleBarH`。
- `DesktopSettingsStore` 新增 `windowShowMaximize`（默认 false）、`windowShowMinimize`（默认 false）、`headerBarCenterTitle`（默认 true）。

---

## 6. 工作流 E：Adwaita 配色（P1）

### 6.1 新色板

`WorkbenchColors` 新增 `gnomeDark`（与 `dark` 并列，设置可切）：

| token | 现 dark | gnomeDark（目标） | 说明 |
|---|---|---|---|
| bg | `#111113` | `#1d1d20` | Adwaita window bg |
| topBar | `#1B1B1F` | `#1c1c1c` | 顶栏（半透明叠加模糊） |
| panel | `#16171A` | `#242428` | HeaderBar / 内容底 |
| panelElevated | `#202126` | `#303036` | 弹层 / Dash |
| border | `#303139` | `#FFFFFF14`（alpha 8%） | Adwaita 极淡白边 |
| accentBlue | `#0A84FF` | `#3584e4` | Adwaita accent blue |
| primaryText | `#FFFFFF` | `#FFFFFF` | |
| secondaryText | `#E7E7EC` | `#c0bfbc` | |
| textMuted | `#A1A1AA` | `#9a9a9a` | |

### 6.2 改动点
- `workbench_theme.dart`：新增 `static const gnomeDark`；`WorkbenchColorsContext.wb` 按 `desktopSettings.colorScheme` 选择。
- `DesktopSettingsStore` 新增 `colorScheme`（`'dark' | 'gnomeDark'`，默认 `gnomeDark`）+ `persist`。
- 桌面设置对话框增「配色方案」单选。
- 顶栏 / 概览 / Dash 背景：`panelElevated.withValues(alpha: 0.85)` + `BackdropFilter(ImageFilter.blur(20))` 实现毛玻璃。

---

## 7. 工作流 F：工作区垂直化（P1）

### 7.1 概览右侧垂直切换器
- 每个工作区一张缩略图卡片（160×100），纵向排列，当前高亮 + 蓝边。
- 点击切换；悬停右上角「×」删除（`removeWorkspace`）；底部「+」新增（`addWorkspace`）。
- 拖拽窗口缩略图到某工作区卡片 → `moveWindowToWorkspace`。

### 7.2 横向切换保留
- `Ctrl+←/→` 切换工作区（`remote_desktop_view.dart:300-317`）保留。
- 顶栏不常驻工作区指示（GNOME 不在顶栏放工作区），改由概览承载；可选：顶栏左侧 Activities 旁显示当前工作区序号「1/3」。

### 7.3 动态工作区（可选，P2）
- 末尾始终留一个空工作区（GNOME 行为）；窗口移空的非末尾工作区自动删除。本期可仅留接口、默认关。

---

## 8. 工作流 G：动画与毛玻璃（P1）

- **概览进入**：`AnimatedSwitcher` + `AnimationController`（250ms，`Curves.easeOutCubic`）：背景模糊 0→20、缩略图缩放 0.92→1.0 + 淡入。
- **顶栏出现**：`taskbarAutohide` 时 `SlideTransition`（y: -32→0，200ms）。
- **窗口聚焦**：聚焦/失焦阴影与边框用 `AnimatedContainer`（150ms）过渡，替代当前瞬切。
- **Dash 悬停**：图标 `ScaleTransition` 1.0→1.1。
- **毛玻璃**：`BackdropFilter(filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20))` 包裹顶栏、概览背景、Dash、Quick Settings。注意用 `RepaintBoundary` 隔离避免整桌面重绘。

---

## 9. 工作流 H：桌面图标策略（P2）

- **默认隐藏**左上 16 个桌面快捷方式（`remote_desktop_view.dart:776-796` `_shortcutLayer`），启动改走 Dash / 应用网格 / 命令面板。
- `DesktopSettingsStore.showDesktopIcons`（默认 false）+ 设置开关 + 右键菜单「显示桌面图标」。
- 保留实现（`_DesktopShortcutIcon`），仅按开关显隐——零删除，可回退。

---

## 10. 工作流 I：设置与快捷键（P2）

### 10.1 设置项扩展（`DesktopSettingsStore` + 对话框）

| 新增键 | 默认 | 说明 |
|---|---|---|
| `colorScheme` | `gnomeDark` | 配色方案 |
| `topBarAutohide` | false | 顶栏自动隐藏（复用既有 `taskbarAutohide` 语义，重命名） |
| `showDesktopIcons` | false | 桌面快捷方式 |
| `windowShowMaximize` | false | 标题栏最大化按钮 |
| `windowShowMinimize` | false | 标题栏最小化按钮 |
| `headerBarCenterTitle` | true | 标题居中 |
| `dashFavorites` | `[terminal,files,browser,monitor,logs,containers]` | Dash 收藏应用 |
| `overviewOnSuper` | true | Super 进概览 |

### 10.2 快捷键对齐 GNOME（`remote_desktop_view.dart` CallbackShortcuts）

| 键 | 现状 | 改为 |
|---|---|---|
| `Super`（单独） | 无 | 进/出概览 |
| `Super+Tab` | 无 | 循环焦点（现 `Ctrl+\`` 保留作兼容） |
| `Super+↑` | Alt+↑ 最大化 | 最大化（保留 Alt+↑ 兼容） |
| `Super+↓` | Alt+↓ 最小化 | 还原/最小化 |
| `Super+←/→` | Alt+←/→ 贴边 | 左右半屏（保留 Alt 兼容） |
| `Super+1..9` | Ctrl+1..9 切工作区 | 切工作区（保留 Ctrl 兼容） |
| `/`（概览中） | 无 | 直达搜索 |

> meta 单独按键需 `HardwareKeyboard` + `FocusNode.onKeyEvent` 检测 meta 的 down→up 无插入字符；与现有 `workbenchMetaOrControl` 工具协同。

---

## 11. 实施计划（分阶段）

> 每阶段独立可交付、可回退；先骨架后美化，先功能后动画。

### 阶段 1：配色 + 窗口装饰 GNOME 化（D + E，最低风险、最高可见度）
1. `workbench_theme.dart` 加 `gnomeDark` 色板 + `colorScheme` 设置。
2. `desktop_window_frame.dart`：圆角 12、标题栏同色融合、36px、关闭按钮右侧圆按钮、最大化/最小化按开关显隐、`AnimatedContainer` 聚焦过渡。
3. `desktop_settings_dialog.dart`：配色方案、窗口按钮开关。
4. 验证：16 个 app 无侵入，终端焦点/选择不回归。

### 阶段 2：顶栏（A）
1. 新建 `desktop_top_bar.dart`，迁移 `desktop_taskbar.dart` 的托盘/状态逻辑，布局改顶部 32px。
2. `remote_desktop_view.dart`：窗口层 `bottom→top`。
3. `desktop_window_manager.dart`：`taskbarH 44→32`，几何辅助方法 `workAreaTop()/workAreaHeight()`。
4. Quick Settings 面板。
5. 接线 `topBarAutohide`。

### 阶段 3：应用注册表 + Dash + 应用网格（C）
1. 抽 `desktop_app_registry.dart`，三处 switch 改读它。
2. 概览内实现 Dash + 应用网格（先静态，无缩略图）。

### 阶段 4：Activities 概览（B + F）
1. `desktop_window_manager.dart`：`overviewOpen` 状态机。
2. 新建 `desktop_overview.dart`：搜索 + 窗口缩略图网格 + 垂直工作区 + Dash。
3. 抽 `DesktopSearchEngine`，命令面板复用。
4. 窗口/工作区缩略图 `RepaintBoundary` 缓存。

### 阶段 5：动画 + 毛玻璃（G）
1. 概览进入/退出过渡。
2. 顶栏/Dash/Quick Settings `BackdropFilter`。
3. 性能验证：`RepaintBoundary` 隔离，拖窗/打字不触发概览层重绘。

### 阶段 6：桌面图标策略 + 快捷键 + 收尾（H + I）
1. 桌面图标默认隐藏 + 开关。
2. Super 进概览等快捷键。
3. 本地化：新增外壳字符串补 `app_localizations_*.dart`。

### 文件清单（新增 / 主要改动）

| 文件 | 动作 |
|---|---|
| `lib/desktop/desktop_top_bar.dart` | 新增 |
| `lib/desktop/desktop_overview.dart` | 新增 |
| `lib/desktop/desktop_app_registry.dart` | 新增 |
| `lib/desktop/desktop_search_engine.dart` | 新增（从 command_palette 迁移） |
| `lib/desktop/desktop_window_frame.dart` | 改：HeaderBar 重写 |
| `lib/desktop/desktop_window_manager.dart` | 改：taskbarH、工作区顶部、overview 状态 |
| `lib/desktop/remote_desktop_view.dart` | 改：顶栏、概览叠加、桌面图标开关 |
| `lib/desktop/desktop_taskbar.dart` | 弃用/拆分（逻辑迁入 top_bar + overview） |
| `lib/desktop/desktop_command_palette.dart` | 改：复用 search engine |
| `lib/theme/workbench_theme.dart` | 改：gnomeDark 色板 |
| `lib/services/desktop_settings_store.dart` | 改：新增键 |
| `lib/widgets/desktop_settings_dialog.dart` | 改：新增项 UI |
| `test/desktop_window_manager_test.dart` | 改：几何语义（顶栏） |

---

## 12. 风险与回归

| 风险 | 影响 | 缓解 |
|---|---|---|
| **几何语义反转**（底→顶） | `displayRect`/`tile`/`clamp`/`snapHint` 都假设底部留 taskbarH | 统一 `workAreaTop()/workAreaHeight()` 辅助方法，单点改；补 widget 测试 |
| **窗口缩略图性能** | 16 app 实时截图可能卡 | `RepaintBoundary` 缓存，仅概览打开时截，几何变更失效；先做静态占位再上截图 |
| **毛玻璃性能** | `BackdropFilter` 大面积模糊贵 | 仅顶栏/概览局部用；`RepaintBoundary` 隔离；低端机设置关 |
| **Super 单键检测** | meta down/up 易误判、与终端快捷键冲突 | 仅在概览关闭且无聚焦终端输入时响应；保留 Ctrl+Shift+P 兼容 |
| **配色回退** | 用户习惯原苹果蓝 | `colorScheme` 可切回 `dark`；不删原色板 |
| **标题栏按钮减少** | 习惯三按钮用户不适 | `windowShowMaximize/Minimize` 开关默认 false 可开；双击/右键菜单保留全部能力 |
| **桌面图标隐藏** | 老用户找不到入口 | Dash + 应用网格 + 命令面板三重入口；设置可恢复桌面图标 |
| **测试覆盖** | 几何/工作区/概览状态无护栏 | 阶段 1/2/4 各补 widget 测试：顶栏几何、概览状态机、工作区切换 |

---

## 13. 验收标准

1. 桌面默认呈现：顶部 32px 顶栏（Activities / 远端时钟 / Quick Settings）+ Adwaita 暗色 + 12px 圆角融合窗口。
2. Super / 点 Activities 进入概览：搜索 + 当前工作区窗口缩略图 + 右侧垂直工作区 + 底部 Dash，250ms 过渡。
3. Dash 启动应用、应用网格覆盖 16 个应用。
4. 窗口：关闭按钮在右（圆）、最大化/最小化按设置显隐、双击最大化、右键 snap 布局保留。
5. 工作区：概览垂直切换、拖窗跨工作区、Ctrl+←/→ 保留。
6. 设置：配色可切回原 dark、顶栏自动隐藏、桌面图标可恢复。
7. 终端模式零回归：终端焦点、选择、PTY、xterm 渲染不受影响。
8. 16 个应用业务逻辑零改动。
