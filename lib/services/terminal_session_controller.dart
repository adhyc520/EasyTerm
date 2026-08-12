import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../models/connection_protocol.dart';
import '../models/proxy_config.dart';
import 'session_recorder.dart';

/// Capability bits a remote session may expose.
enum RemoteCapability { terminal, exec, file, forward }

/// Shared surface for desktop secondary shells (SSH PTY / Telnet TCP).
abstract class SecondaryShell extends ChangeNotifier {
  Terminal get terminal;
  bool get mouseModeActive;
  String get terminalCwd;
  bool get sawOsc7;
  void resize(int w, int h, int pw, int ph);
  void paste(String s);
  Future<void> close();
}

/// Terminal session contract (SSH / Telnet / Serial).
abstract class TerminalSessionController extends ChangeNotifier {
  ConnectionProtocol get protocol;
  String get host;
  int get port;
  String get username;
  Set<RemoteCapability> get capabilities;

  /// Optional password (SSH auth / Telnet login inject). Empty when unused.
  String get password;
  ProxyConfig? get proxyConfig;

  Terminal? get terminal;
  bool get connecting;
  bool get connected;
  bool get dropped;
  String? get error;
  String get terminalCwd;
  bool get mouseModeActive;

  /// Display label for tabs / status (protocol-aware).
  String get sessionLabel;

  SessionRecorder? get sessionRecorder;
  bool get isSessionRecording;
  void startSessionRecording();
  void stopSessionRecording();
  void toggleSessionRecording();

  Future<void> connect();
  Future<void> disconnect();
  Future<void> reconnect();

  void pasteRemoteInput(String text);
  String pasteRemoteInputWithLineSubmit(String text);
  String snapshotTerminalTail({int maxLines = 120, int maxChars = 24000});
  void injectTerminalLocalDisplay(String text);

  /// Opens an independent secondary shell for desktop multi-terminal.
  /// Returns null when unsupported (Serial).
  Future<SecondaryShell?> openSecondaryShell({int? cols, int? rows});

  @override
  void dispose();
}

/// Legacy alias — SSH [RemoteShell] is a [SecondaryShell].
typedef OpenSecondaryShell = Future<SecondaryShell?> Function();
