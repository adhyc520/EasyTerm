# 编辑器查找 / 替换 / 跳行增强方案

> 目标：让两个编辑器（终端模式回退版 + 桌面多标签版）的「查找 / 替换 / 跳行」能力对齐到现代编辑器水准。当前桌面版已有查找替换骨架，但终端模式版完全空白；桌面版还缺「命中高亮、自动滚入视区、替换保留撤销、查找历史」。
>
> 基线事实已逐行核实（见 §0）。本方案不改 SSH/SFTP 保存路径、不改 `SyntaxEditingController` 着色契约。

---

## 0. 现状评估（已核实，含行号）

### 0.1 两个独立编辑器

| 文件 | 行数 | 角色 | 查找/替换 | 行号 | 跳行 |
|---|---|---|---|---|---|
| `lib/screens/remote_editor_screen.dart` | 272 | 终端模式回退（`sftp_browser.dart:1681` 在非桌面模式以路由打开） | **无** | **无** | **无** |
| `lib/desktop/apps/editor_app.dart` | 2101 | 桌面多标签主力 | **已有** | 已有 | 已有 |

两者共享 `SyntaxEditingController`（`lib/util/editor_highlight.dart:91-183`），高亮能力一致。

### 0.2 终端模式版 `remote_editor_screen.dart` 现状（缺口集中地）

- 文本控制器：`SyntaxEditingController`（`:31-34`），按文件名设语言。
- 工具栏（AppBar actions）：**仅一个 Save 按钮**（`:158-168`）。
- 快捷键：**仅 `Cmd/Ctrl+S` 保存**（`:142-145`）。
- 底层 widget：`TextField(maxLines: null, expands: true)`（`:248`），monospace，**无行号 gutter**。
- 已有：远端 mtime 轮询变更检测（`:47`，3s）、语法错误横幅（`:213-244`）。
- 缺失：查找、替换、跳行、行号、Tab 缩进、自动换行切换、编码选择。

### 0.3 桌面版 `editor_app.dart` 已有的查找替换（避免重复造轮子）

- 状态字段（`:328-338`）：`_findOpen` / `_replaceMode` / `_findCaseSensitive` / `_findRegex` / `_findWholeWord` / `_findCtrl` / `_replaceCtrl` / `_findIndex` / `_findHits` / `_findRegexInvalid`；`_FindHit`（`:295-300`）。
- 核心方法：
  - `_rebuildFindHits()`（`:1008-1058`）—— 按选项重建命中列表（正则 / 普通 / 全词）。
  - `_selectFindHit()`（`:1060-1070`）—— 设 `tab.text.selection` 选中当前命中。
  - `_findNext({reverse})`（`:1072-1093`）—— 循环上/下一个。
  - `_replaceOne()`（`:1136-1167`）—— 替换当前选中命中。
  - `_replaceAll()`（`:1169-1190`）—— 从后往前替换全部。
  - `_jumpToLine()`（`:1192-1209`）+ `_gotoLine()` 对话框（`:1211-1247`）。
- 快捷键（`:1296-1344`）：`S` / `F` / `H` / `G` / `Shift+G` / `L`。
- 查找栏 UI（`:1490-1652`）：输入框 + `Aa`/`.*`/`W` 三 Chip + 上/下按钮 + 命中计数 + 替换输入框 + 替换/全部替换。

### 0.4 桌面版查找替换的 4 个明确缺口

| # | 缺口 | 现状证据 | 后果 |
|---|---|---|---|
| 1 | **文本内不标注所有命中**，仅选中当前命中。 | `_selectFindHit()` 只 `tab.text.selection =`（`:1060-1070`） | 大文件里看不到其它匹配分布，只能逐个翻。 |
| 2 | **命中后不自动滚入视区**。 | `_selectFindHit()` 设 selection 后未调用 `ScrollController` / `bringIntoView` | 跨屏命中时选区设在不可见行，用户得手动滚。 |
| 3 | **替换破坏 TextField 撤销栈**。 | `_replaceOne()` / `_replaceAll()` 直接 `tab.text.value = ...`（`:1156, 1186`） | 替换后 `Cmd/Ctrl+Z` 不能回退替换，与编辑器直觉相悖。 |
| 4 | **查找无历史**，每次重开栏为空。 | `_findCtrl` 为普通 `TextEditingController`，无持久化 | 高频重复查找要重输。 |

### 0.5 终端版 `remote_editor_screen.dart` 的「补齐还是废弃」判断

- 它仅在**非桌面模式**（移动端 / 无 desktop chrome）被 `sftp_browser.dart:1681` 以路由形式打开，是真实在用的入口，不能直接删。
- 但其 TextField 无 `ScrollController`、无 gutter、无多 tab，把桌面版 2100 行整体搬过来不现实。
- 结论：**抽取共享查找替换组件**，两端复用；终端版额外补行号 gutter + 跳行（轻量）。

---

## 1. 目标与范围

| 工作流 | 目标 | 优先级 |
|---|---|---|
| **A. 共享查找替换组件** | 把桌面版的查找/替换逻辑抽成 `EditorFindReplaceController` + `EditorFindBar`，终端版与桌面版共用。 | P0 |
| **B. 终端模式版补齐** | 接入共享组件；加行号 gutter、跳行、Tab 缩进；保留现有 mtime/语法横幅。 | P0 |
| **C. 桌面版增强** | 命中高亮标注、命中自动滚入视区、替换保留撤销栈、查找历史持久化。 | P1 |
| **D. 测试** | 共享控制器纯函数测试（命中/替换/正则/全词/边界）+ 终端版 widget 测试。 | P1 |

### 非目标
- 不改 `SyntaxEditingController.buildTextSpan()` 着色管线（>120k 字符跳过高亮的策略保留，`editor_highlight.dart:152-158`）。
- 不引入代码折叠、多光标、LSP——本期不做。
- 不改文件大小上限 `kMaxEditorBytes = 512KB`（`ssh_workspace_controller.dart:41`）。

---

## 2. 工作流 A：共享查找替换组件（P0）

### 2.1 新增 `lib/widgets/editor_find_bar.dart`

把 `editor_app.dart` 的查找替换状态 + 方法剥离为一个可复用控制器与配套栏 UI。

```dart
/// 与具体编辑器解耦的查找/替换控制器。
/// 持有选项、命中列表、当前索引；通过 [onApplySelection] 让宿主把命中映射成
/// TextField 的 TextSelection（不同编辑器的 controller/scroll 各异，故回调外抛）。
class EditorFindReplaceController extends ChangeNotifier {
  EditorFindReplaceController();

  bool open = false;
  bool replaceMode = false;
  bool caseSensitive = false;
  bool regex = false;
  bool wholeWord = false;
  bool regexInvalid = false;

  final TextEditingController findCtrl = TextEditingController();
  final TextEditingController replaceCtrl = TextEditingController();

  List<_FindHit> hits = const [];
  int index = -1;

  /// 宿主提供：把 [hit] 映射成选区并（可选）滚入视区。
  void Function(_FindHit hit)? onApplySelection;
  /// 宿主提供：取当前被编辑的纯文本。
  String Function()? getText;
  /// 宿主提供：替换 [hit] 处文本为 [replacement]，返回替换后新选区。
  /// 宿主负责保留撤销栈（用 TextEditingValue 不可变替换 + keepComposing）。
  void Function(_FindHit hit, String replacement)? onReplace;

  void rebuildHits() { /* 从 editor_app._rebuildFindHits 平移：正则/普通/全词 */ }
  void findNext({bool reverse = false}) { /* 平移 :1072-1093 */ }
  void replaceOne() { /* 调 onReplace */ }
  void replaceAll() { /* 从后往前调 onReplace */ }
}
```

**抽取要点**：
- `_rebuildFindHits`（`editor_app.dart:1008-1058`）、`_isWholeWordMatch`（`:310-319`）是纯函数，直接平移。
- `_FindHit`（`:295-300`）从 `editor_app.dart` 移到共享文件，桌面版 `import` 复用。
- 选项 Chip（`Aa`/`.*`/`W`）、命中计数、正则无效红边框 UI（`:1490-1652`）平移为 `EditorFindBar` widget，接受 `EditorFindReplaceController`。

### 2.2 桌面版接入（重构，行为不变）

`_EditorAppState` 删除 `_findOpen/_replaceMode/_findCaseSensitive/...` 一组字段（`:328-338`），改为持有 `EditorFindReplaceController`（每个 tab 一个，随 `_EditorTab` 创建/销毁）。

- `_rebuildFindHits/_selectFindHit/_findNext/_replaceOne/_replaceAll`（`:1008-1190`）整体删除，改为 `ctrl.rebuildHits()` 等。
- `onApplySelection` = 选中 `tab.text`（原 `_selectFindHit` 逻辑）**+ 工作流 C 的滚入视区**。
- `onReplace` = 工作流 C 的「保留撤销」替换。
- 快捷键绑定（`:1296-1344`）不变，调用点改为 `ctrl.findNext()` 等。
- 查找栏 build（`:1490-1652`）替换为 `EditorFindBar(controller: ctrl)`。

### 2.3 终端版接入（新增能力）

`remote_editor_screen.dart`：
- 新增 `EditorFindReplaceController _find`、`ScrollController _scroll`（给 TextField）、`GloballyKey` 或 `LayerLink`。
- AppBar actions（`:158-168`）在 Save 前加 `IconButton(Icons.search)` 切换 `_find.open`。
- `CallbackShortcuts`（现仅 S，`:142-145`）追加 `F`/`H`/`G`/`Shift+G`/`L`，复用 `workbenchMetaOrControl`。
- `onApplySelection`：把命中偏移转成 `TextSelection`，设给 `SyntaxEditingController`，并 `_scroll` 滚动（见 §3）。
- `onReplace`：见 §3 保留撤销。
- `getText`：`return _ctrl.text;`。

---

## 3. 工作流 B：终端模式版补齐（P0）

### 3.1 行号 gutter

终端版目前是裸 `TextField`（`:248`）。改为 `Row`：左侧 gutter `Text`（右对齐 monospace，颜色 `wb.textMuted`）+ 右侧 `Expanded(TextField)`，整体包 `SingleChildScrollView(vertical)` 共享滚动，与桌面版 gutter 思路一致（`editor_app.dart:2021-2084`）。

- 行数：`'\n'.allMatches(text).length + 1`。
- gutter 宽：`(24.0 + lineCount.toString().length * 7).clamp(32, 60)`。
- 点击行号跳到该行（轻量交互，可选）。

### 3.2 跳行

复用桌面版 `_gotoLine` 对话框思路（`editor_app.dart:1211-1247`）抽出共享 `showGotoLineDialog`，返回行号；终端版拿到后：
```
final offset = _lineOffset(line);  // 累计 '\n' 计算字符偏移
_ctrl.selection = TextSelection.collapsed(offset);
_ctrl..notifyListeners();          // 触发高亮重算
_scrollToOffset(offset);
```

### 3.3 Tab 缩进

终端版补 `Tab` 键处理（桌面版已实现 `:1904-1971`）：`TextField` 的 `onKeyDown`/`shortcuts` 拦截 `Tab` 插入 2 或 4 空格（按现有缩进推断），`Shift+Tab` 反缩进当前行。逻辑直接从桌面版 `_handleTab`/`_dedent` 平移为顶层函数。

### 3.4 替换保留撤销（终端版 + 桌面版共用，归到工作流 C 实现细节）

见 §4.3。

---

## 4. 工作流 C：桌面版增强（P1）

### 4.1 命中高亮（缺口 1）

`SyntaxEditingController.buildTextSpan()` 已重写（`editor_highlight.dart:91-183`）。在着色 `TextSpan` 生成后，叠加命中背景：

- `EditorFindReplaceController` 暴露 `List<TextRange> hitRanges`（命中在全文的字符偏移，`_rebuildFindHits` 已有起始偏移 + 长度）。
- 控制器 `buildTextSpan` 时，若 `hitRanges` 非空，在对应 `TextSpan` 上套 `backgroundColor: wb.findHitBg`（半透明黄），当前命中用 `wb.findHitCurrentBg`。
- 缓存键（`_cacheText/_cacheSpan`，`editor_highlight.dart` 现有缓存）加入 `hitRanges` 指纹，避免命中变化不重绘。
- 性能：>120k 字符本就跳过高亮（`:152-158`），命中高亮同样跳过；常规文件命中数 < 几百时叠加成本可忽略。

### 4.2 命中自动滚入视区（缺口 2）

`onApplySelection` 在设 selection 后，调一次 `Scrollable.ensureVisible` 或手动滚：
```
final boxes = _editableKey.currentContext?.findRenderObject();
// 用 TextPainter 估算命中行 y，或更稳妥：
// 给 TextField 挂一个 ScrollController，命中行号 -> 行高 * 行号 jumpTo。
```
桌面版已有 gutter 行高信息（`:2021`），可复用 `lineHeight`。终端版 §3 用 `_scroll`。

兜底：用 `Scrollable.ensureVisible` 配合 `TextField` 的 `selection` 不直接生效（TextField 内部自滚只对光标），故优先用行号 × 行高手动 `jumpTo`，再 `clamp(minScrollExtent, maxScrollExtent)`。

### 4.3 替换保留撤销栈（缺口 3）

当前 `_replaceOne` 直接 `tab.text.value = newValue`（`:1156`），覆盖 `TextEditingController` 的撤销栈。改为：

```dart
void replacePreservingUndo(TextEditingController tec, _FindHit hit, String rep) {
  final text = tec.text;
  final before = text.substring(0, hit.start);
  final after = text.substring(hit.start + hit.length);
  final next = before + rep + after;
  // 用 selection 标记插入点，让 TextEditingController 把旧值压入 undo 历史
  tec.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(before.length + rep.length),
    composing: TextRange.empty,
  );
}
```

注意：Flutter `TextField` 的 undo 仅在「用户手势 / IME」触发的值变更才压栈；代码直接赋 `value` 不入栈。**正确做法**：用 `TextEditingController` 的 `userGuess` 不可行，需走 `EditableTextState` 的 `replaceText`（内部会压 undo）。但 `EditableTextState` 不公开。**可行替代**：引入 `UndoHistoryController`（Flutter 3.x 起 `TextField` 支持 `undoController`）：

```dart
final UndoHistoryController _undo = UndoHistoryController();
// TextField(undoController: _undo, ...)
// 替换时：
_undo.beginHistoryTransaction();          // 旧值入栈
tec.value = TextEditingValue(text: next, selection: ...);
_undo.endHistoryTransaction();
```

`UndoHistoryController` 在 Flutter SDK 中稳定可用（`package:flutter/widgets.dart`）。`replaceAll` 在循环里对每个命中开一个 transaction（或合并为一个 transaction 批量替换后整体入栈一次，更符合「全部替换可一次撤销」的直觉）。

> 验证点：实施时确认目标 Flutter 版本（`sdk: ^3.11.5`，pubspec）`UndoHistoryController` API 签名一致。

### 4.4 查找历史（缺口 4）

- `EditorFindReplaceController` 在 `findNext` / 关闭栏时，把非空 query 推入去重历史列表（最多 20 条）。
- 持久化：新增 `lib/services/editor_find_history_store.dart`（SharedPreferences，key `editor_find_history`），仿 `browser_history_store.dart` 结构。
- `EditorFindBar` 的查找输入框加 `Autocomplete`/下拉箭头展开历史，点击回填。
- 历史跨编辑器实例共享（全局 store），与桌面/终端版无关。

---

## 5. 工作流 D：测试（P1）

### 5.1 共享控制器纯函数测试 `test/editor_find_replace_test.dart`

- `rebuildHits`：普通/大小写敏感/正则/全词各一组；空 query 返回空；正则无效置 `regexInvalid`。
- `findNext` 循环上/下边界（首位再 next 回到 0；首位 prev 到末尾）。
- `replaceOne` 后命中列表重算且索引指向下一命中（与桌面版现有行为一致）。
- `replaceAll`：从后往前替换，命中数归零，文本正确。
- 边界：命中跨行、命中含 `\n`、替换串比原串长 / 短。

### 5.2 终端版 widget 测试 `test/remote_editor_screen_test.dart`

- 打开查找栏（`F`）→ 输入 → 命中选中 → `G` 下一个 → 替换 → 文本更新。
- 跳行对话框输入行号 → 光标落在该行首。
- 行号 gutter 行数与文本行数一致；新增行后 gutter 更新。

### 5.3 桌面版回归

- 现有 `test/editor_syntax_test.dart` / `test/editor_highlight_test.dart` 不受影响（着色契约未改）。
- 新增命中高亮：构造 `SyntaxEditingController` + `hitRanges`，断言 `buildTextSpan` 叶子节点背景色命中预期。

---

## 6. 实施顺序与风险

1. **A 抽取共享组件**（先不改行为，桌面版接入后跑现有用例确认无回归）→ 2. **B 终端版接入 + 行号 + 跳行 + Tab** → 3. **C 桌面版 4 缺口**（4.3 撤销最需实测）→ 4. **D 测试**。

| 风险 | 缓解 |
|---|---|
| `UndoHistoryController` API 在目标 SDK 签名差异 | 实施首步写最小 demo 验证；不可用则退回 `value=` 赋值并文档标注「替换不可撤销」（不阻塞其余缺口）。 |
| 命中高亮叠加与 IME composing 冲突 | 现有着色已跳过 composing 区（`:132-139`），命中高亮沿用同一跳过逻辑。 |
| 终端版 `TextField` 无 `ScrollController` 改造影响 mtime 轮询布局 | gutter/scroll 只包外层结构，不动 `_poll` 与 `SyntaxEditingController`。 |
| 桌面版重构（删字段改 controller）破坏现有 8 标签场景 | 抽取后先在桌面版单 tab 跑全流程，再回归多 tab。 |

---

## 7. 涉及文件清单

| 文件 | 动作 |
|---|---|
| `lib/widgets/editor_find_bar.dart` | 新增（共享控制器 + 栏 UI） |
| `lib/services/editor_find_history_store.dart` | 新增（查找历史持久化） |
| `lib/util/editor_highlight.dart` | 改：`buildTextSpan` 叠加命中高亮（`hitRanges`） |
| `lib/desktop/apps/editor_app.dart` | 重构：删查找字段/方法，接入共享控制器；补 4 缺口 |
| `lib/screens/remote_editor_screen.dart` | 改：接入共享组件 + 行号 gutter + 跳行 + Tab 缩进 |
| `lib/l10n/app_localizations_zh.dart` / `_en.dart` | 加：跳行/查找历史/替换等字符串 |
| `test/editor_find_replace_test.dart` | 新增 |
| `test/remote_editor_screen_test.dart` | 新增 |
