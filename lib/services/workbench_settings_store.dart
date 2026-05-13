import 'package:flutter/foundation.dart';
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
  static const _kRightPaste = 'wb_right_click_paste';

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

  bool rightClickPaste = false;

  static const List<String> terminalTypeChoices = [
    'xterm-256color',
    'xterm',
    'xterm-color',
    'vt100',
    'ansi',
  ];

  static const List<String> fontFamilyChoices = [
    'Courier New',
    'Menlo',
    'Monaco',
    'Consolas',
    'JetBrains Mono',
    'Roboto Mono',
    'SF Mono',
    'monospace',
  ];

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
    terminalFontSize = (p.getDouble(_kFontSize) ?? 14).clamp(6, 48);
    terminalFontFamily = p.getString(_kFontFamily) ?? 'Courier New';
    if (!fontFamilyChoices.contains(terminalFontFamily)) {
      terminalFontFamily = 'Courier New';
    }
    selectToCopy = p.getBool(_kSelectCopy) ?? false;
    rightClickPaste = p.getBool(_kRightPaste) ?? false;
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
    await p.setBool(_kRightPaste, rightClickPaste);
    notifyListeners();
  }
}
