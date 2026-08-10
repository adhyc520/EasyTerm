# Windows 终端模式 nano 无法复制 — 诊断与修复方案

> 现象：Windows 下终端模式运行 `nano` 时，无法选中屏幕文本并复制。用户要求「检查下是否有问题」。
>
> 结论先行：**根因是缺少「Shift 绕过鼠标模式」机制**——`nano` 开启鼠标上报后，xterm 把鼠标事件转发给 PTY（给 nano），而本项目的文本选择 `Listener` 既没有 Shift 旁路、也未在应用占用鼠标时抑制 PTY 上报，导致选择与 nano 抢事件；选区要么建不起来、要么被 nano 重绘冲掉。Windows 与 macOS/Linux 都受影响，但 Windows 用户更易触发（见 §1.3）。本方案给出可落地的修复 + 诊断核对表。

---

## 0. 现状评估（已核实，含行号）

### 0.1 终端选择与复制的完整链路

选择实现：`lib/widgets/terminal_surface.dart`，外层 `Listener`（`behavior: translucent`，`:715-721`）包裹 `TerminalView`：

- `_onTerminalPointerDown`（`:493-504`）：仅鼠标主键；**不检查 Shift 修饰键**；`rt.getCellOffset(local)` 算起始 cell，置 `_selStartCell`，并 `requestKeyboardFocus()`。
- `_onTerminalPointerMove`（`:506-522`）：拖动更新 `_selLastLocal`，`_selDidDrag=true` 后 `_scheduleApplySelection()`。
- `_onTerminalPointerUp`（`:532-540`）：拖动过则 `_applySelection()` 设 `_viewController.selection`。
- 选择只在**拖动**后生效（`_selDidDrag`），单击不产生选区。

复制路径（任选其一）：
1. `selectToCopy`（默认 **false**，`workbench_settings_store.dart:73`）：选区变化后 220ms 防抖自动 `Clipboard.setData`（`terminal_surface.dart:336-351`）。
2. `Ctrl+C`（Windows/Linux）：`_onTerminalKeyEvent`（`:568-599`）——有选区则复制，无选区则 `ignored` 放行给 PTY 发 SIGINT。
3. `Ctrl+Shift+C`（Windows/Linux）：xterm `shortcuts` 的 `CopySelectionTextIntent.copy`（`workbench_desktop_shortcuts.dart:48-49`）。
4. 右键菜单：`_showTerminalContextMenu`（`:601-695`）copy/paste/selectAll/clearSelection/clearBuffer。
5. macOS：`⌘C`（`:39-40`）。

### 0.2 xterm 4.0.0 鼠标上报（关键背景）

- `TerminalView` 内部手势处理器：当终端处于「鼠标上报模式」（DECSET 1000/1002/1003/1006 等，由应用发 `CSI ?1003h` 开启），xterm 把指针事件转成鼠标 escape 序列写给 PTY，**同时默认不再做文本选择**。
- `nano` 在 `set mouse`（`~/.nanorc`）或 `-m` 启动时开启鼠标上报；部分发行版/镜像默认开启。
- xterm 4.0.0 暴露的公开回调：`onTitleChange`（`terminal.dart:39`）、`onBell` 等；**无 `onMouseModeChange`、无 `isMouseModeActive` 公开 API**（grep `xterm-4.0.0/lib/src/terminal.dart` 确认）。

### 0.3 为什么「没有 Shift 旁路」是根因

本项目选择逻辑（`terminal_surface.dart:493-504`）：

- **不读 Shift**：主键按下即置 `_selStartCell`，与「是否想选择」无关。
- **不抑制 PTY 鼠标上报**：`Listener` 是 `translucent`，事件同时到达 `TerminalView`，xterm 照常把鼠标事件报给 nano。于是：
  - 用户在 nano 里拖选 → 本项目设了选区 → nano 也收到拖拽 → nano 移动光标 / 选区并重绘 → 重绘可能清掉本项目的选区高亮（selection 在 `TerminalView` 重绘后由 controller 持有，但 nano 切换 alt buffer / 全屏刷新会冲掉视觉）。
  - 更糟：nano 鼠标模式下，xterm 自己的选择被禁用，本项目的外层 `Listener` 虽能拿到坐标设选区，但**视觉高亮依赖 `_viewController.selection`**，而 nano 的全屏重绘会覆盖。

业界标准解法（gnome-terminal / iTerm2 / Windows Terminal / PuTTY 一致）：**按住 Shift 拖拽 = 强制本地文本选择，临时不报鼠标给应用**。本项目缺这一层。

### 0.4 与 Windows 的具体关联

- Windows 习惯「选中即复制 / 右键粘贴」（PuTTY/Windows Terminal），但本项目 `selectToCopy` 默认 false；用户在 nano 里选中后下意识直接松手期望已复制，实际未复制（需再按 Ctrl+Shift+C 或右键）。**这是「无法复制」的主观放大器**。
- `_onTerminalKeyEvent` 的 Ctrl+C 路径（`:582-598`）只判 `keyC + Ctrl + 无 Shift/Meta/Alt`。在 nano 里若选区没建起来（§0.3），Ctrl+C 直接 `ignored` → 进 PTY → nano 解释为「取消」，用户感觉「Ctrl+C 不复制」。
- `Clipboard.setData`（Flutter `services.dart`）在 Windows 上写系统剪贴板正常，**与 `super_clipboard` 不冲突**（后者用于 SFTP 文件 URI，见 `sftp_browser.dart:1964`）。剪贴板写入本身不是瓶颈。

---

## 1. 诊断核对表（实施前先跑，确认根因）

按序核对，定位是 §0.3（鼠标模式抢事件）还是另有 Windows 特例：

| # | 核对 | 预期（若根因成立） | 命令 |
|---|---|---|---|
| D1 | nano 是否开了鼠标上报 | 在 nano 里按住 Shift 拖选（当前代码下）仍不可靠；但 `nano -K`（关闭鼠标）后普通拖选+Ctrl+Shift+C 可复制 | 远端 `nano -K file` vs `nano file` |
| D2 | 是否 `~/.nanorc` 含 `set mouse` | 有则确认鼠标模式 | 远端 `grep -i mouse ~/.nanorc /etc/nanorc 2>/dev/null` |
| D3 | 选区是否建得起来 | 鼠标模式下拖选后右键菜单「复制」是否可用（菜单项 enabled 取决于 `_viewController.selection`，`:616`）；若禁用 = 选区没建 | 在 nano 里拖选后右键看菜单 |
| D4 | Ctrl+Shift+C 是否能复制已有选区 | shell 提示符下（非鼠标模式）选中后 Ctrl+Shift+C 可复制 → 证明剪贴板路径 OK | 退出 nano，在 bash 选中文字按 Ctrl+Shift+C |
| D5 | `selectToCopy=true` 后 shell 内是否自动复制 | 可 → 证明选择链路在非鼠标模式正常 | 设置里开启「选中复制」，shell 内拖选 |
| D6 | Windows 多显示器/DPI 下选区坐标是否漂移 | 与 DPI 无关（选择用 `rt.globalToLocal`+`getCellOffset`，逻辑像素） | 不同 DPI 屏拖选 |

**判定**：D1/D2/D3 命中即 §0.3 根因；D4/D5 旁证剪贴板链路无 Windows 特例。若 D4 在 shell 下也失败，则转查 `Clipboard.setData` Windows 路径（概率低，单独分支）。

---

## 2. 修复方案

### 2.1 工作流 A：Shift 旁路选择 + 抑制鼠标上报（P0，核心）

**目标**：按住 Shift 时，强制本地文本选择，且不把该次鼠标事件报给 PTY 应用。

#### 2.1.1 检测 Shift 与鼠标模式

`_onTerminalPointerDown` / `_onTerminalPointerMove` 入口加：

```dart
final shiftBypass = HardwareKeyboard.instance.isShiftPressed;
// 鼠标上报模式下，只有 Shift 旁路才做本地选择；
// 非鼠标上报模式，正常选择（保留现有行为）。
```

判定「终端是否处于鼠标上报模式」：xterm 4.0.0 未公开 `Terminal.isMouseModeActive`。两条路：

- **路 A（推荐，零侵入）**：在 PTY 输出流拦截 `CSI ?1000h/1002h/1003h/1006h/1015h`（开）与 `...l`（关），自维护 `_mouseMode` 布尔。拦截点与 follow-folder 的 OSC 7 拦截同处（见 `terminal-follow-folder.md` §2 的 `PtyInterceptor`），复用同一扫描器。开销极小。
- **路 B（兜底）**：不判模式，**始终允许 Shift 拖拽选择**且抑制上报。副作用：应用本要用 Shift+点击做别的（如 vim 的 Visual 模式扩展）会被吞。故路 A 更稳。

> 注意：即便不精确知道模式，**Shift 拖拽时抑制 PTY 鼠标上报**这一步是必须的，否则 nano 仍收到事件。抑制方式见 §2.1.2。

#### 2.1.2 Shift 拖拽时抑制 xterm 鼠标上报

难点：`Listener`（外层）拿到事件时，`TerminalView`（内层）也会拿到（translucent）。要让 nano 不收到，需在 Shift 旁路期间「吃掉」传给 `TerminalView` 的指针事件。

可行做法：用 `AbsorbPointer` 在 Shift 旁路期间包住 `TerminalView`：

```dart
// terminal_surface.dart build()
child: Listener(
  behavior: HitTestBehavior.translucent,
  onPointerDown: _onTerminalPointerDown, ...   // 始终先收到，做本地选择
  child: AbsorbPointer(
    absorbing: _shiftBypassActive,             // true 时挡住 TerminalView
    child: TerminalView(...),
  ),
),
```

- `_onTerminalPointerDown`：若 `shiftBypass`，置 `_shiftBypassActive=true`（`setState` 或仅字段，因 `AbsorbPointer` 用 `Listenable`？需 `setState` 触发 rebuild）。此时 `Listener` 仍能收到（`AbsorbPointer` 只挡子树，外层 `Listener` 不受影响）——**验证点**：`AbsorbPointer` 在 `translucent` `Listener` 下是否仍让外层 `Listener` 命中；若不行，改用 `Listener` 包 `IgnorePointer`+手动坐标，或把选择坐标算好后用 `PointerInterceptor`。
- `_onTerminalPointerUp` / `_onTerminalPointerCancel`：重置 `_shiftBypassActive=false`。
- 非 Shift：`_shiftBypassActive=false`，`TerminalView` 正常收事件、正常报鼠标给 nano，本项目 `Listener` 也设选区（现状）——但鼠标模式下选区会被 nano 重绘冲掉，这是预期（用户此时本就不该选中，需用 Shift）。

> 备选：不引入 `AbsorbPointer`，改在 PTY 写入侧拦截——即 xterm 把鼠标 escape 写给 `terminal.backend` 前，由我们包装的 backend 吞掉。但 `TerminalView` 的鼠标上报走内部 `backend`，不易插桩。故 `AbsorbPointer` 方案更可控。

#### 2.1.3 Shift 旁路下的复制闭环

Shift 拖选后选区已设 `_viewController.selection`，复制走现有任一路径：
- 右键菜单 copy（`:668-673`）。
- Ctrl+Shift+C。
- 若 `selectToCopy=true`，松手即复制（但 `selectToCopy` 现在是「buffer 变化」触发，`:336-351`，应在 `pointerUp` 时也触发一次 copy，见 §2.2）。

### 2.2 工作流 B：选择即复制的体验对齐（P1）

- **`pointerUp` 时复制**：`selectToCopy=true` 时，`_onTerminalPointerUp` 设完选区后立即 `Clipboard.setData`（不必等 220ms buffer 变化）。当前 `_onTerminalBufferChanged`（`:336`）只在终端有新输出时触发，nano 静态屏幕下永不会自动复制——这是 nano 场景「选中没复制」的另一成因。
- **Windows 默认 `selectToCopy` 建议**：Windows 平台首次启动时若未设过该项，默认置 `true`（PuTTY/Windows Terminal 习惯），右键改为「粘贴」（见 §2.3）。需在 `WorkbenchSettingsStore.load` 加「未设过且 Platform.isWindows → true」逻辑（用 `prefs.containsKey(_kSelectCopy)` 判是否设过）。

### 2.3 工作流 C：右键行为平台化（P2，可选）

Windows 终端惯例：有选区时右键=复制并清选区；无选区时右键=粘贴。当前右键恒出菜单（`:740-744`）。可加设置项「右键智能复制/粘贴」，Windows 默认开。nano 下尤其顺手（Shift 选中 → 右键即复制）。本项不阻塞核心修复。

### 2.4 工作流 D：nano 屏幕渲染核对（P1，回应「屏幕是否有问题」）

用户提到「屏幕」——核对 nano 在 alt buffer 下的渲染：
- nano 进 alt buffer（`CSI ?1049h`）→ 退出恢复。xterm 4.0.0 支持。
- 已知坑：若 `TERM` 非 `xterm-256color`（设置项 `terminalTermType`，默认 `xterm-256color`，`workbench_settings_store.dart:64`），nano 颜色/按键可能异常。核对设置项未被改为 `vt100`/`ansi`。
- 鼠标模式下选区高亮被 nano 重绘冲掉：§2.1 修复后用户用 Shift 旁路即可，不再依赖被冲掉的高亮。
- 无需改渲染层；若 D1-D6 显示 nano 画面本身花屏（与复制无关），再单开 alt buffer 渲染问题分支。

---

## 3. 测试

### 3.1 单元/ widget 测试 `test/terminal_shift_bypass_test.dart`

- 模拟 `nano` 鼠标模式：直接给 `terminal.write('CSI ?1003h')` 进入鼠标上报；构造 `TerminalSurface`，发模拟 `PointerDownEvent`（主键、带 `HardwareKeyboard.isShiftPressed=true`）→ 断言 `_viewController.selection` 被设、且 PTY 未收到鼠标 escape（需 backend 桩）。
- Shift 松开 / 非 Shift：选区不设（鼠标模式下），PTY 收到鼠标 escape。
- `selectToCopy=true` + `pointerUp`：断言 `Clipboard` 被写（用 `MockClipboard` 或 `TestDefaultBinaryMessenger` 拦 `ClipboardChannel`）。

### 3.2 手动核对矩阵

| 场景 | 期望 |
|---|---|
| nano（鼠标模式）Shift 拖选 + Ctrl+Shift+C | 复制成功 |
| nano（鼠标模式）Shift 拖选 + 右键 copy | 复制成功 |
| nano（鼠标模式）普通拖选（无 Shift） | 选区不抢 nano；nano 光标正常移动 |
| nano（鼠标模式）Shift 拖选 + `selectToCopy=true` | 松手即复制 |
| shell（非鼠标模式）普通拖选 + Ctrl+Shift+C | 复制成功（无回归） |
| shell 普通拖选 + Ctrl+C | 复制（有选区）/ SIGINT（无选区，无回归） |
| vim 鼠标模式 Shift 拖选 | 同 nano，可复制 |
| `less` / `tmux` 鼠标模式 | 同上 |

### 3.3 鼠标模式拦截单测

`PtyInterceptor`（与 follow-folder 共用）识别 `CSI ?1003h`/`l` 开关的单测：喂含拼包（`ESC [ ? 1 0 0 3 h` 跨 chunk）的流，断言 `_mouseMode` 状态机正确。

---

## 4. 风险与回退

| 风险 | 缓解 |
|---|---|
| `AbsorbPointer` 挡住 `TerminalView` 时外层 `Listener` 也收不到事件 | 实施首步写最小用例验证；不行则改为「`Listener` 在最外、`AbsorbPointer` 仅包 `TerminalView`，外层 `Listener` 用 `Opaque` 半命中」或手算坐标。 |
| Shift 旁路误吞 vim 的 Shift+点击 | 仅在**鼠标上报模式 + 主键 down + 拖动**时抑制；单击不拖动不抑制（`_selDidDrag` 判定）。vim Visual Block 的 `Ctrl+V` 不受影响（不走鼠标）。 |
| 路 A 鼠标模式状态机漏判罕见序列（1015/1006 组合） | 覆盖 1000/1002/1003/1006 四个主流；漏判则退化为「Shift 始终旁路」（路 B），功能不丢。 |
| Windows `selectToCopy` 默认改 true 影响已有用户 | 仅对 `containsKey==false`（从未设过）的新用户生效；老用户偏好不变。 |

---

## 5. 涉及文件清单

| 文件 | 动作 |
|---|---|
| `lib/widgets/terminal_surface.dart` | 改：Shift 旁路 + `AbsorbPointer` 抑制 + `pointerUp` 复制 |
| `lib/services/pty_interceptor.dart`（或复用 follow-folder 的 `PtyInterceptor`） | 新增/共用：CSI 鼠标模式状态机 + OSC 7 |
| `lib/services/workbench_settings_store.dart` | 改：Windows 新用户 `selectToCopy` 默认 true |
| `lib/widgets/workbench_terminal_settings_dialog.dart` | 改（可选）：右键行为设置项 |
| `lib/l10n/app_localizations_*.dart` | 加：Shift 选择提示等 |
| `test/terminal_shift_bypass_test.dart` | 新增 |

---

## 6. 与其它方案的关系

- 鼠标模式状态机的 PTY 流拦截器与 `terminal-follow-folder.md` 的 OSC 7 拦截器**同一文件、同一扫描循环**，应一并实现，避免两次扫流。
- 高分屏（`windows-high-dpi.md`）与本方案无耦合：选择坐标用逻辑像素，DPI 无关（D6 已核对）。
