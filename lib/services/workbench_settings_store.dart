import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局终端与连接偏好（持久化到 SharedPreferences）。
final class WorkbenchSettingsStore extends ChangeNotifier {
  WorkbenchSettingsStore();

  static const _kTimeoutSec = 'wb_connect_timeout_sec';
  static const _kRetryCount = 'wb_connect_retry_count';
  static const _kRetryIntervalSec = 'wb_retry_interval_sec';
  static const _kKeepAliveSec = 'wb_ssh_keepalive_sec';
  static const _kPtyColumns = 'wb_pty_columns';
  static const _kPtyRows = 'wb_pty_rows';
  static const _kTermType = 'wb_terminal_type';
  static const _kBufferLines = 'wb_buffer_lines';
  static const _kFontSize = 'wb_font_size';
  static const _kFontFamily = 'wb_font_family';
  static const _kSelectCopy = 'wb_select_copy';
  static const _kAppLocale = 'wb_app_locale';
  static const _kThemeMode = 'wb_theme_mode';
  static const _kLlmBaseUrl = 'wb_llm_base_url';
  static const _kLlmModel = 'wb_llm_model';
  static const _kLlmApiKey = 'wb_llm_api_key';
  static const _kAssistantCollapsed = 'wb_assistant_collapsed';
  static const _kAssistantWidth = 'wb_assistant_width';
  static const _kUiScale = 'wb_ui_scale';
  static const _kFollowTerminalCwd = 'wb_follow_terminal_cwd';
  static const _kInjectOsc7 = 'wb_inject_osc7';
  static const _kSmartRightClick = 'wb_smart_right_click';

  /// 界面语言：`zh` 或 `en`，默认中文。
  String appLocaleCode = 'zh';

  /// 外观：`dark` | `light` | `system`（跟随系统）。
  String appThemeMode = 'dark';

  /// 与 [MaterialApp.themeMode] 对应。
  ThemeMode get materialThemeMode {
    switch (appThemeMode) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      case 'dark':
      default:
        return ThemeMode.dark;
    }
  }

  /// SSH 套接字连接超时（秒），与界面标签一致。
  int connectTimeoutSec = 30;

  /// 失败后的额外重试次数（不含首次），例如 3 表示最多共尝试 4 次。
  int connectRetryCount = 3;

  /// 两次尝试之间的等待（秒）。
  int retryIntervalSec = 5;

  /// SSH keep-alive 发包间隔（秒）。为 0 时关闭 keep-alive（对应 [SSHClient] 的 `null`）。
  int sshKeepAliveSec = 30;

  /// 新建 shell 时 PTY 默认列数（新连接生效）。
  int ptyDefaultColumns = 120;

  /// 新建 shell 时 PTY 默认行数（新连接生效）。
  int ptyDefaultRows = 32;

  String terminalTermType = 'xterm-256color';

  /// 终端回滚缓冲行数（较大值占用更多内存）。
  int terminalMaxLines = 1000;

  double terminalFontSize = 14;

  String terminalFontFamily = 'Courier New';

  bool selectToCopy = false;

  /// Assign UI scale and notify listeners (for live slider preview).
  void setUiScaleFactor(double value) {
    final next = value.clamp(0.75, 2.0);
    if (uiScaleFactor == next) return;
    uiScaleFactor = next;
    notifyListeners();
  }

  /// 全局 UI 缩放（0.75–2.0），经 textScaler + 终端字号联动。
  double uiScaleFactor = 1.0;

  /// 终端 `cd` 后自动同步 SFTP 浏览器目录。
  bool followTerminalCwd = false;

  /// 连接后注入 bash/zsh OSC 7 片段（默认关）。
  bool injectOsc7Cwd = false;

  /// Windows 风格：有选区右键=复制并清选区；无选区右键=粘贴。
  bool smartRightClick = false;

  /// OpenAI 兼容 Chat Completions 的基础地址（通常以 `/v1` 结尾，也可直接填完整 `.../chat/completions` URL）。
  String llmBaseUrl = 'https://api.openai.com/v1';

  /// 模型 id，例如 `gpt-4o-mini`。
  String llmModel = 'gpt-4o-mini';

  /// API Key（仅存于本机 SharedPreferences）。
  String llmApiKey = '';

  /// 右侧助手栏是否收起为窄条。
  bool assistantPanelCollapsed = true;

  /// 展开时助手栏宽度。
  double assistantPanelWidth = 320;

  static const List<String> terminalTypeChoices = [
    'xterm-256color',
    'xterm',
    'xterm-color',
    'vt100',
    'ansi',
  ];

  static const List<String> _allFontFamilies = [
    'Courier New',
    'Menlo',
    'Monaco',
    'Consolas',
    'JetBrains Mono',
    'Roboto Mono',
    'SF Mono',
    'monospace',
  ];

  /// Platform-filtered font list for settings UI.
  static List<String> get fontFamilyChoices {
    if (kIsWeb) return List<String>.from(_allFontFamilies);
    if (Platform.isWindows) {
      return const [
        'Consolas',
        'Courier New',
        'JetBrains Mono',
        'Roboto Mono',
        'monospace',
      ];
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return const [
        'Menlo',
        'Monaco',
        'SF Mono',
        'Courier New',
        'JetBrains Mono',
        'Roboto Mono',
        'monospace',
      ];
    }
    return List<String>.from(_allFontFamilies);
  }

  /// Default monospace for [TerminalSurface] when no setting is passed.
  static String get platformDefaultFontFamily {
    if (!kIsWeb && Platform.isWindows) return 'Consolas';
    if (!kIsWeb && (Platform.isMacOS || Platform.isIOS)) return 'Menlo';
    return 'Courier New';
  }

  static double defaultUiScaleForDpr(double dpr) {
    if (dpr >= 2.0) return 1.1;
    return 1.0;
  }

  static double defaultFontSizeForDpr(double dpr) {
    if (dpr >= 2.0) return 16;
    return 14;
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    connectTimeoutSec = (p.getInt(_kTimeoutSec) ?? 30).clamp(5, 600);
    connectRetryCount = (p.getInt(_kRetryCount) ?? 3).clamp(0, 20);
    retryIntervalSec = (p.getInt(_kRetryIntervalSec) ?? 5).clamp(1, 300);
    sshKeepAliveSec = (p.getInt(_kKeepAliveSec) ?? 30).clamp(0, 3600);
    ptyDefaultColumns = (p.getInt(_kPtyColumns) ?? 120).clamp(40, 512);
    ptyDefaultRows = (p.getInt(_kPtyRows) ?? 32).clamp(8, 256);
    terminalTermType = p.getString(_kTermType) ?? 'xterm-256color';
    if (!terminalTypeChoices.contains(terminalTermType)) {
      terminalTermType = 'xterm-256color';
    }
    terminalMaxLines = (p.getInt(_kBufferLines) ?? 1000).clamp(100, 100000);

    double dpr = 1.0;
    try {
      dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    } catch (_) {}

    if (p.containsKey(_kFontSize)) {
      terminalFontSize = (p.getDouble(_kFontSize) ?? 14).clamp(6, 48);
    } else {
      terminalFontSize = defaultFontSizeForDpr(dpr);
    }

    terminalFontFamily =
        p.getString(_kFontFamily) ?? platformDefaultFontFamily;
    if (!fontFamilyChoices.contains(terminalFontFamily) &&
        !_allFontFamilies.contains(terminalFontFamily)) {
      terminalFontFamily = platformDefaultFontFamily;
    }

    if (p.containsKey(_kSelectCopy)) {
      selectToCopy = p.getBool(_kSelectCopy) ?? false;
    } else {
      // Windows newcomers expect select-to-copy (PuTTY / Windows Terminal).
      selectToCopy = !kIsWeb && Platform.isWindows;
    }

    if (p.containsKey(_kUiScale)) {
      uiScaleFactor = (p.getDouble(_kUiScale) ?? 1.0).clamp(0.75, 2.0);
    } else {
      uiScaleFactor = defaultUiScaleForDpr(dpr);
    }

    followTerminalCwd = p.getBool(_kFollowTerminalCwd) ?? false;
    injectOsc7Cwd = p.getBool(_kInjectOsc7) ?? false;
    if (p.containsKey(_kSmartRightClick)) {
      smartRightClick = p.getBool(_kSmartRightClick) ?? false;
    } else {
      smartRightClick = !kIsWeb && Platform.isWindows;
    }

    appLocaleCode = p.getString(_kAppLocale) ?? 'zh';
    if (appLocaleCode != 'en' && appLocaleCode != 'zh') {
      appLocaleCode = 'zh';
    }
    appThemeMode = p.getString(_kThemeMode) ?? 'dark';
    if (appThemeMode != 'dark' &&
        appThemeMode != 'light' &&
        appThemeMode != 'system') {
      appThemeMode = 'dark';
    }
    llmBaseUrl = (p.getString(_kLlmBaseUrl) ?? llmBaseUrl).trim();
    if (llmBaseUrl.isEmpty) llmBaseUrl = 'https://api.openai.com/v1';
    llmModel = (p.getString(_kLlmModel) ?? llmModel).trim();
    if (llmModel.isEmpty) llmModel = 'gpt-4o-mini';
    llmApiKey = p.getString(_kLlmApiKey) ?? '';
    assistantPanelCollapsed = p.getBool(_kAssistantCollapsed) ?? true;
    assistantPanelWidth = (p.getDouble(_kAssistantWidth) ?? 320).clamp(
      240,
      560,
    );
    notifyListeners();
  }

  Future<void> persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kTimeoutSec, connectTimeoutSec);
    await p.setInt(_kRetryCount, connectRetryCount);
    await p.setInt(_kRetryIntervalSec, retryIntervalSec);
    await p.setInt(_kKeepAliveSec, sshKeepAliveSec);
    await p.setInt(_kPtyColumns, ptyDefaultColumns);
    await p.setInt(_kPtyRows, ptyDefaultRows);
    await p.setString(_kTermType, terminalTermType);
    await p.setInt(_kBufferLines, terminalMaxLines);
    await p.setDouble(_kFontSize, terminalFontSize);
    await p.setString(_kFontFamily, terminalFontFamily);
    await p.setBool(_kSelectCopy, selectToCopy);
    await p.setDouble(_kUiScale, uiScaleFactor);
    await p.setBool(_kFollowTerminalCwd, followTerminalCwd);
    await p.setBool(_kInjectOsc7, injectOsc7Cwd);
    await p.setBool(_kSmartRightClick, smartRightClick);
    await p.setString(_kAppLocale, appLocaleCode);
    await p.setString(_kThemeMode, appThemeMode);
    await p.setString(_kLlmBaseUrl, llmBaseUrl);
    await p.setString(_kLlmModel, llmModel);
    await p.setString(_kLlmApiKey, llmApiKey);
    await p.setBool(_kAssistantCollapsed, assistantPanelCollapsed);
    await p.setDouble(_kAssistantWidth, assistantPanelWidth);
    notifyListeners();
  }
}
