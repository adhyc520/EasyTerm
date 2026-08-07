# 附件：管理类应用细节（Management Apps）

> containers / logs / packages / firewall / cron / users / forwards 全量发现（file:line + 修复）。对应主方案 §7。
> 跨应用共性（主方案 §0.2#2/3/4）：错误态不统一（-> `RemoteStateView`）、破坏性确认不一致（-> `confirmDestructiveAction`）、sudo 会话复用（-> 主方案 §2.4）、无内联重试。

---

## 安全护栏专项（跨管理类，主方案 §2.1）

| 应用 | 操作 | 位置 | 现状 | 改为 |
|---|---|---|---|---|
| firewall | allow | `:269-286` | 无确认 | 确认；端口==SSH 端口 -> 强警告 |
| firewall | deny | `:287-304` | 无确认，deny 22/tcp 断 SSH | **必确认 + SSH 强警告**；hint `257` 改 `80/tcp` |
| containers | stop | `:174-194,301-305` | 无确认 | 确认 |
| containers | restart | `:174-194,307-312` | 无确认 | 确认 |
| containers | 双击 | `:370-379` | 双击=restart | 双击=开日志/详情 |
| forwards | 删除 | `:186-193,354-359` | 无确认 + 永久取消持久化 | 确认 + 一步撤销（Snack） |
| cron | 整表替换 | `:91-111` | 无备份 | 一步备份撤销 |
| task_manager | kill | `:465-522,514` | 确认但恒 SIGKILL | 确认框 SIGTERM/SIGKILL 两按钮 |
| packages | 卸载 | `:177-197` | 已确认 | dry-run 列受影响依赖 |

---

## C. Containers（`containers_app.dart`，617 行）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| C1 | `:174-194,301-312` | stop/restart 无确认 | 见安全专项 |
| C2 | `:370-379` | 双击静默 restart | 双击开日志/详情 |
| C3 | `:186-192` | 错误靠输出含 "error" 字符串判定，漏判 | 服务追加 `__EC:$?` + `interpretExit`；总显错误 |
| C4 | `:314-327` | 仅->logs 一条联动；无 exec/inspect/删除 | 加 exec（terminal `docker exec -it <name> sh`）、inspect 详情、删除 |
| C5 | `:90,79` | 5s 刷新无法暂停（仅最小化） | `PauseToggle`；保选区跨刷新 |
| C6 | `:127-130,477-519` | 容器消失选区清空，详情区无声消失 | 详情区短暂显「容器已不存在」 |

---

## L. Logs（`logs_app.dart`，632 行）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| L1 | `:269,196,151` | 行数硬编码 300；live 缓冲 5000 与快照不一致 | 行数选择器 100/300/1000/2000（service 钳 20-2000 `remote_logs.dart:83`）；live/snapshot 统一传 |
| L2 | `remote_logs.dart:81,96-105,227-234` `:298-305` | service 有 `priority` 但 UI 未接 | 级别下拉（emerg/err/warning/info/debug）journal 源 |
| L3 | `remote_logs.dart:332-346` `:586` | 时间戳已解析但 UI 整行渲染 | 时间戳暗色等宽列 + 消息分列 |
| L4 | `:603-619` | 复制仅过滤后行 | 「导出」全量（pre-filter）入剪贴板/文件 |
| L5 | 全文 | 无换行开关/清空/跳时间 | 换行 toggle + 清空按钮 + 时间跳转 |
| L6 | `:132-137,545-555` | 上滚时流仍追加至 5000 上限，噪声 | 可选「上滚暂停跟随」（区别于暂停刷新） |
| L7 | `:526-533,413` | 错误仅文本，刷新断线时禁用 | 内联「重试」 |

---

## P. Packages（`packages_app.dart`，543 行）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| P1 | 全文 | 无升级/update-all | 「升级」跑 manager upgrade（同 op-log 对话框） |
| P2 | `:495-531` | 搜索结果不标已安装 | 交叉 `_installed` 显徽标 + 禁用安装 |
| P3 | `remote_packages.dart:210-226` `:294` | 已装列表截断 400 无提示 | `length==400` 显「已截断（仅前 400）」 |
| P4 | 全文 | 无包详情/文件列表 | 详情抽屉 `dpkg -L`/`rpm -ql` + 跳文件管理器（接 H） |
| P5 | `:177-197` | 卸载确认不警告连带删除 | `apt -s` dry-run 列受影响依赖 |
| P6 | 全文 | 仅装最新，无版本选择 | 版本输入（支持的 manager） |
| P7 | `:311-319` | 失败提示的终端命令恒 `install:true` | 传实际 install 标志 |

---

## F. Firewall（`firewall_app.dart`，423 行）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| F1 | `:269-304,94,257` | allow/deny 无确认，可断 SSH（hint 即 22） | 见安全专项（最高优先） |
| F2 | `:217` | 非 UFW 后端按钮静默消失无说明 | 显「此后端暂不支持可视化编辑」+ 可复制命令 |
| F3 | 全文 | 无常用预设 | 预设菜单（SSH/HTTP/HTTPS） |
| F4 | `:400-418` | 仅增/删，改规则要删后重加 | 「编辑」预填端口 |
| F5 | `remote_firewall.dart:168-181` | firewalld zone/service 无管理/reload | 暴露 service/reload |
| F6 | `:257` | hint 是 SSH 端口紧邻 deny | 改 `80/tcp` |

---

## CR. Cron（`cron_app.dart`，261 行）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| CR1 | `:91-111` | 保存前无语法校验 | `parseCrontab` 校验；<6 字段非注释/特殊行告警 |
| CR2 | `remote_cron.dart:100-117` `:91-111` | 整表替换无备份 | 一步内存备份 + 「撤销上一次」（主方案 §2.3） |
| CR3 | `:219-256` | 无「立即运行」 | 跑任务命令于 terminal（接 H） |
| CR4 | `:233-254,215` | 无启用/禁用/语法帮助/下次运行预览 | 注释切换、语法参考浮层、计算下次运行 |
| CR5 | 全文 | 假定 crond 运行 | 头部 `systemctl is-active cron` |
| CR6 | `:195-218` | 编辑器裸 TextField | 行号 + 畸形行高亮 |

---

## U. Users（`users_app.dart`，298 行）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| U1 | `:270-293` | 全只读，无增删/锁定/改密 | 写操作（sudo 已就绪） |
| U2 | `remote_users.dart:31-49` `:285` | 仅 uid 无组名/成员 | 取 `/etc/group` 显主组 + 成员 |
| U3 | `:171-197` | 在线会话无踢出 | `pkill`/注销动作 |
| U4 | `remote_users.dart:174` | 仅成功登录，无失败 | `lastb`/auth.log 失败登录 |
| U5 | `remote_users.dart:48` `:256-261` | 系统 uid<1000 硬编码 | 读 `login.defs` `UID_MIN` 或可配 |

---

## FW. Forwards（`forwards_app.dart`，376 行）

| ID | 位置 | 问题 | 修复 |
|---|---|---|---|
| FW1 | `:186-193,354-359` | 删除无确认 + 永久 | 见安全专项 + 撤销 |
| FW2 | `:131-161,159` | 无本地端口冲突检测，失败信息晦涩 | 预检端口，冲突建议下一空闲 |
| FW3 | `:318-363` | 仅启停/删，改端口要删后重加 | 「编辑」 |
| FW4 | 全文 | 无开浏览器/复制 URL | 复制 URL + web 端口「开浏览器」（接 H） |
| FW5 | `:320-329` | 状态点仅 socket 绑定，远端死服务仍绿 | 轻量探测/字节计数 |
| FW6 | `:70-114` | 持久转发静默自启 | 「已恢复 N 个转发」toast |
| FW7 | `:340,346-353` | 转发中断无自动重连 | 可选自动重启 |

---

## 优先级（管理类内部）
1. F1 防火墙 allow/deny 无确认（关键） 2. C1/C2 容器 stop/restart/双击无确认 3. FW1 转发删除无确认 4. CR2 cron 无备份 5. C3 容器错误靠字符串匹配 6. L1/L2 日志 300 硬编码/级别 UI 缺 7. P1 无升级 8. P3 400 截断 9. CR1 cron 无校验 10. F2 非 UFW 静默只读 11. U1 用户全只读 12. P2 搜索不标已装 13. sudo 复用（主方案 §2.4） 14. L3/L4 时间戳/导出 15. FW2 端口冲突 16. C5 容器暂停 17. CR3/CR4 cron 立即运行/启用/帮助 18. 内联重试（跨应用） 19. F3/F4 预设/编辑 20. U2/U4 组/失败登录 21. FW4/FW5 开浏览器/健康 22. 联动（主方案 §9）
