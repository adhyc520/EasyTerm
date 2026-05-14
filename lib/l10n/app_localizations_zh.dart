// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'Easy Term';

  @override
  String get appBarTitle => 'Easy Term';

  @override
  String get newConnection => '新建连接';

  @override
  String get settingsTooltip => '设置';

  @override
  String get menuInterfaceSettings => '界面与外观…';

  @override
  String get menuTerminalAndConnection => '终端与连接设置…';

  @override
  String get menuCloseAllSessions => '关闭全部会话';

  @override
  String get menuAbout => '关于 Easy Term';

  @override
  String get aboutDescription => '多会话 SSH 终端与 SFTP 文件浏览。';

  @override
  String get sidebarSavedHostsTooltip => '已保存主机';

  @override
  String get sidebarFilesTooltip => '文件';

  @override
  String get placeholderFileBrowserTitle => '文件浏览器';

  @override
  String get placeholderFileBrowserSubtitle => '连接主机后可浏览远程目录';

  @override
  String get placeholderTerminalTitle => '终端';

  @override
  String get placeholderTerminalSubtitle => '从侧栏「已保存」打开会话，或使用顶部「新建连接」';

  @override
  String get savedConnectionsHeader => '已保存连接';

  @override
  String get savedConnectionsEmpty => '暂无条目。使用顶部「新建连接」将自动加入此处。';

  @override
  String get contextOpenSession => '打开新会话';

  @override
  String get contextEdit => '修改…';

  @override
  String get contextDelete => '删除';

  @override
  String snackbarPrivateKeyReadFailed(String error) {
    return '无法读取私钥文件（路径可能来自其他系统或无效）：$error';
  }

  @override
  String get connectionEditTitle => '修改连接';

  @override
  String get connectionNewTitle => '新建主机';

  @override
  String get connectionDeviceNameLabel => '设备名称（可选）';

  @override
  String get connectionDeviceNameHint => '例如：公司 GPU 服务器';

  @override
  String get connectionHostLabel => '主机';

  @override
  String get connectionHostHint => 'IP 或域名';

  @override
  String get connectionPortLabel => '端口';

  @override
  String get connectionUserLabel => '用户名';

  @override
  String get connectionPasswordLabel => '密码 / 密钥口令';

  @override
  String get connectionPasswordHintEdit => '留空则保留已保存的口令';

  @override
  String get connectionKeyPathLabel => '私钥路径（可选）';

  @override
  String get connectionKeyPathHint => '桌面端可点右侧浏览';

  @override
  String get connectionPickKeyTooltip => '选择私钥文件';

  @override
  String get connectionSubmitConnect => '连接';

  @override
  String get connectionSubmitSave => '保存';

  @override
  String get connectionMissingHostUser => '请填写主机与用户名。';

  @override
  String savedHostConnectTitle(String label) {
    return '连接到「$label」';
  }

  @override
  String get savedHostKeyPassphraseHint => '已配置私钥路径，口令仅用于解密私钥（若私钥无加密可留空）。';

  @override
  String get savedHostPasswordFieldKey => '私钥口令 / SSH 密码';

  @override
  String get savedHostPasswordFieldPassword => 'SSH 密码';

  @override
  String get savedHostPasswordHelperKey => '无加密私钥且使用公钥登录时可留空';

  @override
  String get savedHostPasswordHelperPassword => '使用密钥登录时请先在「新建主机」里为该设备配置私钥路径';

  @override
  String get savedHostConnect => '连接';

  @override
  String get settingsDialogTitle => '终端与连接';

  @override
  String get settingsSectionConnection => '连接';

  @override
  String get settingsSectionTerminal => '终端';

  @override
  String get settingsSectionLanguage => '语言';

  @override
  String get settingsLanguageLabel => '界面语言';

  @override
  String get settingsLanguageChinese => '中文';

  @override
  String get settingsLanguageEnglish => 'English';

  @override
  String get settingsTimeoutLabel => '超时（秒）';

  @override
  String get settingsTimeoutHint => '5–600，默认 30';

  @override
  String get settingsRetryLabel => '重试次数';

  @override
  String get settingsRetryHint => '失败后的额外重试，0–20';

  @override
  String get settingsRetryIntervalLabel => '重试间隔（秒）';

  @override
  String get settingsRetryIntervalHint => '1–300';

  @override
  String get settingsKeepAliveLabel => 'Keep-alive（秒）';

  @override
  String get settingsKeepAliveHint => '0–3600，0 为关闭';

  @override
  String get settingsPtyColsLabel => 'PTY 列数';

  @override
  String get settingsPtyColsHint => '40–512，新连接生效';

  @override
  String get settingsPtyRowsLabel => 'PTY 行数';

  @override
  String get settingsPtyRowsHint => '8–256，新连接生效';

  @override
  String get settingsTermTypeLabel => '终端类型';

  @override
  String get settingsBufferLabel => '缓冲区大小';

  @override
  String get settingsBufferHint => '行数 100–100000，新连接生效';

  @override
  String get settingsFontSizeLabel => '字体大小';

  @override
  String get settingsFontSizeHint => '6–48';

  @override
  String get settingsFontFamilyLabel => '字体';

  @override
  String get settingsSelectCopyLabel => '选择复制';

  @override
  String get settingsSelectCopyDescription => '选中后自动复制到剪贴板（有短暂防抖）。';

  @override
  String get settingsRightClickPasteLabel => '右键粘贴';

  @override
  String get settingsRightClickPasteDescription => '在终端区域使用鼠标右键粘贴剪贴板文本';

  @override
  String get settingsInvalidNumbers => '请填写有效的数字（见各项取值范围）。';

  @override
  String get settingsCancel => '取消';

  @override
  String get settingsSave => '保存';

  @override
  String get terminalConnecting => '正在连接…';

  @override
  String get terminalConnectionFailed => '连接失败';

  @override
  String get terminalRetry => '重试';

  @override
  String get terminalWaiting => '等待连接…';

  @override
  String get sftpPanelTitle => '文件浏览器';

  @override
  String get sftpRefreshTooltip => '刷新';

  @override
  String get sftpColumnName => '名称';

  @override
  String get sftpColumnSize => '大小';

  @override
  String get sftpColumnModified => '修改时间';

  @override
  String get sftpBreadcrumbRoot => '根';

  @override
  String get sftpDownloadMenu => '下载到本地…';

  @override
  String get sftpDeleteMenu => '删除';

  @override
  String get sftpPickDirTitle => '选择保存位置（将创建同名子文件夹）';

  @override
  String get sftpSaveFileTitle => '保存远程文件';

  @override
  String sftpDownloadedDir(String name) {
    return '已下载目录 $name';
  }

  @override
  String sftpDownloadedFile(String name) {
    return '已下载 $name';
  }

  @override
  String sftpUploaded(String name) {
    return '已上传 $name';
  }

  @override
  String sftpUploadFailed(String error) {
    return '上传失败: $error';
  }

  @override
  String get sftpBinaryNotOpened => '该文件为二进制，已取消在编辑器中打开';

  @override
  String get sftpDeleteConfirmTitle => '删除确认';

  @override
  String sftpDeleteConfirmBody(String name) {
    return '确定删除「$name」？';
  }

  @override
  String get sftpDeleteConfirm => '删除';

  @override
  String get sftpCancel => '取消';

  @override
  String get remoteEditorSave => '保存';

  @override
  String get remoteEditorRemoteChanged => '服务器上的文件已被其他进程修改。';

  @override
  String get remoteEditorReload => '重新载入';

  @override
  String get remoteEditorIgnore => '忽略';

  @override
  String get remoteEditorSaved => '已保存并同步到服务器';

  @override
  String remoteEditorSaveFailed(String error) {
    return '保存失败: $error';
  }

  @override
  String get statusNotConnected => '未连接';

  @override
  String get statusNoRemoteInfo => '系统信息暂不可用';

  @override
  String get statusPickHost => '请选择左侧主机并连接';

  @override
  String get statusBeijingTimeLabel => '北京';

  @override
  String get statusRemoteUptimePrefix => '远端';

  @override
  String statusRemoteUptimeLine(String uptime) {
    return '远端：$uptime';
  }

  @override
  String get tooltipMemNoData => '内存使用率\n（暂无数据）';

  @override
  String tooltipMem(String percent) {
    return '内存使用率\n已用约 $percent%（相对 MemAvailable / MemTotal）';
  }

  @override
  String get tooltipCpuNoData => 'CPU 使用率\n（暂无数据，依赖 vmstat 采样）';

  @override
  String tooltipCpu(String percent) {
    return 'CPU 使用率\n约 $percent%（vmstat 1s 间隔采样）';
  }

  @override
  String get tooltipDiskTitle => '根挂载点 / 磁盘空间';

  @override
  String tooltipDiskUsed(String percent) {
    return '\n已用 $percent%';
  }

  @override
  String get tooltipDiskNoUsage => '\n使用率：暂无数据';

  @override
  String get tooltipInodeTitle => '根挂载点 / inode';

  @override
  String tooltipInodeUsed(String percent) {
    return '\n已用 $percent%';
  }

  @override
  String get tooltipInodeNoUsage => '\n使用率：暂无数据';

  @override
  String get tooltipLoadTitle => '系统负载';

  @override
  String tooltipLoadLine(String line) {
    return '\n1 / 5 / 15 分钟: $line';
  }

  @override
  String get tooltipLoadNoData => '\n（暂无 /proc/loadavg）';

  @override
  String tooltipLoadPressure(String percent) {
    return '\n相对 CPU 数折算压力: $percent%';
  }

  @override
  String get sshAuthFailKeyAndPassword =>
      '认证失败：私钥未被服务器接受，或私钥口令 / SSH 登录密码不正确，请逐项核对。';

  @override
  String get sshAuthFailKey => '认证失败：当前私钥与该账户不匹配，或私钥解密口令错误。';

  @override
  String get sshAuthFailPassword =>
      '认证失败：用户名或 SSH 密码不正确。若服务器仅允许密钥登录，请配置私钥并确认未填错密码。';

  @override
  String get sshAuthFailNone => '认证失败：未填写 SSH 密码，也未提供可用私钥。';

  @override
  String sshAuthAbort(String message) {
    return '认证中断：$message';
  }

  @override
  String sshKeyDecode(String message) {
    return '私钥无法解析或口令错误：$message';
  }

  @override
  String get interfaceSettingsTitle => '界面';

  @override
  String get interfaceThemeLabel => '外观';

  @override
  String get interfaceThemeDark => '深色';

  @override
  String get interfaceThemeLight => '浅色';

  @override
  String get interfaceThemeSystem => '跟随系统';

  @override
  String get interfaceDone => '完成';
}
