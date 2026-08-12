// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'EasyTerm';

  @override
  String get appBarTitle => 'EasyTerm';

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
  String get menuAbout => '关于 EasyTerm';

  @override
  String aboutCurrentVersion(String version) {
    return '版本 $version';
  }

  @override
  String get menuQuit => '退出 EasyTerm';

  @override
  String get menuFile => '文件';

  @override
  String get menuCloseTab => '关闭标签页';

  @override
  String get menuTabCloseLeft => '关闭左侧标签';

  @override
  String get menuTabCloseRight => '关闭右侧标签';

  @override
  String get menuTabCloseOthers => '关闭其他标签';

  @override
  String get menuTabCloseAll => '关闭全部标签';

  @override
  String get menuTabDuplicate => '复制当前窗口';

  @override
  String get menuTabToggleDesktop => '切换桌面/终端';

  @override
  String get menuTabToggleDesktopToDesktop => '切换到桌面模式';

  @override
  String get menuTabToggleDesktopToTerminal => '切换到终端模式';

  @override
  String get desktopSidebarOpenFiles => '打开文件管理器';

  @override
  String get desktopSidebarExpandHosts => '展开已保存主机';

  @override
  String get menuSplitRight => '向右分屏';

  @override
  String get menuSplitLeft => '向左分屏';

  @override
  String get menuSplitDown => '向下分屏';

  @override
  String get menuSplitUp => '向上分屏';

  @override
  String get menuView => '视图';

  @override
  String get menuCodeSnippets => '代码块';

  @override
  String get menuHealthBoard => '健康看板';

  @override
  String get paneMenuTooltip => '窗格操作';

  @override
  String get paneSplitRight => '向右分屏';

  @override
  String get paneSplitLeft => '向左分屏';

  @override
  String get paneSplitDown => '向下分屏';

  @override
  String get paneSplitUp => '向上分屏';

  @override
  String get paneClose => '关闭窗格';

  @override
  String get codeSnippetsTitle => '代码块';

  @override
  String get codeSnippetsEmpty => '还没有代码块。点「新建」创建可复用的命令或脚本。';

  @override
  String get codeSnippetNew => '新建';

  @override
  String get codeSnippetEdit => '编辑';

  @override
  String get codeSnippetDelete => '删除';

  @override
  String get codeSnippetRun => '运行';

  @override
  String get codeSnippetNameLabel => '名称';

  @override
  String get codeSnippetNameHint => '例如：重启服务';

  @override
  String get codeSnippetBodyLabel => '内容';

  @override
  String get codeSnippetBodyHint => '将写入所选终端的命令或脚本';

  @override
  String get codeSnippetSave => '保存';

  @override
  String get codeSnippetCancel => '取消';

  @override
  String codeSnippetDeleteConfirm(String name) {
    return '确定删除「$name」？';
  }

  @override
  String get codeSnippetNeedSession => '请先打开并连接一个终端会话。';

  @override
  String get codeSnippetRan => '已发送到终端';

  @override
  String get codeSnippetClickTargetHint => '点击要运行的终端窗口（可先切换标签）';

  @override
  String get codeSnippetClickToRun => '点击运行';

  @override
  String get healthBoardTitle => '健康看板';

  @override
  String get healthBoardSessions => '会话';

  @override
  String get healthBoardActive => '活跃连接';

  @override
  String get healthBoardConnecting => '连接中';

  @override
  String get healthBoardErrors => '异常';

  @override
  String get healthBoardPanes => '终端窗格';

  @override
  String get healthBoardCpu => 'CPU';

  @override
  String get healthBoardMemory => '内存';

  @override
  String get healthBoardDisk => '磁盘';

  @override
  String get healthBoardLoad => '负载';

  @override
  String get healthBoardFetching => '正在拉取远端指标…';

  @override
  String get healthBoardMetricsUnavailable =>
      '暂无法获取远端指标（需 Linux /proc 或 Windows CIM）';

  @override
  String get healthBoardNoSessions => '暂无会话。新建连接后可在此查看服务器状态。';

  @override
  String get healthBoardNoConnected => '没有已连接的主机。连接后可查看远端 CPU、内存、磁盘与负载。';

  @override
  String get healthBoardSessionStatus => '连接状态';

  @override
  String get healthBoardRefresh => '刷新';

  @override
  String get healthBoardConnected => '已连接';

  @override
  String get healthBoardDisconnected => '未连接';

  @override
  String get healthBoardHost => '远端主机';

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
  String get connectionAuthMethodLabel => '认证方式';

  @override
  String get connectionAuthPassword => '密码';

  @override
  String get connectionAuthPrivateKey => '私钥';

  @override
  String get connectionSshPasswordLabel => 'SSH 密码';

  @override
  String get connectionSshPasswordHintEdit => '留空则保留已保存的密码';

  @override
  String get connectionKeyPassphraseLabel => '私钥口令（可选）';

  @override
  String get connectionKeyPassphraseHintEdit => '留空则保留已保存的私钥口令';

  @override
  String get connectionPasswordHintEdit => '留空则保留已保存的口令';

  @override
  String get connectionKeyPathLabel => '私钥文件';

  @override
  String get connectionKeyPathHint => '桌面端可点右侧浏览';

  @override
  String get connectionMissingKeyPath => '请选择私钥文件。';

  @override
  String get connectionPrivateKeyEmpty => '私钥文件为空或不是有效的 PEM 文本。';

  @override
  String get connectionPickKeyTooltip => '选择私钥文件';

  @override
  String connectionPickKeyFailed(String error) {
    return '无法选择私钥文件：$error';
  }

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
  String get settingsFollowTerminalCwdLabel => '跟随终端目录';

  @override
  String get settingsFollowTerminalCwdDescription =>
      '终端 cd 后自动同步文件浏览器；会自动向 bash/zsh 注入目录上报。';

  @override
  String get settingsInjectOsc7Label => '启用目录上报';

  @override
  String get settingsInjectOsc7Description =>
      '连接后向 bash/zsh 注入 OSC 7（开启「跟随终端目录」时也会自动注入）。';

  @override
  String get settingsSmartRightClickLabel => '右键智能复制/粘贴';

  @override
  String get settingsSmartRightClickDescription =>
      '有选区时右键复制并清除；无选区时右键粘贴（Windows 终端习惯）。';

  @override
  String get settingsUiScaleLabel => '界面缩放';

  @override
  String get settingsUiScaleDescription => '放大或缩小界面文字与终端字号（0.75–2.0）。';

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
  String get terminalDisconnected => '连接已断开';

  @override
  String get terminalReconnect => '重新连接';

  @override
  String get terminalReconnecting => '正在重新连接…';

  @override
  String get terminalMenuCopy => '复制';

  @override
  String get terminalMenuPaste => '粘贴';

  @override
  String get terminalMenuSelectAll => '全选';

  @override
  String get terminalMenuClearSelection => '清除选择';

  @override
  String get sftpPanelTitle => '文件浏览器';

  @override
  String get sftpRefreshTooltip => '刷新';

  @override
  String get sftpViewListTooltip => '列表视图';

  @override
  String get sftpViewGridTooltip => '图标视图';

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
  String get sftpOpenInEditorMenu => '在编辑器中打开…';

  @override
  String get sftpOpenTerminalMenu => '打开终端';

  @override
  String get sftpAnalyzeDiskUsageMenu => '分析磁盘占用…';

  @override
  String get sftpRenameMenu => '重命名';

  @override
  String get sftpNewFolderMenu => '新建文件夹';

  @override
  String get sftpNewFolderTooltip => '新建文件夹';

  @override
  String get sftpNewFileMenu => '新建文件';

  @override
  String get sftpNewFileTooltip => '新建文件';

  @override
  String get sftpUploadFilesMenu => '上传文件…';

  @override
  String get sftpUploadFolderMenu => '上传文件夹…';

  @override
  String get sftpNewFolderTitle => '新建文件夹';

  @override
  String get sftpNewFolderHint => '文件夹名称';

  @override
  String get sftpNewFileTitle => '新建文件';

  @override
  String get sftpNewFileHint => '文件名称';

  @override
  String get sftpRenameTitle => '重命名';

  @override
  String get sftpNameFieldLabel => '名称';

  @override
  String get sftpCreate => '创建';

  @override
  String get sftpRenameConfirm => '重命名';

  @override
  String get sftpInvalidName => '请输入有效名称（不能包含路径分隔符）。';

  @override
  String sftpCreatedFolder(String name) {
    return '已创建文件夹 $name';
  }

  @override
  String sftpCreatedFile(String name) {
    return '已创建文件 $name';
  }

  @override
  String sftpRenamed(String name) {
    return '已重命名为 $name';
  }

  @override
  String get sftpCopyMenu => '复制';

  @override
  String get sftpCutMenu => '剪切';

  @override
  String get sftpPasteMenu => '粘贴';

  @override
  String sftpCopied(int count) {
    return '已复制 $count 项';
  }

  @override
  String sftpCutToast(int count) {
    return '已剪切 $count 项';
  }

  @override
  String sftpPasted(int count) {
    return '已粘贴 $count 项';
  }

  @override
  String get sftpClipboardEmpty => '剪贴板为空';

  @override
  String get sftpOk => '确定';

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
  String sftpTransferQueueProgress(int done, int total) {
    return '已完成 $done / $total 项';
  }

  @override
  String get sftpTransferKindUploadTooltip => '上传';

  @override
  String get sftpTransferKindDownloadTooltip => '下载';

  @override
  String get sftpUploadQueueExpand => '展开全部';

  @override
  String get sftpUploadQueueCollapse => '收起';

  @override
  String get sftpUploadRowPending => '排队中';

  @override
  String get sftpUploadCancelFileTooltip => '取消上传此文件';

  @override
  String get sftpUploadCancelAllTooltip => '全部取消';

  @override
  String get sftpUploadOverwriteTitle => '覆盖服务器上的同名项？';

  @override
  String sftpUploadOverwriteBody(String name) {
    return '服务器当前目录下已存在「$name」。覆盖将删除远端该项后重新上传，是否继续？';
  }

  @override
  String get sftpUploadOverwriteConfirm => '覆盖';

  @override
  String get sftpUploadConflictTypeMismatchTitle => '无法覆盖';

  @override
  String sftpUploadConflictTypeMismatchBody(String name) {
    return '「$name」与服务器上的类型不一致（文件 / 文件夹）。请先在服务器上删除该项后再上传。';
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
  String sftpDeleteConfirmBodyMultiple(int count) {
    return '确定删除选中的 $count 项？';
  }

  @override
  String sftpDownloadedMultiple(int count) {
    return '已下载 $count 项';
  }

  @override
  String sftpSelectionCount(int count) {
    return '已选 $count 项';
  }

  @override
  String get sftpPickDownloadDirTitle => '选择下载保存文件夹';

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
  String remoteEditorSyntaxError(String detail) {
    return '语法错误：$detail';
  }

  @override
  String get sshAuthFailKeyAndPassword =>
      '认证失败：私钥未被服务器接受，或私钥口令 / SSH 登录密码不正确，请逐项核对。';

  @override
  String get sshAuthFailKey => '认证失败：当前私钥与该账户不匹配，或私钥解密口令错误。';

  @override
  String get sshAuthFailPassword =>
      '未能连接：用户名或 SSH 密码不正确（认证失败）。若服务器仅允许密钥登录，请配置私钥并确认未填错密码。';

  @override
  String get sshAuthFailNone => '认证失败：未填写 SSH 密码，也未提供可用私钥。';

  @override
  String sshAuthAbort(String message) {
    return '认证中断：$message';
  }

  @override
  String get sshNotConnectedLikelyWrongPassword =>
      '未能连接：登录尚未完成连接即断开。使用仅密码登录时，多为用户名或 SSH 密码错误；若已确认无误，也可能是网络不稳定或服务器主动断开。';

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

  @override
  String get menuLlmSettings => '大模型与助手…';

  @override
  String get llmSettingsTitle => '大模型';

  @override
  String get llmSettingsHint =>
      '使用 OpenAI 兼容的 Chat Completions 接口。基础地址通常为 `https://…/v1`；也可直接填写以 `/chat/completions` 结尾的完整 URL。API Key 仅保存在本机。';

  @override
  String get llmBaseUrlLabel => '基础 URL';

  @override
  String get llmBaseUrlHint => '例如 https://api.openai.com/v1';

  @override
  String get llmModelLabel => '模型';

  @override
  String get llmModelHint => '例如 gpt-4o-mini';

  @override
  String get llmApiKeyLabel => 'API Key（可选）';

  @override
  String get llmApiKeyHint => '部分本地服务可留空';

  @override
  String get llmToggleKeyVisibility => '显示 / 隐藏';

  @override
  String get llmTestConnection => '连接测试';

  @override
  String get llmTestConnectionTooltip => '发送最小请求验证地址、模型与密钥';

  @override
  String get llmTestSuccess => '连接测试成功';

  @override
  String llmTestFailed(String error) {
    return '连接测试失败：$error';
  }

  @override
  String get llmMissingConfig => '请先在「大模型与助手」中填写基础 URL 与模型。';

  @override
  String get assistantPanelTitle => '助手';

  @override
  String get assistantExpandTooltip => '展开助手';

  @override
  String get assistantCollapseTooltip => '收起助手';

  @override
  String get assistantStopTooltip => '停止生成';

  @override
  String get assistantClearTooltip => '清空对话';

  @override
  String get assistantClearConfirmTitle => '清空对话？';

  @override
  String get assistantClearConfirmBody => '将移除当前会话中的助手消息（系统提示会保留）。';

  @override
  String get assistantClearConfirm => '清空';

  @override
  String get assistantSend => '发送';

  @override
  String get assistantInputHint =>
      '输入问题…（Enter 换行；Windows / Linux：Ctrl+Enter 发送；Mac：⌘+Enter 发送）';

  @override
  String get assistantThinking => '正在思考…';

  @override
  String get assistantNotConnected => '当前无已连接会话或本标签未连接：无法向终端注入命令，仍可讨论命令用法。';

  @override
  String assistantToolRunning(String names) {
    return '调用工具：$names';
  }

  @override
  String get assistantTerminalApprovalTitle => '终端命令';

  @override
  String get assistantTerminalApprovalSubtitle =>
      '助手将把下列内容发送到当前 SSH 终端，效果等同于你在该终端里直接键入（含换行与转义）。请确认你信任该操作后再运行。';

  @override
  String get assistantTerminalCommandSectionTitle => '将发送的内容';

  @override
  String get assistantTerminalSecurityHint => '不受信任的命令可能修改或删除远端文件、消耗资源或泄露环境信息。';

  @override
  String get assistantTerminalDeny => '不允许';

  @override
  String get assistantTerminalAllowExecute => '运行';

  @override
  String get assistantReasoningHeader => '思考过程';

  @override
  String get assistantAnswerHeader => '回复';

  @override
  String get assistantUserHeader => '你';

  @override
  String get assistantReasoningExpand => '展开思考';

  @override
  String get assistantReasoningCollapse => '收起思考';

  @override
  String get assistantToolResultHeader => '终端输出';

  @override
  String get assistantToolResultEmpty => '（无终端输出）';

  @override
  String get menuCheckForUpdates => '检查更新…';

  @override
  String get updateChecking => '正在检查更新…';

  @override
  String get updateAvailableTitle => '发现新版本';

  @override
  String updateAvailableMessage(String version) {
    return 'GitHub 上已有版本 $version。';
  }

  @override
  String get updateReleaseNotes => '更新说明';

  @override
  String get updateDownloadInstall => '下载并安装';

  @override
  String get updateLater => '稍后';

  @override
  String get updateSkipVersion => '跳过此版本';

  @override
  String updateDownloading(int percent) {
    return '正在下载… $percent%';
  }

  @override
  String get updateInstalling => '正在安装…应用将重新启动。';

  @override
  String get updateUpToDateTitle => '已是最新版本';

  @override
  String get updateUpToDateMessage => 'EasyTerm 已安装最新发布版本。';

  @override
  String get updateErrorTitle => '更新失败';

  @override
  String updateError(String error) {
    return '$error';
  }

  @override
  String get updateErrorUnknown => '无法检查更新。';

  @override
  String get updateRetry => '重试';

  @override
  String get updateUnsupported => '自动更新仅支持 macOS 与 Windows。';

  @override
  String get updateOk => '确定';

  @override
  String get desktopReconnecting => '正在重连…';

  @override
  String get desktopReconnect => '重连';

  @override
  String get desktopDismissBanner => '关闭提示';

  @override
  String get desktopPaused => '已暂停';

  @override
  String get desktopUndoLast => '撤销上一次';

  @override
  String get sudoNeedAuthTitle => '需要 sudo 授权';

  @override
  String get sudoAuthBody =>
      '远端执行特权命令需要 sudo 密码。密码将在本次会话内复用（15 分钟空闲后失效），不会保存到本地。';

  @override
  String get sudoPasswordLabel => 'sudo 密码';

  @override
  String get sudoUseSshPassword => '使用 SSH 登录密码';

  @override
  String get sudoAuthorize => '授权';

  @override
  String get sudoPasswordIncorrect => '密码不正确，请重试';

  @override
  String get sudoLockedSnack => '已锁定 sudo 密码';

  @override
  String get sudoCancel => '取消';

  @override
  String get sudoShowPassword => '显示';

  @override
  String get sudoHidePassword => '隐藏';

  @override
  String get bulkOperationTitle => '批量执行命令';

  @override
  String get bulkTargetHosts => '目标主机';

  @override
  String get bulkNoConnectedHosts => '当前没有已连接的会话。请先打开标签页再执行批量命令。';

  @override
  String get bulkNoHostsSelected => '请至少选择一台已连接的主机。';

  @override
  String get bulkCommandEmpty => '请输入要执行的命令。';

  @override
  String get bulkCommandLabel => '命令';

  @override
  String get bulkParallel => '并行执行';

  @override
  String get bulkTimeoutSec => '超时 (秒)';

  @override
  String get bulkExecute => '执行';

  @override
  String get bulkResults => '结果';

  @override
  String get sshConfigImportTitle => '导入 SSH Config';

  @override
  String sshConfigImportSource(String path) {
    return '源文件: $path';
  }

  @override
  String get sshConfigImportEmpty => '未发现 Host 条目（Host * 等通配会被跳过）。';

  @override
  String sshConfigImportFound(int count) {
    return '发现 $count 个主机配置';
  }

  @override
  String get sshConfigConflictLabel => '冲突处理';

  @override
  String get sshConfigConflictSkip => '跳过';

  @override
  String get sshConfigConflictOverwrite => '覆盖';

  @override
  String get sshConfigConflictDuplicate => '创建副本';

  @override
  String get sshConfigImportAll => '导入全部';

  @override
  String get sshConfigImportSelected => '导入选中';

  @override
  String sshConfigImportDone(
    int imported,
    int skipped,
    int overwritten,
    int duplicated,
  ) {
    return '已导入 $imported，跳过 $skipped，覆盖 $overwritten，副本 $duplicated';
  }

  @override
  String get hostGroupEditorTitle => '主机分组';

  @override
  String get hostGroupsHeader => '分组';

  @override
  String get hostGroupsEmpty => '暂无分组。';

  @override
  String get hostGroupCreateTitle => '新建分组';

  @override
  String get hostGroupRenameTitle => '重命名分组';

  @override
  String get hostGroupDeleteTitle => '删除分组';

  @override
  String hostGroupDeleteConfirm(String name) {
    return '删除分组「$name」？主机本身不会被删除。';
  }

  @override
  String get hostGroupNameLabel => '分组名称';

  @override
  String hostGroupMemberCount(int count) {
    return '$count 台主机';
  }

  @override
  String get hostGroupSelectHint => '选择一个分组以分配主机。';

  @override
  String hostGroupMembersOf(String name) {
    return '成员 · $name';
  }

  @override
  String get hostGroupNoMembers => '该分组暂无成员。';

  @override
  String get hostGroupAddMember => '添加主机';

  @override
  String get hostGroupRemoveMember => '移出分组';

  @override
  String get hostSearchHint => '搜索主机…';

  @override
  String hostUngroupedHeader(int count) {
    return '未分组 ($count)';
  }

  @override
  String get connectionAdvancedSection => '高级';

  @override
  String get connectionJumpHostLabel => '跳板机 (ProxyJump)';

  @override
  String get connectionJumpHostNone => '无';

  @override
  String get connectionTimeoutSecLabel => '连接超时 (秒)';
}
