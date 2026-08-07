# 附件：文件与终端应用细节（File & Terminal Apps）

> sftp_browser / terminal / transfers / run_command 全量发现（file:line + 修复）。对应主方案 §8。
> 附：桌面外壳可用性补充（§9 末），与 plan2（GNOME 视觉重塑）标注重叠处。

---

## 2. SFTP Browser / File Manager（`widgets/sftp_browser.dart` + `desktop_sftp_controller.dart`）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| 2.1 | `desktop_sftp_controller.dart:144-184` `sftp_browser.dart:2475-2518` | 仅面包屑，无返回/前进/上级 | controller 加历史栈 `canGoBack/Forward` + 工具栏返回/前进/上级按钮 |
| 2.2 | `desktop_sftp_controller.dart:107-109` | 仅滤 `.`/`..`，dotfile 恒显无开关 | `showHidden` 开关，过滤 `startsWith('.')` |
| 2.3 | `sftp_browser.dart:2823-2877` `desktop_sftp_controller.dart:101-106` | 列头不可点，固定目录优先+名称排序 | 头部 `InkWell` 循环 名/大小/修改 升降序 |
| 2.4 | `sftp_browser.dart:2393-2518` | 无 go-to-path | 面包屑可点转编辑路径字段，或 `⌘L`/`Ctrl+L` 输入 |
| 2.5 | 全文 | 无书签/最近 | 每主机持久书签 + 最近列表；面包屑栏星标 + 「快速访问」下拉 |
| 2.6 | `sftp_browser.dart:2120-2180` `1347-1402` | 权限仅 Properties 弹窗 stat，列表无列 | 详情视图模式：mode/owner/group 列 |
| 2.7 | `sftp_browser.dart:2467-2637` | 工具栏 ~12 按钮窄窗溢出（min 宽 240） | 按钮横滚或低频项（磁盘占用/上传文件夹）收进溢出菜单 |
| 2.8 | `desktop_sftp_controller.dart:114-116,155-158,180-183` | 加载失败 `catch->debugPrint` 静默空白 | controller 暴露 `loadError` -> `RemoteStateView(error, onRetry: refresh)` |
| 2.9 | `sftp_browser.dart:159-203` | 右键菜单无「复制路径」 | 加项复制 `remoteJoin(remoteCwd, name)` |
| 2.10 | `sftp_browser.dart:2501-2512` | 面包屑当前段也作链接样式 | 末段去下划线/蓝色，用 `secondaryText` |
| 2.11 | `sftp_browser.dart:1271-1323` | 搜索仅文件名、80 上限、深度 4、不可取消 | 取消按钮 + 截断提示 + 可配深度 + 可选内容搜索 `grep -l` |

---

## 4. Terminal（`terminal_app.dart` + `widgets/terminal_surface.dart`）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| 4.1 | `terminal_surface.dart:412-477,92-96` | theme 已定义 `searchHit*` 色但无搜索 UI | Cmd+F 查找栏，`TerminalController`/xterm 搜索高亮 + next/prev |
| 4.2 | `terminal_surface.dart:412-452` | 右键仅「清空选区」，无清屏/重置 | 加「清空缓冲区」`buffer.clear()` / 「重置终端」 |
| 4.3 | `terminal_surface.dart:520` `workbench_settings_store.dart:69` | 字号仅设置对话框 | Cmd+/-(Cmd+0 重置) 调 `terminalFontSize`（持久） |
| 4.4 | `terminal_app.dart` | 一窗一终端，多终端须多窗 | 窗内 tab/分屏（P2） |
| 4.5 | `terminal_surface.dart` | 滚离底部无指示/跳最新 | 离底显「↓ 跳最新」，新输出到达时脉冲 |

---

## 3. Transfers（`transfers_app.dart` + `sftp_upload_task_list.dart`）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| 3.1 | `transfers_app.dart:195-203` `sftp_upload_task_list.dart:136` | 失败行「取消」是 no-op，无重试 | 失败行显「重试」(重入队) 或取消禁用+tooltip |
| 3.2 | `sftp_upload_task_list.dart:62-72` `transfers_app.dart:98-101` | 「清空」清 UI 不取消进行中，后台孤儿上传 | 「清空」仅清失败/完成；进行中禁用；区分「清空失败」 |
| 3.3 | `transfers_app.dart:180-191` | 无速度/ETA | 滚动字节率窗，显「2.4 MB/s · ~1m20s」 |
| 3.4 | `sftp_upload_task_list.dart` | 仅 pending/uploading/failed，无暂停 | `paused` 态 + 逐行/批量暂停（chunk 边界尊重暂停标志，仿 `desktop_sftp_controller.dart:359-376`）（P2） |
| 3.5 | `sftp_upload_task_list.dart` | 严格追加序，无优先/重排 | 拖拽重排 + 「优先」 |
| 3.6 | `sftp_upload_task_list.dart:223-231` `transfers_app.dart` | 成功自动移除，「清空」等价清失败 | 加「清空失败」「全部重试」 |
| 7.2 | `transfers_app.dart:83-90` | 头部「本批 X/Y」失败后误导 | 三态「成功 X · 失败 Z · 进行中 N」 |

---

## 5. Run Command（`run_command_app.dart`）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| 5.1 | `:29` | 无命令历史 | 每主机持久历史 + ↑↓ 召回 + 下拉 |
| 5.2 | 全文 | 无收藏/预设 | 输入框星标收藏 + 常用命令 chip |
| 5.3 | `:215-229` | 输出逐行 `SelectableText`，跨行选不了 | 整段单 `SelectableText`(`\n` 连接) 支持自由多行选；保留「复制全部」 |
| 5.4 | `:82-88` | 每次运行清空前次输出 | 追加分隔 + 新输出，或保历史下拉 |
| 8.3 | `:220-228` | 长行不换行/横滚，溢出裁剪 | softWrap 或逐行横向 `SingleChildScrollView` |

---

## 6. 跨应用（文件/终端方向，主方案 §9 子集）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| 6.1 | `terminal_app.dart:186-202` `file_manager_app.dart:115-120` | file_manager->terminal 有，反向无 | 终端右键/命令面板「在文件管理器打开」`files{cwd: pwd}` |
| 6.2 | `remote_desktop_view.dart:86-91` | 桌面右键「在此打开终端」无 cwd（空桌面无「此」） | 改「打开终端」；editor 加「在终端打开」于文件父目录 |

---

## 9 末. 桌面外壳可用性补充

> 以下为外壳**功能/可用性**项（非 GNOME 视觉重塑）；与 plan2 重叠处标注。

| ID | 位置 | 问题 | 修复 | 与 plan2 |
|---|---|---|---|---|
| S1 | `desktop_taskbar.dart:81-99,106` | 工作区圆点 10px 无 label/tooltip/窗口数 | Tooltip「桌面 2 · 3 窗口」+ 命中区 ~20px | plan2 改垂直缩略图，本项过渡期补 tooltip |
| S2 | `desktop_taskbar.dart:43-53,557` | 窗口按钮不分组、溢出无指示 | 同类分组+计数徽标 或 滚动渐变/箭头 | plan2 用 Activities 概览替代；过渡期补溢出指示 |
| S3 | `remote_desktop_view.dart:443-509` | 掉线全屏模态遮罩，阻断背后窗口交互（读 scrollback/看传输） | 改可关闭横幅或非模态角 toast，仅阻断 SSH 依赖面 | 独立项，plan2 未含 |
| S4 | `desktop_taskbar.dart:273-281` | 「显示桌面」图标无状态区分 | 切图标或激活态高亮 | 独立项 |
| S5 | `desktop_window_frame.dart:524-583` | snap 布局几乎不可发现（tooltip 承诺 hover 但 onEnter 空） | 实现 hover snap 网格 或 改 tooltip「右键/长按选布局」+ 最大化按钮小箭头 | 独立项（主方案 §10 已列） |

> 主方案 §10 已含：命令面板补窗口命令+快捷键提示(S)、快捷键速查表、macOS 工作区键一致、snap 可发现性。

---

## 优先级（文件/终端内部）
**P0**：3.2 清空孤儿上传（数据） · 3.1 失败行无重试 · 2.8 SFTP 加载静默 · S2/S5（主方案 §10 mac 工作区键/snap）
**P1**：2.1 返回/上级 · 4.3 字号快捷键 · 4.1 终端搜索 · 5.1 命令历史 · S2 任务栏溢出 · S5 snap 发现
**P2**：2.7 工具栏溢出 · 2.2 隐藏开关 · 2.3 列排序 · 3.3 速度/ETA · 5.3 部分复制 · S3 掉线遮罩 · 命令面板补全 · 2.9 复制路径 · S1 工作区 tooltip · 6.1 终端->文件管理器
**P3**：2.10 面包屑当前段 · S4 显示桌面图标 · 4.2 清屏 · 3.6 清空失败/全部重试 · 8.3 长行 · 速查表
