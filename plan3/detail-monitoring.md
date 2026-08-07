# 附件：监控类应用细节（Monitoring Apps）

> task_manager / monitor / disk_usage 全量发现（file:line + 修复）。对应主方案 §5。
> 跨应用共性（已提炼到主方案 §0.2#7）：三应用均无 `Shortcuts`/`Clipboard`/`LayoutBuilder`，无键盘导航、无复制、无响应式。下文不重复，仅列各应用特有项。

---

## A. Task Manager（`lib/desktop/apps/task_manager_app.dart`，2253 行）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| A1 | `:129,147-154` | `_paused` 仅最小化；无暂停/间隔控制 | `PauseToggle`（B.4）；间隔下拉 1/3/10/30s |
| A2 | `:712-772,165-171` | 首次后 `_loading` 恒 false，刷新仅闪 spinner | `LastUpdatedChip` + 活动呼吸点 |
| A3 | `:514,465-522` | kill 恒 `force:true`（SIGKILL） | 确认框两按钮：结束=SIGTERM / 强制结束=SIGKILL；默认优雅（主方案 C8） |
| A4 | `:883` | 双击进程行直接开 kill 对话框 | **移除双击杀进程**；双击开详情（A5）；kill 走按钮/右键/Delete 键 |
| A5 | `:998-1113` `remote_process_list.dart:7-27` | 进程行仅 name/pid/user/cpu/mem，无 cmdline/PPID/启动时间 | 选中行展开详情或侧栏：读 `/proc/<pid>/cmdline`、PPID、启动时间；`RemoteProcess` 加字段 |
| A6 | `:884-902` | 右键仅「结束任务」；无跨 tab/跨应用联动 | 右键加「查看监听端口」(跳 Network 按 PID 过滤) /「查看日志」(`journalctl _PID=`，接 H) /「打开所在目录」(files at `/proc/pid/cwd`) |
| A7 | `:1700-1724` | UDP/非可浏览监听无任何动作（菜单 gated on `canBrowse`） | 所有监听行都有「复制端点」「查看进程」(按 PID 跳进程 tab)；「在浏览器打开」仅 TCP |
| A8 | 全文 | 无复制 | `CopyMenuItem`：进程行/监听行/服务行/挂载点 |
| A9 | `:560-578` | 服务控制仅「access denied」弹 SnackBar，其它成败静默 | 总弹 SnackBar 显成功/具体错误；重载后高亮该服务行 |
| A10 | 全文 | 无键盘导航 | `Focus`+`Shortcuts`：↑↓ 移选、Enter 开详情、Delete 杀、`/`或 Ctrl+F 聚焦过滤、Esc 清选 |
| A11 | `remote_process_list.dart:51` `:826-829` | 进程列表截断 800 无提示 | `length==800` 显「(可能截断，仅前 800)」并引导过滤 |
| A12 | `:961-981` `remote_process_list.dart:57-59,179-204` | Windows 缺 CPU/用户列无说明 | 富化 `Get-Process` 取 CPU/UserName；或显「Windows 下 CPU/用户列不可用」 |
| A13 | `:1505-1513,1544-1553` | 网络 rx/tx 各自归一，无法比较 | `SparklineCard` 共享刻度（max(rx∪tx)）；显峰值副标题 |
| A14 | `:268-288` `remote_network.dart:100` | 重连后速率按含断线时长算，产生尖峰 | `_onConnectionRestored` 清 `_netPrev`；或拒绝 >2x 预期间隔 |
| A15 | `:765,620-627` | 断线时刷新按钮 disabled，错误条无重试 | 错误条「重试」调 `controller.reconnect()`；不断线时仍可手动刷新 |
| A16 | `:940-995,1644-1677` | 固定列宽，窄窗名/地址列挤死 | `LayoutBuilder` 窄窗切堆叠/紧凑；或横向 `SingleChildScrollView`+minWidth |

---

## B. Monitor（`lib/desktop/apps/monitor_app.dart`，734 行）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| B1 | `:80,88` | 同 A1，仅最小化暂停、固定 5s | `PauseToggle` |
| B2 | `:109-111` `ssh_workspace_controller.dart:1613-1630` | 每 5s 探测 OS 三次（network/gpu/snapshot 各 `detectRemoteOs`） | 缓存 `_os`，三处传 `osHint`（对齐 task_manager；主方案 C7） |
| B3 | `:354-537` | 网络页无过滤搜索（task_manager 有） | `FilterField` |
| B4 | `:375-376` | 回环恒隐藏无开关（task_manager 有 chip） | 「隐藏回环」`FilterChip` |
| B5 | `:481-494` | 双击监听开浏览器无提示 | `Tooltip`「双击在浏览器打开」+ 尾部开浏览器图标按钮；可改单击 |
| B6 | `:417,481,336` | `take(8/40/10)` 静默截断 | 显「显示前 N（共 M）」+「显示全部」展开 |
| B7 | `:236-352,204-211` | `_snap==null && _error==null` 时满屏 `-` 卡无说明 | `RemoteStateView(empty)`「暂无资源数据」 |
| B8 | `:236-352` vs `task_manager:1119-1259` | 资源页与 task_manager 性能页近乎重复，可漂移 | 抽共享 `SparklineCard`/资源组件；择一为唯一资源视图或共享实现；至少文档化差异 |
| B9 | `:282-294` `task_manager:1185-1195` | GPU 无趋势线 | 每 GPU 维护 history 列表传 `SparklineCard` |

---

## C. Disk Usage（`lib/desktop/apps/disk_usage_app.dart`，287 行）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| C1 | `:137-139,211,263-275` | 条形/颜色按「最大兄弟」归一 -> 最大项恒红，哪怕占总量 2% | 条形 value 与颜色阈值改用 `ofTotal`（bytes/total）；保留「相对最大」仅作可选副可视化并标注（主方案 C1） |
| C2 | `:117-126` | 下钻每次开新窗，无返回/上级/面包屑 | **就地导航**：更新 `_path` 重载同窗；加面包屑（段可点跳祖先）+「上级」按钮（主方案 C2） |
| C3 | 全文 | 无联动到文件管理器/终端（file_manager 已单向开 disk_usage） | 条目右键/工具栏「在文件管理器打开」「在终端打开」（接 H） |
| C4 | `:128-286` | 无过滤 | `FilterField` |
| C5 | `:206-281` | 无排序（固定 bytes desc） | 排序切换：大小/名称/占总比 |
| C6 | `remote_disk_usage.dart:51,85` `:185` | 60 截断无提示；`du -x` 静默排除其它文件系统 | `length==60` 显「显示前 60 项」；`-x` 行为加提示「已排除其它文件系统」+ 重新扫描开关 |
| C7 | `:65-115` `remote_disk_usage.dart:84-86` | 大目录 `du` 无取消/超时，可卡数分钟 | `_loading` 时「取消」按钮中止流；服务端 `timeout` 包裹 |
| C8 | `remote_disk_usage.dart:39-43` `:88-92` | 路径正则过严（拒 `()`/`[]`/unicode），报「无法获取占用」误导 | 放宽（已有 `_shellSingleQuote` 安全引用）；或报「路径含不支持的字符」并指明字符 |
| C9 | `:95-102` | 标题仅叶名，丢全路径 | 标题用全路径（左省略）或含父级「占用 · log/nginx」 |
| C10 | `:189-196` `remote_disk_usage.dart:92` | 权限不足 vs 不存在同文案，无 sudo 重试 | 区分；权限错误给「以 sudo 重试」（`RemoteStateView.denied`） |

---

## 优先级（监控类内部）
1. C1 磁盘条形误导（正确性） 2. C2 下钻无返回（摩擦） 3. A3 kill 恒 SIGKILL（安全） 4. B2 OS 重复探测（性能） 5. A6/A7 进程/监听联动 6. C3 磁盘联动 7. A1/B1 暂停 8. A4 双击杀进程 9. A10 键盘 10. A8 复制 11. C7 取消扫描 12. A9 服务反馈 13. A2 上次更新 14. A15 断线重试 15. B3/B4 monitor 网络对齐 16. B5 联动提示 17. A13 网络刻度 18. C6 截断/跨文件系统 19. A11 800 截断 20. A5 进程详情 21. A12 Windows 列 22. A14 重连尖峰 23. A16 响应式 24. B6 截断 25. B7 `-` 卡墙 26. B8 去重 27. B9 GPU 趋势 28. C4/C5 过滤排序 29. C8 路径校验 30. C9 标题 31. C10 sudo 重试
