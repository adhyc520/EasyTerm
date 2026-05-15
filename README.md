# Easy Term

**Easy Term** is a Flutter desktop SSH client: a multi-tab terminal with an integrated SFTP file browser, saved connections, optional AI assistant (OpenAI-compatible Chat API) with guarded terminal actions, and a status bar that surfaces remote health hints (uptime, load, and more on supported Linux hosts).

**Easy Term** 是一款基于 Flutter 的桌面端 SSH 客户端：支持多标签终端、内置 SFTP 文件浏览（含远程文本编辑）、已保存连接、可选的 AI 助手（OpenAI 兼容对话接口，终端操作建议需用户确认），以及可在状态栏查看远端运行概况（运行时间、负载等，在支持的 Linux 主机上信息更丰富）。

<p align="center">
  <img src="images/home.png" alt="Easy Term main window — terminal with SFTP sidebar and status bar" width="920" />
</p>

---

## English

### Highlights

- **SSH sessions in tabs** — Open several `user@host` sessions in one window; each tab owns its own connection and resources.
- **Integrated SFTP file browser** — After you connect, browse remote paths with name, size, and modification time; switch between “Saved hosts” and “Files” in the left sidebar; open supported text files in a simple remote editor with save and change detection.
- **Flexible authentication** — Password, optional PEM private key (with passphrase when needed), plus handling for setups where keyboard-interactive is required.
- **Saved connections** — Store hosts, ports, users, optional device labels, and key paths; connect or edit from the sidebar.
- **AI assistant (optional)** — Right-side panel talks to an **OpenAI Chat Completions–compatible** endpoint (configurable base URL, model, and API key stored only on this machine). Streaming replies; optional **terminal tool** that proposes shell input—**each execution is confirmed in a dialog** before anything is sent to the PTY.
- **Workbench settings** — Grouped dialogs for **Terminal** (timeouts/retries, SSH keep-alive, PTY size and `TERM`, scrollback, font size and family, select-to-copy), **Interface** (English / 中文, light / dark / system theme, assistant panel width), and **LLM** (base URL, model, API key).
- **Status bar** — Local and remote clock, plus remote snippets such as uptime and load average where the shell snapshot can read them (e.g. typical Linux environments).

### Requirements

- [Flutter](https://docs.flutter.dev/get-started/install) SDK compatible with this project (`environment.sdk` in `pubspec.yaml`).
- **Windows** or **macOS** desktop tooling enabled in your Flutter installation (`flutter doctor`).

### Run from source

```bash
flutter pub get
flutter gen-l10n   # if localization outputs are not already generated
flutter run -d windows
# or
flutter run -d macos
```

Release builds follow the usual Flutter desktop flow, for example:

```bash
flutter build windows
flutter build macos
```

### Tech stack

| Area | Packages / notes |
|------|-------------------|
| SSH / SFTP | [`dartssh2`](https://pub.dev/packages/dartssh2) |
| Terminal UI | [`xterm`](https://pub.dev/packages/xterm) |
| Desktop window | [`window_manager`](https://pub.dev/packages/window_manager) |
| Settings | [`shared_preferences`](https://pub.dev/packages/shared_preferences) |
| Key file pick | [`file_picker`](https://pub.dev/packages/file_picker) |
| LLM HTTP | [`http`](https://pub.dev/packages/http) (OpenAI-compatible chat + streaming) |

This repo vendors a small [`desktop_drop`](https://pub.dev/packages/desktop_drop) override under `packages/desktop_drop` for reliable drag-and-drop on Windows (see `pubspec.yaml` `dependency_overrides`).

---

## 中文

### 功能概览

- **多标签 SSH** — 在同一窗口管理多个 `用户名@主机` 会话；每个标签独立连接与资源。
- **内置 SFTP 文件管理** — 连接后可浏览远端目录，展示名称、大小、修改时间；左侧可在「已保存主机」与「文件」视图间切换；可对合适类型的文本文件进行简单的远程编辑、保存与变更提示。
- **多种登录方式** — 支持密码、可选 PEM 私钥（及密钥口令），并兼顾部分仅开启 keyboard-interactive 的服务端场景。
- **已保存连接** — 保存主机、端口、用户名、可选设备备注与私钥路径；在侧栏快速连接或编辑。
- **AI 助手（可选）** — 右侧助手面板通过 **OpenAI Chat Completions 兼容接口**对话（可配置基础地址、模型；**API Key 仅保存在本机**）。支持流式回复；可选 **终端工具** 由模型建议向当前 PTY 注入命令——**每次执行前均需用户在弹窗中确认**。
- **工作台设置** — 分为 **终端**（连接超时与重试、SSH keep-alive、PTY 行列与终端类型、滚动缓冲、字号与字体、选中复制）、**界面**（**English / 中文**、浅色 / 深色 / 跟随系统、助手栏宽度等）与 **LLM**（基础 URL、模型、密钥）等对话框。
- **底部状态栏** — 本地与远端时间；在可获取远端输出的环境下展示运行时间、负载等信息（常见于 Linux 远端）。

### 环境要求

- 已安装与本项目 `pubspec.yaml` 中 `environment.sdk` 匹配的 [Flutter](https://docs.flutter.dev/get-started/install)。
- Flutter 已启用 **Windows** 或 **macOS** 桌面支持（可用 `flutter doctor` 自检）。

### 从源码运行

```bash
flutter pub get
flutter gen-l10n   # 若本地化代码尚未生成
flutter run -d windows
# 或
flutter run -d macos
```

发布构建可使用例如：

```bash
flutter build windows
flutter build macos
```

### 技术栈说明

| 模块 | 说明 |
|------|------|
| SSH / SFTP | [`dartssh2`](https://pub.dev/packages/dartssh2) |
| 终端界面 | [`xterm`](https://pub.dev/packages/xterm) |
| 桌面窗口 | [`window_manager`](https://pub.dev/packages/window_manager) |
| 配置持久化 | [`shared_preferences`](https://pub.dev/packages/shared_preferences) |
| 私钥文件选择 | [`file_picker`](https://pub.dev/packages/file_picker) |
| 助手网络请求 | [`http`](https://pub.dev/packages/http)（兼容 OpenAI 的对话与流式响应） |

仓库在 `packages/desktop_drop` 中带有 `desktop_drop` 的本地覆盖，用于改善 Windows 下拖放行为（见根目录 `pubspec.yaml` 的 `dependency_overrides`）。

---

### Repository note

The Flutter package name in `pubspec.yaml` is `terminall`; the product name shown in the app and localization files is **Easy Term**.

Flutter 工程在 `pubspec.yaml` 里的包名为 `terminall`，应用界面与文案中的产品名为 **Easy Term**。
