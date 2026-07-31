import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'EasyTerm'**
  String get appTitle;

  /// No description provided for @appBarTitle.
  ///
  /// In en, this message translates to:
  /// **'EasyTerm'**
  String get appBarTitle;

  /// No description provided for @newConnection.
  ///
  /// In en, this message translates to:
  /// **'New connection'**
  String get newConnection;

  /// No description provided for @settingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTooltip;

  /// No description provided for @menuInterfaceSettings.
  ///
  /// In en, this message translates to:
  /// **'Interface & appearance…'**
  String get menuInterfaceSettings;

  /// No description provided for @menuTerminalAndConnection.
  ///
  /// In en, this message translates to:
  /// **'Terminal & connection settings…'**
  String get menuTerminalAndConnection;

  /// No description provided for @menuCloseAllSessions.
  ///
  /// In en, this message translates to:
  /// **'Close all sessions'**
  String get menuCloseAllSessions;

  /// No description provided for @menuAbout.
  ///
  /// In en, this message translates to:
  /// **'About EasyTerm'**
  String get menuAbout;

  /// No description provided for @aboutCurrentVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String aboutCurrentVersion(String version);

  /// No description provided for @menuQuit.
  ///
  /// In en, this message translates to:
  /// **'Quit EasyTerm'**
  String get menuQuit;

  /// No description provided for @menuFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get menuFile;

  /// No description provided for @menuCloseTab.
  ///
  /// In en, this message translates to:
  /// **'Close Tab'**
  String get menuCloseTab;

  /// No description provided for @menuTabCloseLeft.
  ///
  /// In en, this message translates to:
  /// **'Close tabs to the left'**
  String get menuTabCloseLeft;

  /// No description provided for @menuTabCloseRight.
  ///
  /// In en, this message translates to:
  /// **'Close tabs to the right'**
  String get menuTabCloseRight;

  /// No description provided for @menuTabCloseOthers.
  ///
  /// In en, this message translates to:
  /// **'Close other tabs'**
  String get menuTabCloseOthers;

  /// No description provided for @menuTabCloseAll.
  ///
  /// In en, this message translates to:
  /// **'Close all tabs'**
  String get menuTabCloseAll;

  /// No description provided for @menuTabDuplicate.
  ///
  /// In en, this message translates to:
  /// **'Duplicate Tab'**
  String get menuTabDuplicate;

  /// No description provided for @menuSplitRight.
  ///
  /// In en, this message translates to:
  /// **'Split Right'**
  String get menuSplitRight;

  /// No description provided for @menuSplitLeft.
  ///
  /// In en, this message translates to:
  /// **'Split Left'**
  String get menuSplitLeft;

  /// No description provided for @menuSplitDown.
  ///
  /// In en, this message translates to:
  /// **'Split Down'**
  String get menuSplitDown;

  /// No description provided for @menuSplitUp.
  ///
  /// In en, this message translates to:
  /// **'Split Up'**
  String get menuSplitUp;

  /// No description provided for @menuView.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get menuView;

  /// No description provided for @menuCodeSnippets.
  ///
  /// In en, this message translates to:
  /// **'Code Snippets'**
  String get menuCodeSnippets;

  /// No description provided for @menuHealthBoard.
  ///
  /// In en, this message translates to:
  /// **'Health Board'**
  String get menuHealthBoard;

  /// No description provided for @paneMenuTooltip.
  ///
  /// In en, this message translates to:
  /// **'Pane actions'**
  String get paneMenuTooltip;

  /// No description provided for @paneSplitRight.
  ///
  /// In en, this message translates to:
  /// **'Split Right'**
  String get paneSplitRight;

  /// No description provided for @paneSplitLeft.
  ///
  /// In en, this message translates to:
  /// **'Split Left'**
  String get paneSplitLeft;

  /// No description provided for @paneSplitDown.
  ///
  /// In en, this message translates to:
  /// **'Split Down'**
  String get paneSplitDown;

  /// No description provided for @paneSplitUp.
  ///
  /// In en, this message translates to:
  /// **'Split Up'**
  String get paneSplitUp;

  /// No description provided for @paneClose.
  ///
  /// In en, this message translates to:
  /// **'Close Pane'**
  String get paneClose;

  /// No description provided for @codeSnippetsTitle.
  ///
  /// In en, this message translates to:
  /// **'Code Snippets'**
  String get codeSnippetsTitle;

  /// No description provided for @codeSnippetsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No snippets yet. Create one to reuse commands or scripts.'**
  String get codeSnippetsEmpty;

  /// No description provided for @codeSnippetNew.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get codeSnippetNew;

  /// No description provided for @codeSnippetEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get codeSnippetEdit;

  /// No description provided for @codeSnippetDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get codeSnippetDelete;

  /// No description provided for @codeSnippetRun.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get codeSnippetRun;

  /// No description provided for @codeSnippetNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get codeSnippetNameLabel;

  /// No description provided for @codeSnippetNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Restart service'**
  String get codeSnippetNameHint;

  /// No description provided for @codeSnippetBodyLabel.
  ///
  /// In en, this message translates to:
  /// **'Body'**
  String get codeSnippetBodyLabel;

  /// No description provided for @codeSnippetBodyHint.
  ///
  /// In en, this message translates to:
  /// **'Commands or script sent to the chosen terminal'**
  String get codeSnippetBodyHint;

  /// No description provided for @codeSnippetSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get codeSnippetSave;

  /// No description provided for @codeSnippetCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get codeSnippetCancel;

  /// No description provided for @codeSnippetDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete “{name}”?'**
  String codeSnippetDeleteConfirm(String name);

  /// No description provided for @codeSnippetNeedSession.
  ///
  /// In en, this message translates to:
  /// **'Open and connect a terminal session first.'**
  String get codeSnippetNeedSession;

  /// No description provided for @codeSnippetRan.
  ///
  /// In en, this message translates to:
  /// **'Sent to terminal'**
  String get codeSnippetRan;

  /// No description provided for @codeSnippetClickTargetHint.
  ///
  /// In en, this message translates to:
  /// **'Click the terminal window to run in (switch tabs first if needed)'**
  String get codeSnippetClickTargetHint;

  /// No description provided for @codeSnippetClickToRun.
  ///
  /// In en, this message translates to:
  /// **'Click to run'**
  String get codeSnippetClickToRun;

  /// No description provided for @healthBoardTitle.
  ///
  /// In en, this message translates to:
  /// **'Health Board'**
  String get healthBoardTitle;

  /// No description provided for @healthBoardSessions.
  ///
  /// In en, this message translates to:
  /// **'Sessions'**
  String get healthBoardSessions;

  /// No description provided for @healthBoardActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get healthBoardActive;

  /// No description provided for @healthBoardConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get healthBoardConnecting;

  /// No description provided for @healthBoardErrors.
  ///
  /// In en, this message translates to:
  /// **'Errors'**
  String get healthBoardErrors;

  /// No description provided for @healthBoardPanes.
  ///
  /// In en, this message translates to:
  /// **'Panes'**
  String get healthBoardPanes;

  /// No description provided for @healthBoardCpu.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get healthBoardCpu;

  /// No description provided for @healthBoardMemory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get healthBoardMemory;

  /// No description provided for @healthBoardDisk.
  ///
  /// In en, this message translates to:
  /// **'Disk'**
  String get healthBoardDisk;

  /// No description provided for @healthBoardLoad.
  ///
  /// In en, this message translates to:
  /// **'Load'**
  String get healthBoardLoad;

  /// No description provided for @healthBoardFetching.
  ///
  /// In en, this message translates to:
  /// **'Fetching remote metrics…'**
  String get healthBoardFetching;

  /// No description provided for @healthBoardMetricsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Remote metrics unavailable (needs Linux /proc)'**
  String get healthBoardMetricsUnavailable;

  /// No description provided for @healthBoardNoSessions.
  ///
  /// In en, this message translates to:
  /// **'No sessions yet. Connect a host to see remote status here.'**
  String get healthBoardNoSessions;

  /// No description provided for @healthBoardNoConnected.
  ///
  /// In en, this message translates to:
  /// **'No connected hosts. Connect to view remote CPU, memory, disk, and load.'**
  String get healthBoardNoConnected;

  /// No description provided for @healthBoardSessionStatus.
  ///
  /// In en, this message translates to:
  /// **'Connection status'**
  String get healthBoardSessionStatus;

  /// No description provided for @healthBoardRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get healthBoardRefresh;

  /// No description provided for @healthBoardConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get healthBoardConnected;

  /// No description provided for @healthBoardDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get healthBoardDisconnected;

  /// No description provided for @healthBoardHost.
  ///
  /// In en, this message translates to:
  /// **'Remote hosts'**
  String get healthBoardHost;

  /// No description provided for @aboutDescription.
  ///
  /// In en, this message translates to:
  /// **'Multi-session SSH terminal with SFTP file browsing.'**
  String get aboutDescription;

  /// No description provided for @sidebarSavedHostsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Saved hosts'**
  String get sidebarSavedHostsTooltip;

  /// No description provided for @sidebarFilesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get sidebarFilesTooltip;

  /// No description provided for @placeholderFileBrowserTitle.
  ///
  /// In en, this message translates to:
  /// **'File browser'**
  String get placeholderFileBrowserTitle;

  /// No description provided for @placeholderFileBrowserSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Browse remote folders after you connect.'**
  String get placeholderFileBrowserSubtitle;

  /// No description provided for @placeholderTerminalTitle.
  ///
  /// In en, this message translates to:
  /// **'Terminal'**
  String get placeholderTerminalTitle;

  /// No description provided for @placeholderTerminalSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Open a session from Saved on the left, or use New connection above.'**
  String get placeholderTerminalSubtitle;

  /// No description provided for @savedConnectionsHeader.
  ///
  /// In en, this message translates to:
  /// **'Saved connections'**
  String get savedConnectionsHeader;

  /// No description provided for @savedConnectionsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No entries yet. Use New connection at the top to add one here.'**
  String get savedConnectionsEmpty;

  /// No description provided for @contextOpenSession.
  ///
  /// In en, this message translates to:
  /// **'Open session'**
  String get contextOpenSession;

  /// No description provided for @contextEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit…'**
  String get contextEdit;

  /// No description provided for @contextDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get contextDelete;

  /// No description provided for @snackbarPrivateKeyReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read the private key file (path may be from another machine or invalid): {error}'**
  String snackbarPrivateKeyReadFailed(String error);

  /// No description provided for @connectionEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit connection'**
  String get connectionEditTitle;

  /// No description provided for @connectionNewTitle.
  ///
  /// In en, this message translates to:
  /// **'New host'**
  String get connectionNewTitle;

  /// No description provided for @connectionDeviceNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Device name (optional)'**
  String get connectionDeviceNameLabel;

  /// No description provided for @connectionDeviceNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Company GPU server'**
  String get connectionDeviceNameHint;

  /// No description provided for @connectionHostLabel.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get connectionHostLabel;

  /// No description provided for @connectionHostHint.
  ///
  /// In en, this message translates to:
  /// **'IP or hostname'**
  String get connectionHostHint;

  /// No description provided for @connectionPortLabel.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get connectionPortLabel;

  /// No description provided for @connectionUserLabel.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get connectionUserLabel;

  /// No description provided for @connectionPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password / key passphrase'**
  String get connectionPasswordLabel;

  /// No description provided for @connectionAuthMethodLabel.
  ///
  /// In en, this message translates to:
  /// **'Sign-in method'**
  String get connectionAuthMethodLabel;

  /// No description provided for @connectionAuthPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get connectionAuthPassword;

  /// No description provided for @connectionAuthPrivateKey.
  ///
  /// In en, this message translates to:
  /// **'Private key'**
  String get connectionAuthPrivateKey;

  /// No description provided for @connectionSshPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'SSH password'**
  String get connectionSshPasswordLabel;

  /// No description provided for @connectionSshPasswordHintEdit.
  ///
  /// In en, this message translates to:
  /// **'Leave blank to keep the saved password'**
  String get connectionSshPasswordHintEdit;

  /// No description provided for @connectionKeyPassphraseLabel.
  ///
  /// In en, this message translates to:
  /// **'Key passphrase (optional)'**
  String get connectionKeyPassphraseLabel;

  /// No description provided for @connectionKeyPassphraseHintEdit.
  ///
  /// In en, this message translates to:
  /// **'Leave blank to keep the saved key passphrase'**
  String get connectionKeyPassphraseHintEdit;

  /// No description provided for @connectionPasswordHintEdit.
  ///
  /// In en, this message translates to:
  /// **'Leave blank to keep the saved passphrase'**
  String get connectionPasswordHintEdit;

  /// No description provided for @connectionKeyPathLabel.
  ///
  /// In en, this message translates to:
  /// **'Private key file'**
  String get connectionKeyPathLabel;

  /// No description provided for @connectionKeyPathHint.
  ///
  /// In en, this message translates to:
  /// **'On desktop, use Browse on the right'**
  String get connectionKeyPathHint;

  /// No description provided for @connectionMissingKeyPath.
  ///
  /// In en, this message translates to:
  /// **'Please choose a private key file.'**
  String get connectionMissingKeyPath;

  /// No description provided for @connectionPrivateKeyEmpty.
  ///
  /// In en, this message translates to:
  /// **'The key file is empty or not valid PEM text.'**
  String get connectionPrivateKeyEmpty;

  /// No description provided for @connectionPickKeyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Choose private key file'**
  String get connectionPickKeyTooltip;

  /// No description provided for @connectionPickKeyFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not choose a private key file: {error}'**
  String connectionPickKeyFailed(String error);

  /// No description provided for @connectionSubmitConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connectionSubmitConnect;

  /// No description provided for @connectionSubmitSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get connectionSubmitSave;

  /// No description provided for @connectionMissingHostUser.
  ///
  /// In en, this message translates to:
  /// **'Please enter host and username.'**
  String get connectionMissingHostUser;

  /// No description provided for @savedHostConnectTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect to “{label}”'**
  String savedHostConnectTitle(String label);

  /// No description provided for @savedHostKeyPassphraseHint.
  ///
  /// In en, this message translates to:
  /// **'A key path is set; the passphrase only decrypts the key (leave empty if the key is not encrypted).'**
  String get savedHostKeyPassphraseHint;

  /// No description provided for @savedHostPasswordFieldKey.
  ///
  /// In en, this message translates to:
  /// **'Key passphrase / SSH password'**
  String get savedHostPasswordFieldKey;

  /// No description provided for @savedHostPasswordFieldPassword.
  ///
  /// In en, this message translates to:
  /// **'SSH password'**
  String get savedHostPasswordFieldPassword;

  /// No description provided for @savedHostPasswordHelperKey.
  ///
  /// In en, this message translates to:
  /// **'Leave empty for unencrypted keys with public-key login.'**
  String get savedHostPasswordHelperKey;

  /// No description provided for @savedHostPasswordHelperPassword.
  ///
  /// In en, this message translates to:
  /// **'For key login, set a private key path in New host first.'**
  String get savedHostPasswordHelperPassword;

  /// No description provided for @savedHostConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get savedHostConnect;

  /// No description provided for @settingsDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Terminal & connection'**
  String get settingsDialogTitle;

  /// No description provided for @settingsSectionConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get settingsSectionConnection;

  /// No description provided for @settingsSectionTerminal.
  ///
  /// In en, this message translates to:
  /// **'Terminal'**
  String get settingsSectionTerminal;

  /// No description provided for @settingsSectionLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsSectionLanguage;

  /// No description provided for @settingsLanguageLabel.
  ///
  /// In en, this message translates to:
  /// **'Display language'**
  String get settingsLanguageLabel;

  /// No description provided for @settingsLanguageChinese.
  ///
  /// In en, this message translates to:
  /// **'Chinese'**
  String get settingsLanguageChinese;

  /// No description provided for @settingsLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get settingsLanguageEnglish;

  /// No description provided for @settingsTimeoutLabel.
  ///
  /// In en, this message translates to:
  /// **'Timeout (seconds)'**
  String get settingsTimeoutLabel;

  /// No description provided for @settingsTimeoutHint.
  ///
  /// In en, this message translates to:
  /// **'5–600, default 30'**
  String get settingsTimeoutHint;

  /// No description provided for @settingsRetryLabel.
  ///
  /// In en, this message translates to:
  /// **'Retry count'**
  String get settingsRetryLabel;

  /// No description provided for @settingsRetryHint.
  ///
  /// In en, this message translates to:
  /// **'Extra retries after failure, 0–20'**
  String get settingsRetryHint;

  /// No description provided for @settingsRetryIntervalLabel.
  ///
  /// In en, this message translates to:
  /// **'Retry interval (seconds)'**
  String get settingsRetryIntervalLabel;

  /// No description provided for @settingsRetryIntervalHint.
  ///
  /// In en, this message translates to:
  /// **'1–300'**
  String get settingsRetryIntervalHint;

  /// No description provided for @settingsKeepAliveLabel.
  ///
  /// In en, this message translates to:
  /// **'Keep-alive (seconds)'**
  String get settingsKeepAliveLabel;

  /// No description provided for @settingsKeepAliveHint.
  ///
  /// In en, this message translates to:
  /// **'0–3600, 0 disables'**
  String get settingsKeepAliveHint;

  /// No description provided for @settingsPtyColsLabel.
  ///
  /// In en, this message translates to:
  /// **'PTY columns'**
  String get settingsPtyColsLabel;

  /// No description provided for @settingsPtyColsHint.
  ///
  /// In en, this message translates to:
  /// **'40–512, new sessions only'**
  String get settingsPtyColsHint;

  /// No description provided for @settingsPtyRowsLabel.
  ///
  /// In en, this message translates to:
  /// **'PTY rows'**
  String get settingsPtyRowsLabel;

  /// No description provided for @settingsPtyRowsHint.
  ///
  /// In en, this message translates to:
  /// **'8–256, new sessions only'**
  String get settingsPtyRowsHint;

  /// No description provided for @settingsTermTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Terminal type'**
  String get settingsTermTypeLabel;

  /// No description provided for @settingsBufferLabel.
  ///
  /// In en, this message translates to:
  /// **'Scrollback buffer'**
  String get settingsBufferLabel;

  /// No description provided for @settingsBufferHint.
  ///
  /// In en, this message translates to:
  /// **'Lines 100–100000, new sessions only'**
  String get settingsBufferHint;

  /// No description provided for @settingsFontSizeLabel.
  ///
  /// In en, this message translates to:
  /// **'Font size'**
  String get settingsFontSizeLabel;

  /// No description provided for @settingsFontSizeHint.
  ///
  /// In en, this message translates to:
  /// **'6–48'**
  String get settingsFontSizeHint;

  /// No description provided for @settingsFontFamilyLabel.
  ///
  /// In en, this message translates to:
  /// **'Font'**
  String get settingsFontFamilyLabel;

  /// No description provided for @settingsSelectCopyLabel.
  ///
  /// In en, this message translates to:
  /// **'Select to copy'**
  String get settingsSelectCopyLabel;

  /// No description provided for @settingsSelectCopyDescription.
  ///
  /// In en, this message translates to:
  /// **'Auto-copy selection to clipboard (short debounce).'**
  String get settingsSelectCopyDescription;

  /// No description provided for @settingsInvalidNumbers.
  ///
  /// In en, this message translates to:
  /// **'Enter valid numbers (see each field’s range).'**
  String get settingsInvalidNumbers;

  /// No description provided for @settingsCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get settingsCancel;

  /// No description provided for @settingsSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get settingsSave;

  /// No description provided for @terminalConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get terminalConnecting;

  /// No description provided for @terminalConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get terminalConnectionFailed;

  /// No description provided for @terminalRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get terminalRetry;

  /// No description provided for @terminalWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting to connect…'**
  String get terminalWaiting;

  /// No description provided for @terminalDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Connection lost'**
  String get terminalDisconnected;

  /// No description provided for @terminalReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get terminalReconnect;

  /// No description provided for @terminalReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get terminalReconnecting;

  /// No description provided for @terminalMenuCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get terminalMenuCopy;

  /// No description provided for @terminalMenuPaste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get terminalMenuPaste;

  /// No description provided for @terminalMenuSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get terminalMenuSelectAll;

  /// No description provided for @terminalMenuClearSelection.
  ///
  /// In en, this message translates to:
  /// **'Clear selection'**
  String get terminalMenuClearSelection;

  /// No description provided for @sftpPanelTitle.
  ///
  /// In en, this message translates to:
  /// **'File browser'**
  String get sftpPanelTitle;

  /// No description provided for @sftpRefreshTooltip.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get sftpRefreshTooltip;

  /// No description provided for @sftpColumnName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get sftpColumnName;

  /// No description provided for @sftpColumnSize.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get sftpColumnSize;

  /// No description provided for @sftpColumnModified.
  ///
  /// In en, this message translates to:
  /// **'Modified'**
  String get sftpColumnModified;

  /// No description provided for @sftpBreadcrumbRoot.
  ///
  /// In en, this message translates to:
  /// **'Root'**
  String get sftpBreadcrumbRoot;

  /// No description provided for @sftpDownloadMenu.
  ///
  /// In en, this message translates to:
  /// **'Download…'**
  String get sftpDownloadMenu;

  /// No description provided for @sftpOpenInEditorMenu.
  ///
  /// In en, this message translates to:
  /// **'Open in editor…'**
  String get sftpOpenInEditorMenu;

  /// No description provided for @sftpDeleteMenu.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get sftpDeleteMenu;

  /// No description provided for @sftpPickDirTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose where to save (a subfolder with the same name will be created)'**
  String get sftpPickDirTitle;

  /// No description provided for @sftpSaveFileTitle.
  ///
  /// In en, this message translates to:
  /// **'Save remote file'**
  String get sftpSaveFileTitle;

  /// No description provided for @sftpDownloadedDir.
  ///
  /// In en, this message translates to:
  /// **'Downloaded folder {name}'**
  String sftpDownloadedDir(String name);

  /// No description provided for @sftpDownloadedFile.
  ///
  /// In en, this message translates to:
  /// **'Downloaded {name}'**
  String sftpDownloadedFile(String name);

  /// No description provided for @sftpUploaded.
  ///
  /// In en, this message translates to:
  /// **'Uploaded {name}'**
  String sftpUploaded(String name);

  /// No description provided for @sftpUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed: {error}'**
  String sftpUploadFailed(String error);

  /// No description provided for @sftpTransferQueueProgress.
  ///
  /// In en, this message translates to:
  /// **'{done} / {total} tasks'**
  String sftpTransferQueueProgress(int done, int total);

  /// No description provided for @sftpTransferKindUploadTooltip.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get sftpTransferKindUploadTooltip;

  /// No description provided for @sftpTransferKindDownloadTooltip.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get sftpTransferKindDownloadTooltip;

  /// No description provided for @sftpUploadQueueExpand.
  ///
  /// In en, this message translates to:
  /// **'Show all'**
  String get sftpUploadQueueExpand;

  /// No description provided for @sftpUploadQueueCollapse.
  ///
  /// In en, this message translates to:
  /// **'Show less'**
  String get sftpUploadQueueCollapse;

  /// No description provided for @sftpUploadRowPending.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get sftpUploadRowPending;

  /// No description provided for @sftpUploadCancelFileTooltip.
  ///
  /// In en, this message translates to:
  /// **'Cancel this upload'**
  String get sftpUploadCancelFileTooltip;

  /// No description provided for @sftpUploadCancelAllTooltip.
  ///
  /// In en, this message translates to:
  /// **'Cancel all'**
  String get sftpUploadCancelAllTooltip;

  /// No description provided for @sftpUploadOverwriteTitle.
  ///
  /// In en, this message translates to:
  /// **'Replace on server?'**
  String get sftpUploadOverwriteTitle;

  /// No description provided for @sftpUploadOverwriteBody.
  ///
  /// In en, this message translates to:
  /// **'“{name}” already exists on the server. Replace it? Remote files will be overwritten or removed.'**
  String sftpUploadOverwriteBody(String name);

  /// No description provided for @sftpUploadOverwriteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get sftpUploadOverwriteConfirm;

  /// No description provided for @sftpUploadConflictTypeMismatchTitle.
  ///
  /// In en, this message translates to:
  /// **'Cannot replace'**
  String get sftpUploadConflictTypeMismatchTitle;

  /// No description provided for @sftpUploadConflictTypeMismatchBody.
  ///
  /// In en, this message translates to:
  /// **'“{name}” does not match the type on the server (file vs folder). Remove the remote item first, then upload again.'**
  String sftpUploadConflictTypeMismatchBody(String name);

  /// No description provided for @sftpBinaryNotOpened.
  ///
  /// In en, this message translates to:
  /// **'This file looks binary; open in editor was cancelled.'**
  String get sftpBinaryNotOpened;

  /// No description provided for @sftpDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete?'**
  String get sftpDeleteConfirmTitle;

  /// No description provided for @sftpDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Delete “{name}”?'**
  String sftpDeleteConfirmBody(String name);

  /// No description provided for @sftpDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get sftpDeleteConfirm;

  /// No description provided for @sftpCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get sftpCancel;

  /// No description provided for @remoteEditorSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get remoteEditorSave;

  /// No description provided for @remoteEditorRemoteChanged.
  ///
  /// In en, this message translates to:
  /// **'The file on the server was modified by another process.'**
  String get remoteEditorRemoteChanged;

  /// No description provided for @remoteEditorReload.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get remoteEditorReload;

  /// No description provided for @remoteEditorIgnore.
  ///
  /// In en, this message translates to:
  /// **'Ignore'**
  String get remoteEditorIgnore;

  /// No description provided for @remoteEditorSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved to the server.'**
  String get remoteEditorSaved;

  /// No description provided for @remoteEditorSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed: {error}'**
  String remoteEditorSaveFailed(String error);

  /// No description provided for @statusNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get statusNotConnected;

  /// No description provided for @statusNoRemoteInfo.
  ///
  /// In en, this message translates to:
  /// **'Remote metrics unavailable'**
  String get statusNoRemoteInfo;

  /// No description provided for @statusPickHost.
  ///
  /// In en, this message translates to:
  /// **'Pick a host on the left and connect'**
  String get statusPickHost;

  /// No description provided for @statusBeijingTimeLabel.
  ///
  /// In en, this message translates to:
  /// **'Beijing'**
  String get statusBeijingTimeLabel;

  /// No description provided for @statusRemoteUptimePrefix.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get statusRemoteUptimePrefix;

  /// No description provided for @statusRemoteUptimeLine.
  ///
  /// In en, this message translates to:
  /// **'Remote: {uptime}'**
  String statusRemoteUptimeLine(String uptime);

  /// No description provided for @tooltipMemNoData.
  ///
  /// In en, this message translates to:
  /// **'Memory usage\n(no data)'**
  String get tooltipMemNoData;

  /// No description provided for @tooltipMem.
  ///
  /// In en, this message translates to:
  /// **'Memory usage\nAbout {percent}% (vs MemAvailable / MemTotal)'**
  String tooltipMem(String percent);

  /// No description provided for @tooltipCpuNoData.
  ///
  /// In en, this message translates to:
  /// **'CPU usage\n(no data; needs vmstat sampling)'**
  String get tooltipCpuNoData;

  /// No description provided for @tooltipCpu.
  ///
  /// In en, this message translates to:
  /// **'CPU usage\nAbout {percent}% (vmstat 1s sample)'**
  String tooltipCpu(String percent);

  /// No description provided for @tooltipDiskTitle.
  ///
  /// In en, this message translates to:
  /// **'Disk space on /'**
  String get tooltipDiskTitle;

  /// No description provided for @tooltipDiskUsed.
  ///
  /// In en, this message translates to:
  /// **'\nUsed: about {percent}%'**
  String tooltipDiskUsed(String percent);

  /// No description provided for @tooltipDiskNoUsage.
  ///
  /// In en, this message translates to:
  /// **'\nUsage: no data'**
  String get tooltipDiskNoUsage;

  /// No description provided for @tooltipInodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Inodes on /'**
  String get tooltipInodeTitle;

  /// No description provided for @tooltipInodeUsed.
  ///
  /// In en, this message translates to:
  /// **'\nUsed: about {percent}%'**
  String tooltipInodeUsed(String percent);

  /// No description provided for @tooltipInodeNoUsage.
  ///
  /// In en, this message translates to:
  /// **'\nUsage: no data'**
  String get tooltipInodeNoUsage;

  /// No description provided for @tooltipLoadTitle.
  ///
  /// In en, this message translates to:
  /// **'Load average'**
  String get tooltipLoadTitle;

  /// No description provided for @tooltipLoadLine.
  ///
  /// In en, this message translates to:
  /// **'\n1 / 5 / 15 min: {line}'**
  String tooltipLoadLine(String line);

  /// No description provided for @tooltipLoadNoData.
  ///
  /// In en, this message translates to:
  /// **'\n(no /proc/loadavg)'**
  String get tooltipLoadNoData;

  /// No description provided for @tooltipLoadPressure.
  ///
  /// In en, this message translates to:
  /// **'\nPressure vs CPU count: about {percent}%'**
  String tooltipLoadPressure(String percent);

  /// No description provided for @sshAuthFailKeyAndPassword.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed: the server rejected the key, or the key passphrase / SSH password is wrong. Double-check each.'**
  String get sshAuthFailKeyAndPassword;

  /// No description provided for @sshAuthFailKey.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed: the key does not match this account, or the key passphrase is wrong.'**
  String get sshAuthFailKey;

  /// No description provided for @sshAuthFailPassword.
  ///
  /// In en, this message translates to:
  /// **'Could not connect: wrong username or SSH password (authentication failed). If the server allows keys only, configure a key and avoid mixing passwords incorrectly.'**
  String get sshAuthFailPassword;

  /// No description provided for @sshAuthFailNone.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed: no SSH password and no usable private key.'**
  String get sshAuthFailNone;

  /// No description provided for @sshAuthAbort.
  ///
  /// In en, this message translates to:
  /// **'Authentication aborted: {message}'**
  String sshAuthAbort(String message);

  /// No description provided for @sshNotConnectedLikelyWrongPassword.
  ///
  /// In en, this message translates to:
  /// **'Could not connect: authentication did not finish before the connection closed. With password-only login, this usually means the username or SSH password is wrong (after double-checking, consider network issues or the server closing the session).'**
  String get sshNotConnectedLikelyWrongPassword;

  /// No description provided for @sshKeyDecode.
  ///
  /// In en, this message translates to:
  /// **'Could not parse private key or wrong passphrase: {message}'**
  String sshKeyDecode(String message);

  /// No description provided for @interfaceSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Interface'**
  String get interfaceSettingsTitle;

  /// No description provided for @interfaceThemeLabel.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get interfaceThemeLabel;

  /// No description provided for @interfaceThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get interfaceThemeDark;

  /// No description provided for @interfaceThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get interfaceThemeLight;

  /// No description provided for @interfaceThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'Match system'**
  String get interfaceThemeSystem;

  /// No description provided for @interfaceDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get interfaceDone;

  /// No description provided for @menuLlmSettings.
  ///
  /// In en, this message translates to:
  /// **'LLM & assistant…'**
  String get menuLlmSettings;

  /// No description provided for @llmSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Large language model'**
  String get llmSettingsTitle;

  /// No description provided for @llmSettingsHint.
  ///
  /// In en, this message translates to:
  /// **'Uses an OpenAI-compatible Chat Completions API. Base URL is usually `https://…/v1`, or paste a full URL ending with `/chat/completions`. The API key is stored only on this device.'**
  String get llmSettingsHint;

  /// No description provided for @llmBaseUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get llmBaseUrlLabel;

  /// No description provided for @llmBaseUrlHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. https://api.openai.com/v1'**
  String get llmBaseUrlHint;

  /// No description provided for @llmModelLabel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get llmModelLabel;

  /// No description provided for @llmModelHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. gpt-4o-mini'**
  String get llmModelHint;

  /// No description provided for @llmApiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'API key (optional)'**
  String get llmApiKeyLabel;

  /// No description provided for @llmApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Some local servers need no key'**
  String get llmApiKeyHint;

  /// No description provided for @llmToggleKeyVisibility.
  ///
  /// In en, this message translates to:
  /// **'Show / hide'**
  String get llmToggleKeyVisibility;

  /// No description provided for @llmTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get llmTestConnection;

  /// No description provided for @llmTestConnectionTooltip.
  ///
  /// In en, this message translates to:
  /// **'Send a minimal request to verify URL, model, and credentials'**
  String get llmTestConnectionTooltip;

  /// No description provided for @llmTestSuccess.
  ///
  /// In en, this message translates to:
  /// **'Connection test succeeded'**
  String get llmTestSuccess;

  /// No description provided for @llmTestFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection test failed: {error}'**
  String llmTestFailed(String error);

  /// No description provided for @llmMissingConfig.
  ///
  /// In en, this message translates to:
  /// **'Set base URL and model in LLM & assistant first.'**
  String get llmMissingConfig;

  /// No description provided for @assistantPanelTitle.
  ///
  /// In en, this message translates to:
  /// **'Assistant'**
  String get assistantPanelTitle;

  /// No description provided for @assistantExpandTooltip.
  ///
  /// In en, this message translates to:
  /// **'Expand assistant'**
  String get assistantExpandTooltip;

  /// No description provided for @assistantCollapseTooltip.
  ///
  /// In en, this message translates to:
  /// **'Collapse assistant'**
  String get assistantCollapseTooltip;

  /// No description provided for @assistantStopTooltip.
  ///
  /// In en, this message translates to:
  /// **'Stop generation'**
  String get assistantStopTooltip;

  /// No description provided for @assistantClearTooltip.
  ///
  /// In en, this message translates to:
  /// **'Clear chat'**
  String get assistantClearTooltip;

  /// No description provided for @assistantClearConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear chat?'**
  String get assistantClearConfirmTitle;

  /// No description provided for @assistantClearConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'Removes messages in this chat (system prompt is kept).'**
  String get assistantClearConfirmBody;

  /// No description provided for @assistantClearConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get assistantClearConfirm;

  /// No description provided for @assistantSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get assistantSend;

  /// No description provided for @assistantInputHint.
  ///
  /// In en, this message translates to:
  /// **'Type a message… (Enter for newline; send with Ctrl+Enter on Windows/Linux, ⌘+Enter on macOS)'**
  String get assistantInputHint;

  /// No description provided for @assistantThinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking…'**
  String get assistantThinking;

  /// No description provided for @assistantNotConnected.
  ///
  /// In en, this message translates to:
  /// **'No connected session (or this tab is offline): terminal tools cannot inject commands; you can still discuss usage.'**
  String get assistantNotConnected;

  /// No description provided for @assistantToolRunning.
  ///
  /// In en, this message translates to:
  /// **'Calling tools: {names}'**
  String assistantToolRunning(String names);

  /// No description provided for @assistantTerminalApprovalTitle.
  ///
  /// In en, this message translates to:
  /// **'Terminal command'**
  String get assistantTerminalApprovalTitle;

  /// No description provided for @assistantTerminalApprovalSubtitle.
  ///
  /// In en, this message translates to:
  /// **'The assistant will send the content below to your SSH session, as if you typed it in that terminal (including newlines and escapes). Only run it if you trust the action.'**
  String get assistantTerminalApprovalSubtitle;

  /// No description provided for @assistantTerminalCommandSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Payload'**
  String get assistantTerminalCommandSectionTitle;

  /// No description provided for @assistantTerminalSecurityHint.
  ///
  /// In en, this message translates to:
  /// **'Untrusted commands can change or delete remote files, burn resources, or leak environment details.'**
  String get assistantTerminalSecurityHint;

  /// No description provided for @assistantTerminalDeny.
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get assistantTerminalDeny;

  /// No description provided for @assistantTerminalAllowExecute.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get assistantTerminalAllowExecute;

  /// No description provided for @assistantReasoningHeader.
  ///
  /// In en, this message translates to:
  /// **'Reasoning'**
  String get assistantReasoningHeader;

  /// No description provided for @assistantAnswerHeader.
  ///
  /// In en, this message translates to:
  /// **'Answer'**
  String get assistantAnswerHeader;

  /// No description provided for @assistantUserHeader.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get assistantUserHeader;

  /// No description provided for @assistantReasoningExpand.
  ///
  /// In en, this message translates to:
  /// **'Show reasoning'**
  String get assistantReasoningExpand;

  /// No description provided for @assistantReasoningCollapse.
  ///
  /// In en, this message translates to:
  /// **'Hide reasoning'**
  String get assistantReasoningCollapse;

  /// No description provided for @assistantToolResultHeader.
  ///
  /// In en, this message translates to:
  /// **'Terminal output'**
  String get assistantToolResultHeader;

  /// No description provided for @assistantToolResultEmpty.
  ///
  /// In en, this message translates to:
  /// **'(No terminal output)'**
  String get assistantToolResultEmpty;

  /// No description provided for @menuCheckForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates…'**
  String get menuCheckForUpdates;

  /// No description provided for @updateChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking for updates…'**
  String get updateChecking;

  /// No description provided for @updateAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get updateAvailableTitle;

  /// No description provided for @updateAvailableMessage.
  ///
  /// In en, this message translates to:
  /// **'Version {version} is available on GitHub.'**
  String updateAvailableMessage(String version);

  /// No description provided for @updateReleaseNotes.
  ///
  /// In en, this message translates to:
  /// **'Release notes'**
  String get updateReleaseNotes;

  /// No description provided for @updateDownloadInstall.
  ///
  /// In en, this message translates to:
  /// **'Download and install'**
  String get updateDownloadInstall;

  /// No description provided for @updateLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get updateLater;

  /// No description provided for @updateSkipVersion.
  ///
  /// In en, this message translates to:
  /// **'Skip this version'**
  String get updateSkipVersion;

  /// No description provided for @updateDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading… {percent}%'**
  String updateDownloading(int percent);

  /// No description provided for @updateInstalling.
  ///
  /// In en, this message translates to:
  /// **'Installing… the app will restart.'**
  String get updateInstalling;

  /// No description provided for @updateUpToDateTitle.
  ///
  /// In en, this message translates to:
  /// **'You\'re up to date'**
  String get updateUpToDateTitle;

  /// No description provided for @updateUpToDateMessage.
  ///
  /// In en, this message translates to:
  /// **'EasyTerm is already on the latest release.'**
  String get updateUpToDateMessage;

  /// No description provided for @updateErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Update failed'**
  String get updateErrorTitle;

  /// No description provided for @updateError.
  ///
  /// In en, this message translates to:
  /// **'{error}'**
  String updateError(String error);

  /// No description provided for @updateErrorUnknown.
  ///
  /// In en, this message translates to:
  /// **'Could not check for updates.'**
  String get updateErrorUnknown;

  /// No description provided for @updateRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get updateRetry;

  /// No description provided for @updateUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Automatic updates are only available on macOS and Windows.'**
  String get updateUnsupported;

  /// No description provided for @updateOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get updateOk;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
