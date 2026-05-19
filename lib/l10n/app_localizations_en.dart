// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'EasyTerm';

  @override
  String get appBarTitle => 'EasyTerm';

  @override
  String get newConnection => 'New connection';

  @override
  String get settingsTooltip => 'Settings';

  @override
  String get menuInterfaceSettings => 'Interface & appearance…';

  @override
  String get menuTerminalAndConnection => 'Terminal & connection settings…';

  @override
  String get menuCloseAllSessions => 'Close all sessions';

  @override
  String get menuAbout => 'About EasyTerm';

  @override
  String aboutCurrentVersion(String version) {
    return 'Version $version';
  }

  @override
  String get menuQuit => 'Quit EasyTerm';

  @override
  String get menuFile => 'File';

  @override
  String get menuCloseTab => 'Close Tab';

  @override
  String get aboutDescription =>
      'Multi-session SSH terminal with SFTP file browsing.';

  @override
  String get sidebarSavedHostsTooltip => 'Saved hosts';

  @override
  String get sidebarFilesTooltip => 'Files';

  @override
  String get placeholderFileBrowserTitle => 'File browser';

  @override
  String get placeholderFileBrowserSubtitle =>
      'Browse remote folders after you connect.';

  @override
  String get placeholderTerminalTitle => 'Terminal';

  @override
  String get placeholderTerminalSubtitle =>
      'Open a session from Saved on the left, or use New connection above.';

  @override
  String get savedConnectionsHeader => 'Saved connections';

  @override
  String get savedConnectionsEmpty =>
      'No entries yet. Use New connection at the top to add one here.';

  @override
  String get contextOpenSession => 'Open session';

  @override
  String get contextEdit => 'Edit…';

  @override
  String get contextDelete => 'Delete';

  @override
  String snackbarPrivateKeyReadFailed(String error) {
    return 'Could not read the private key file (path may be from another machine or invalid): $error';
  }

  @override
  String get connectionEditTitle => 'Edit connection';

  @override
  String get connectionNewTitle => 'New host';

  @override
  String get connectionDeviceNameLabel => 'Device name (optional)';

  @override
  String get connectionDeviceNameHint => 'e.g. Company GPU server';

  @override
  String get connectionHostLabel => 'Host';

  @override
  String get connectionHostHint => 'IP or hostname';

  @override
  String get connectionPortLabel => 'Port';

  @override
  String get connectionUserLabel => 'Username';

  @override
  String get connectionPasswordLabel => 'Password / key passphrase';

  @override
  String get connectionAuthMethodLabel => 'Sign-in method';

  @override
  String get connectionAuthPassword => 'Password';

  @override
  String get connectionAuthPrivateKey => 'Private key';

  @override
  String get connectionSshPasswordLabel => 'SSH password';

  @override
  String get connectionSshPasswordHintEdit =>
      'Leave blank to keep the saved password';

  @override
  String get connectionKeyPassphraseLabel => 'Key passphrase (optional)';

  @override
  String get connectionKeyPassphraseHintEdit =>
      'Leave blank to keep the saved key passphrase';

  @override
  String get connectionPasswordHintEdit =>
      'Leave blank to keep the saved passphrase';

  @override
  String get connectionKeyPathLabel => 'Private key file';

  @override
  String get connectionKeyPathHint => 'On desktop, use Browse on the right';

  @override
  String get connectionMissingKeyPath => 'Please choose a private key file.';

  @override
  String get connectionPrivateKeyEmpty =>
      'The key file is empty or not valid PEM text.';

  @override
  String get connectionPickKeyTooltip => 'Choose private key file';

  @override
  String connectionPickKeyFailed(String error) {
    return 'Could not choose a private key file: $error';
  }

  @override
  String get connectionSubmitConnect => 'Connect';

  @override
  String get connectionSubmitSave => 'Save';

  @override
  String get connectionMissingHostUser => 'Please enter host and username.';

  @override
  String savedHostConnectTitle(String label) {
    return 'Connect to “$label”';
  }

  @override
  String get savedHostKeyPassphraseHint =>
      'A key path is set; the passphrase only decrypts the key (leave empty if the key is not encrypted).';

  @override
  String get savedHostPasswordFieldKey => 'Key passphrase / SSH password';

  @override
  String get savedHostPasswordFieldPassword => 'SSH password';

  @override
  String get savedHostPasswordHelperKey =>
      'Leave empty for unencrypted keys with public-key login.';

  @override
  String get savedHostPasswordHelperPassword =>
      'For key login, set a private key path in New host first.';

  @override
  String get savedHostConnect => 'Connect';

  @override
  String get settingsDialogTitle => 'Terminal & connection';

  @override
  String get settingsSectionConnection => 'Connection';

  @override
  String get settingsSectionTerminal => 'Terminal';

  @override
  String get settingsSectionLanguage => 'Language';

  @override
  String get settingsLanguageLabel => 'Display language';

  @override
  String get settingsLanguageChinese => 'Chinese';

  @override
  String get settingsLanguageEnglish => 'English';

  @override
  String get settingsTimeoutLabel => 'Timeout (seconds)';

  @override
  String get settingsTimeoutHint => '5–600, default 30';

  @override
  String get settingsRetryLabel => 'Retry count';

  @override
  String get settingsRetryHint => 'Extra retries after failure, 0–20';

  @override
  String get settingsRetryIntervalLabel => 'Retry interval (seconds)';

  @override
  String get settingsRetryIntervalHint => '1–300';

  @override
  String get settingsKeepAliveLabel => 'Keep-alive (seconds)';

  @override
  String get settingsKeepAliveHint => '0–3600, 0 disables';

  @override
  String get settingsPtyColsLabel => 'PTY columns';

  @override
  String get settingsPtyColsHint => '40–512, new sessions only';

  @override
  String get settingsPtyRowsLabel => 'PTY rows';

  @override
  String get settingsPtyRowsHint => '8–256, new sessions only';

  @override
  String get settingsTermTypeLabel => 'Terminal type';

  @override
  String get settingsBufferLabel => 'Scrollback buffer';

  @override
  String get settingsBufferHint => 'Lines 100–100000, new sessions only';

  @override
  String get settingsFontSizeLabel => 'Font size';

  @override
  String get settingsFontSizeHint => '6–48';

  @override
  String get settingsFontFamilyLabel => 'Font';

  @override
  String get settingsSelectCopyLabel => 'Select to copy';

  @override
  String get settingsSelectCopyDescription =>
      'Auto-copy selection to clipboard (short debounce).';

  @override
  String get settingsInvalidNumbers =>
      'Enter valid numbers (see each field’s range).';

  @override
  String get settingsCancel => 'Cancel';

  @override
  String get settingsSave => 'Save';

  @override
  String get terminalConnecting => 'Connecting…';

  @override
  String get terminalConnectionFailed => 'Connection failed';

  @override
  String get terminalRetry => 'Retry';

  @override
  String get terminalWaiting => 'Waiting to connect…';

  @override
  String get terminalMenuCopy => 'Copy';

  @override
  String get terminalMenuPaste => 'Paste';

  @override
  String get terminalMenuSelectAll => 'Select all';

  @override
  String get terminalMenuClearSelection => 'Clear selection';

  @override
  String get sftpPanelTitle => 'File browser';

  @override
  String get sftpRefreshTooltip => 'Refresh';

  @override
  String get sftpColumnName => 'Name';

  @override
  String get sftpColumnSize => 'Size';

  @override
  String get sftpColumnModified => 'Modified';

  @override
  String get sftpBreadcrumbRoot => 'Root';

  @override
  String get sftpDownloadMenu => 'Download…';

  @override
  String get sftpOpenInEditorMenu => 'Open in editor…';

  @override
  String get sftpDeleteMenu => 'Delete';

  @override
  String get sftpPickDirTitle =>
      'Choose where to save (a subfolder with the same name will be created)';

  @override
  String get sftpSaveFileTitle => 'Save remote file';

  @override
  String sftpDownloadedDir(String name) {
    return 'Downloaded folder $name';
  }

  @override
  String sftpDownloadedFile(String name) {
    return 'Downloaded $name';
  }

  @override
  String sftpUploaded(String name) {
    return 'Uploaded $name';
  }

  @override
  String sftpUploadFailed(String error) {
    return 'Upload failed: $error';
  }

  @override
  String sftpTransferQueueProgress(int done, int total) {
    return '$done / $total tasks';
  }

  @override
  String get sftpTransferKindUploadTooltip => 'Upload';

  @override
  String get sftpTransferKindDownloadTooltip => 'Download';

  @override
  String get sftpUploadQueueExpand => 'Show all';

  @override
  String get sftpUploadQueueCollapse => 'Show less';

  @override
  String get sftpUploadRowPending => 'Queued';

  @override
  String get sftpUploadCancelFileTooltip => 'Cancel this upload';

  @override
  String get sftpUploadCancelAllTooltip => 'Cancel all';

  @override
  String get sftpUploadOverwriteTitle => 'Replace on server?';

  @override
  String sftpUploadOverwriteBody(String name) {
    return '“$name” already exists on the server. Replace it? Remote files will be overwritten or removed.';
  }

  @override
  String get sftpUploadOverwriteConfirm => 'Replace';

  @override
  String get sftpUploadConflictTypeMismatchTitle => 'Cannot replace';

  @override
  String sftpUploadConflictTypeMismatchBody(String name) {
    return '“$name” does not match the type on the server (file vs folder). Remove the remote item first, then upload again.';
  }

  @override
  String get sftpBinaryNotOpened =>
      'This file looks binary; open in editor was cancelled.';

  @override
  String get sftpDeleteConfirmTitle => 'Delete?';

  @override
  String sftpDeleteConfirmBody(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get sftpDeleteConfirm => 'Delete';

  @override
  String get sftpCancel => 'Cancel';

  @override
  String get remoteEditorSave => 'Save';

  @override
  String get remoteEditorRemoteChanged =>
      'The file on the server was modified by another process.';

  @override
  String get remoteEditorReload => 'Reload';

  @override
  String get remoteEditorIgnore => 'Ignore';

  @override
  String get remoteEditorSaved => 'Saved to the server.';

  @override
  String remoteEditorSaveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String get statusNotConnected => 'Not connected';

  @override
  String get statusNoRemoteInfo => 'Remote metrics unavailable';

  @override
  String get statusPickHost => 'Pick a host on the left and connect';

  @override
  String get statusBeijingTimeLabel => 'Beijing';

  @override
  String get statusRemoteUptimePrefix => 'Remote';

  @override
  String statusRemoteUptimeLine(String uptime) {
    return 'Remote: $uptime';
  }

  @override
  String get tooltipMemNoData => 'Memory usage\n(no data)';

  @override
  String tooltipMem(String percent) {
    return 'Memory usage\nAbout $percent% (vs MemAvailable / MemTotal)';
  }

  @override
  String get tooltipCpuNoData => 'CPU usage\n(no data; needs vmstat sampling)';

  @override
  String tooltipCpu(String percent) {
    return 'CPU usage\nAbout $percent% (vmstat 1s sample)';
  }

  @override
  String get tooltipDiskTitle => 'Disk space on /';

  @override
  String tooltipDiskUsed(String percent) {
    return '\nUsed: about $percent%';
  }

  @override
  String get tooltipDiskNoUsage => '\nUsage: no data';

  @override
  String get tooltipInodeTitle => 'Inodes on /';

  @override
  String tooltipInodeUsed(String percent) {
    return '\nUsed: about $percent%';
  }

  @override
  String get tooltipInodeNoUsage => '\nUsage: no data';

  @override
  String get tooltipLoadTitle => 'Load average';

  @override
  String tooltipLoadLine(String line) {
    return '\n1 / 5 / 15 min: $line';
  }

  @override
  String get tooltipLoadNoData => '\n(no /proc/loadavg)';

  @override
  String tooltipLoadPressure(String percent) {
    return '\nPressure vs CPU count: about $percent%';
  }

  @override
  String get sshAuthFailKeyAndPassword =>
      'Authentication failed: the server rejected the key, or the key passphrase / SSH password is wrong. Double-check each.';

  @override
  String get sshAuthFailKey =>
      'Authentication failed: the key does not match this account, or the key passphrase is wrong.';

  @override
  String get sshAuthFailPassword =>
      'Could not connect: wrong username or SSH password (authentication failed). If the server allows keys only, configure a key and avoid mixing passwords incorrectly.';

  @override
  String get sshAuthFailNone =>
      'Authentication failed: no SSH password and no usable private key.';

  @override
  String sshAuthAbort(String message) {
    return 'Authentication aborted: $message';
  }

  @override
  String get sshNotConnectedLikelyWrongPassword =>
      'Could not connect: authentication did not finish before the connection closed. With password-only login, this usually means the username or SSH password is wrong (after double-checking, consider network issues or the server closing the session).';

  @override
  String sshKeyDecode(String message) {
    return 'Could not parse private key or wrong passphrase: $message';
  }

  @override
  String get interfaceSettingsTitle => 'Interface';

  @override
  String get interfaceThemeLabel => 'Appearance';

  @override
  String get interfaceThemeDark => 'Dark';

  @override
  String get interfaceThemeLight => 'Light';

  @override
  String get interfaceThemeSystem => 'Match system';

  @override
  String get interfaceDone => 'Done';

  @override
  String get menuLlmSettings => 'LLM & assistant…';

  @override
  String get llmSettingsTitle => 'Large language model';

  @override
  String get llmSettingsHint =>
      'Uses an OpenAI-compatible Chat Completions API. Base URL is usually `https://…/v1`, or paste a full URL ending with `/chat/completions`. The API key is stored only on this device.';

  @override
  String get llmBaseUrlLabel => 'Base URL';

  @override
  String get llmBaseUrlHint => 'e.g. https://api.openai.com/v1';

  @override
  String get llmModelLabel => 'Model';

  @override
  String get llmModelHint => 'e.g. gpt-4o-mini';

  @override
  String get llmApiKeyLabel => 'API key (optional)';

  @override
  String get llmApiKeyHint => 'Some local servers need no key';

  @override
  String get llmToggleKeyVisibility => 'Show / hide';

  @override
  String get llmTestConnection => 'Test connection';

  @override
  String get llmTestConnectionTooltip =>
      'Send a minimal request to verify URL, model, and credentials';

  @override
  String get llmTestSuccess => 'Connection test succeeded';

  @override
  String llmTestFailed(String error) {
    return 'Connection test failed: $error';
  }

  @override
  String get llmMissingConfig =>
      'Set base URL and model in LLM & assistant first.';

  @override
  String get assistantPanelTitle => 'Assistant';

  @override
  String get assistantExpandTooltip => 'Expand assistant';

  @override
  String get assistantCollapseTooltip => 'Collapse assistant';

  @override
  String get assistantStopTooltip => 'Stop generation';

  @override
  String get assistantClearTooltip => 'Clear chat';

  @override
  String get assistantClearConfirmTitle => 'Clear chat?';

  @override
  String get assistantClearConfirmBody =>
      'Removes messages in this chat (system prompt is kept).';

  @override
  String get assistantClearConfirm => 'Clear';

  @override
  String get assistantSend => 'Send';

  @override
  String get assistantInputHint =>
      'Type a message… (Enter for newline; send with Ctrl+Enter on Windows/Linux, ⌘+Enter on macOS)';

  @override
  String get assistantThinking => 'Thinking…';

  @override
  String get assistantNotConnected =>
      'No connected session (or this tab is offline): terminal tools cannot inject commands; you can still discuss usage.';

  @override
  String assistantToolRunning(String names) {
    return 'Calling tools: $names';
  }

  @override
  String get assistantTerminalApprovalTitle => 'Terminal command';

  @override
  String get assistantTerminalApprovalSubtitle =>
      'The assistant will send the content below to your SSH session, as if you typed it in that terminal (including newlines and escapes). Only run it if you trust the action.';

  @override
  String get assistantTerminalCommandSectionTitle => 'Payload';

  @override
  String get assistantTerminalSecurityHint =>
      'Untrusted commands can change or delete remote files, burn resources, or leak environment details. Like confirming Run in Cursor, you decide whether to proceed.';

  @override
  String get assistantTerminalDeny => 'Deny';

  @override
  String get assistantTerminalAllowExecute => 'Run';

  @override
  String get assistantReasoningHeader => 'Reasoning';

  @override
  String get assistantAnswerHeader => 'Answer';

  @override
  String get assistantUserHeader => 'You';

  @override
  String get assistantReasoningExpand => 'Show reasoning';

  @override
  String get assistantReasoningCollapse => 'Hide reasoning';

  @override
  String get assistantToolResultHeader => 'Terminal output';

  @override
  String get assistantToolResultEmpty => '(No terminal output)';

  @override
  String get menuCheckForUpdates => 'Check for updates…';

  @override
  String get updateChecking => 'Checking for updates…';

  @override
  String get updateAvailableTitle => 'Update available';

  @override
  String updateAvailableMessage(String version) {
    return 'Version $version is available on GitHub.';
  }

  @override
  String get updateReleaseNotes => 'Release notes';

  @override
  String get updateDownloadInstall => 'Download and install';

  @override
  String get updateLater => 'Later';

  @override
  String get updateSkipVersion => 'Skip this version';

  @override
  String updateDownloading(int percent) {
    return 'Downloading… $percent%';
  }

  @override
  String get updateInstalling => 'Installing… the app will restart.';

  @override
  String get updateUpToDateTitle => 'You\'re up to date';

  @override
  String get updateUpToDateMessage =>
      'EasyTerm is already on the latest release.';

  @override
  String get updateErrorTitle => 'Update failed';

  @override
  String updateError(String error) {
    return '$error';
  }

  @override
  String get updateErrorUnknown => 'Could not check for updates.';

  @override
  String get updateRetry => 'Retry';

  @override
  String get updateUnsupported =>
      'Automatic updates are only available on macOS and Windows.';

  @override
  String get updateOk => 'OK';
}
