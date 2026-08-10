# 终端模式 / Windows 体验增强方案（第四轮）

> 四份独立方案，按用户提出的四个问题成文。每份均含已核实现状（行号）、目标与范围、工作流、代码草图、非目标、测试、风险、文件清单。可独立实施，依赖关系在文末标注。

| 问题 | 方案 | 核心结论 |
|---|---|---|
| 1. 文件编辑器功能更强（查找/替换等） | [editor-find-replace.md](editor-find-replace.md) | 桌面版已有查找替换骨架；终端模式版完全空白。抽共享组件两端复用 + 桌面版补「命中高亮/自动滚入/替换保留撤销/查找历史」 |
| 2. Windows 下终端模式 nano 无法复制 | [windows-nano-copy.md](windows-nano-copy.md) | 根因：缺 Shift 绕过鼠标模式。nano 开鼠标上报后选择被抢、选区被重绘冲掉。加 Shift 旁路 + 抑制 PTY 鼠标上报 + pointerUp 即复制 |
| 3. 终端模式 follow terminal folder | [terminal-follow-folder.md](terminal-follow-folder.md) | `_remoteCwd` 不跟踪 shell `cd`。在 `term.write` 前拦截 OSC 7 取真实 cwd，同步 SFTP 浏览器/状态栏 |
| 4. Windows 高分辨率显示 | [windows-high-dpi.md](windows-high-dpi.md) | manifest 已 PerMonitorV2（不糊）；缺口是无全局 UI 缩放。`MaterialApp.builder` 注入 `textScaler` + 终端字号联动 + 多显示器 DPI 兜底 |

## 共用件

- **`lib/services/pty_interceptor.dart`**（新增）由方案 2 与方案 3 共用：OSC 7 解析（cwd）+ 鼠标模式状态机（CSI ?1003h/l），一次扫流两用。两方案应同步实现拦截器。
- 其余互不耦合。

## 实施建议顺序

1. **pty_interceptor.dart**（方案 2+3 共基座）
2. 方案 2（nano 复制）+ 方案 3（follow folder）--同基座，并行
3. 方案 1（编辑器）--独立
4. 方案 4（高分屏）--独立；若工期紧可只做 §9 三件高收益项

## 基线

- 前序：`plan/desktop-next-iteration.md`、`plan2/gnome-desktop-redesign.md`、`plan3/desktop-apps-usability.md`（已实现/已并入主干，本目录工作树中已删）。
- 本轮聚焦「终端模式 + Windows + 编辑器」三条用户可直接感知的体验线，不改 SSH 连接模型与桌面外壳架构。
