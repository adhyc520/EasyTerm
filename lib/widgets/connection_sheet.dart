import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/connection_protocol.dart';
import '../models/proxy_config.dart';
import '../models/serial_port_config.dart';
import '../services/terminal_charset.dart';
import '../services/serial/serial_transport.dart';
import '../models/saved_host_profile.dart';
import '../services/host_profiles_store.dart';
import '../theme/workbench_theme.dart';
import '../services/ssh_workspace_controller.dart';

enum _ConnectionAuthMode { password, privateKey }

class ConnectionLaunch {
  ConnectionLaunch({
    this.protocol = ConnectionProtocol.ssh,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.privateKeyPem,
    this.keyPath,
    this.deviceLabel,
    this.existingProfileId,
    this.proxyConfig,
    this.connectTimeoutSec,
    this.encoding,
    this.serialConfig,
    this.autoInjectCredentials = true,
  });

  final ConnectionProtocol protocol;
  final String host;
  final int port;
  final String username;
  final String password;
  final String? privateKeyPem;
  final String? keyPath;
  final String? deviceLabel;

  /// 非空表示在保存到侧边栏时应更新该 id 的条目，而非新建。
  final String? existingProfileId;

  /// 跳板机 / SOCKS5 / HTTP 代理。
  final ProxyConfig? proxyConfig;

  /// 可选覆盖连接超时（秒）。
  final int? connectTimeoutSec;

  final TerminalEncoding? encoding;
  final SerialPortConfig? serialConfig;
  final bool autoInjectCredentials;
}

/// 新建或修改主机（完整表单）；已保存列表仅在主页展示，此处不再重复。
///
/// [editingProfile] 非空时为修改模式，提交后 [ConnectionLaunch.existingProfileId] 为该配置 id。
Future<ConnectionLaunch?> showNewHostSheet(
  BuildContext context, {
  SavedHostProfile? editingProfile,
  HostProfilesStore? profiles,
}) {
  return showModalBottomSheet<ConnectionLaunch>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _NewHostSheetBody(
      editingProfile: editingProfile,
      profiles: profiles,
    ),
  );
}

class _NewHostSheetBody extends StatefulWidget {
  const _NewHostSheetBody({this.editingProfile, this.profiles});

  final SavedHostProfile? editingProfile;
  final HostProfilesStore? profiles;

  @override
  State<_NewHostSheetBody> createState() => _NewHostSheetBodyState();
}

class _NewHostSheetBodyState extends State<_NewHostSheetBody> {
  late final TextEditingController _label = TextEditingController();
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _sshPassword;
  late final TextEditingController _keyPassphrase;
  late final TextEditingController _keyPath;
  late final TextEditingController _connectTimeout;
  late _ConnectionAuthMode _authMode;
  String? _jumpProfileId;
  bool _advancedOpen = false;
  /// Telnet: none / socks5 / http (SSH uses jump profile instead).
  ProxyType? _tcpProxyType;
  late final TextEditingController _proxyHost;
  late final TextEditingController _proxyPort;
  late final TextEditingController _proxyUser;
  late final TextEditingController _proxyPassword;

  /// 底部弹层出现时，底层 [TerminalView]（hardware keyboard Focus）仍可能占着焦点，Mac 上按键进不了表单。
  final FocusNode _firstFieldFocus = FocusNode();
  bool _busy = false;
  ConnectionProtocol _protocol = ConnectionProtocol.ssh;
  TerminalEncoding _encoding = TerminalEncoding.utf8;
  bool _autoInject = true;
  List<String> _serialPorts = const [];
  String? _serialPortName;
  int _baudRate = 115200;
  int _dataBits = 8;
  SerialParity _parity = SerialParity.none;
  int _stopBits = 1;
  SerialFlowControl _flowControl = SerialFlowControl.none;

  @override
  void initState() {
    super.initState();
    final p = widget.editingProfile;
    _protocol = p?.protocol ?? ConnectionProtocol.ssh;
    _encoding = p?.encoding ?? TerminalEncoding.utf8;
    _autoInject = p?.autoInjectCredentials ?? true;
    final sc = p?.serialConfig;
    if (sc != null) {
      _serialPortName = sc.name;
      _baudRate = sc.baudRate;
      _dataBits = sc.dataBits;
      _parity = sc.parity;
      _stopBits = sc.stopBits;
      _flowControl = sc.flowControl;
    }
    _host = TextEditingController(text: p?.host ?? '');
    _port = TextEditingController(
      text: (p?.port ?? _protocol.defaultPort).toString(),
    );
    _user = TextEditingController(text: p?.username ?? '');
    _connectTimeout = TextEditingController(text: '30');
    _proxyHost = TextEditingController();
    _proxyPort = TextEditingController(text: '1080');
    _proxyUser = TextEditingController();
    _proxyPassword = TextEditingController();
    final savedKeyPath = (p?.keyPath ?? '').trim();
    final hasKeyPath = savedKeyPath.isNotEmpty;
    _authMode = hasKeyPath
        ? _ConnectionAuthMode.privateKey
        : _ConnectionAuthMode.password;
    if (hasKeyPath) {
      _sshPassword = TextEditingController();
      _keyPassphrase = TextEditingController(text: p!.password ?? '');
      _keyPath = TextEditingController(text: savedKeyPath);
    } else {
      _sshPassword = TextEditingController(text: p?.password ?? '');
      _keyPassphrase = TextEditingController();
      _keyPath = TextEditingController();
    }
    if (p != null) {
      _label.text = p.label;
      final proxy = p.proxyConfig;
      if (proxy != null) {
        _advancedOpen = true;
        if (proxy.type == ProxyType.socks5 || proxy.type == ProxyType.http) {
          _tcpProxyType = proxy.type;
          _proxyHost.text = proxy.host;
          _proxyPort.text = '${proxy.port}';
          _proxyUser.text = proxy.username;
          _proxyPassword.text = proxy.password ?? '';
        } else {
          final store = widget.profiles;
          if (store != null) {
            for (final other in store.profiles) {
              if (other.id == p.id) continue;
              if (other.matchesEndpoint(
                host: proxy.host,
                port: proxy.port,
                username: proxy.username,
              )) {
                _jumpProfileId = other.id;
                break;
              }
            }
          }
        }
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _firstFieldFocus.requestFocus();
      unawaited(_refreshSerialPorts());
    });
  }

  Future<void> _refreshSerialPorts() async {
    final ports = await SerialTransport.availablePorts();
    if (!mounted) return;
    setState(() {
      _serialPorts = ports;
      if (_serialPortName == null && ports.isNotEmpty) {
        _serialPortName = ports.first;
      }
    });
  }

  void _onProtocolChanged(ConnectionProtocol next) {
    if (_protocol == next) return;
    setState(() {
      _protocol = next;
      if (widget.editingProfile == null) {
        _port.text = next.defaultPort > 0 ? '${next.defaultPort}' : '115200';
      }
    });
    if (next == ConnectionProtocol.serial) {
      unawaited(_refreshSerialPorts());
    }
  }

  @override
  void dispose() {
    _firstFieldFocus.dispose();
    _label.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _sshPassword.dispose();
    _keyPassphrase.dispose();
    _keyPath.dispose();
    _connectTimeout.dispose();
    _proxyHost.dispose();
    _proxyPort.dispose();
    _proxyUser.dispose();
    _proxyPassword.dispose();
    super.dispose();
  }

  Future<void> _pickKeyFile() async {
    final l = AppLocalizations.of(context)!;
    try {
      // 不与 BottomSheet 同一帧争抢模态面板（尤其 macOS 上更稳）。
      await Future<void>.delayed(Duration.zero);
      final r = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        lockParentWindow:
            !kIsWeb && defaultTargetPlatform == TargetPlatform.windows,
      );
      if (!mounted) return;
      if (r == null || r.files.isEmpty) return;
      final path = r.files.single.path;
      if (path != null && path.isNotEmpty) {
        setState(() => _keyPath.text = path);
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      final detail = [
        if (e.code.isNotEmpty) e.code,
        if (e.message != null && e.message!.trim().isNotEmpty)
          e.message!.trim(),
      ].join(': ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l.connectionPickKeyFailed(detail.isEmpty ? '$e' : detail),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.connectionPickKeyFailed('$e'))));
    }
  }

  Future<void> _submit() async {
    final l = AppLocalizations.of(context)!;
    final edit = widget.editingProfile;

    if (_protocol == ConnectionProtocol.serial) {
      final name = (_serialPortName ?? _host.text).trim();
      if (name.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请选择串口')),
        );
        return;
      }
      final cfg = SerialPortConfig(
        name: name,
        baudRate: _baudRate,
        dataBits: _dataBits,
        parity: _parity,
        stopBits: _stopBits,
        flowControl: _flowControl,
      );
      Navigator.of(context).pop(
        ConnectionLaunch(
          protocol: ConnectionProtocol.serial,
          host: name,
          port: _baudRate,
          username: '',
          password: '',
          deviceLabel: _label.text.trim().isEmpty ? null : _label.text.trim(),
          existingProfileId: edit?.id,
          encoding: _encoding,
          serialConfig: cfg,
        ),
      );
      return;
    }

    final host = _host.text.trim();
    final user = _user.text.trim();
    final defaultPort = _protocol.defaultPort;
    final port = int.tryParse(_port.text.trim()) ?? defaultPort;

    if (_protocol == ConnectionProtocol.ssh) {
      if (host.isEmpty || user.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.connectionMissingHostUser)),
        );
        return;
      }
    } else {
      // Telnet
      if (host.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请填写主机地址')),
        );
        return;
      }
    }

    setState(() => _busy = true);
    String passwordForLaunch = '';
    String? keyPathForLaunch;
    String? pem;
    try {
      if (_protocol == ConnectionProtocol.telnet) {
        passwordForLaunch = _sshPassword.text;
        keyPathForLaunch = null;
        pem = null;
      } else if (_authMode == _ConnectionAuthMode.password) {
        passwordForLaunch = _sshPassword.text;
        keyPathForLaunch = null;
        pem = null;
      } else {
        final kp = _keyPath.text.trim();
        if (kp.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l.connectionMissingKeyPath)),
            );
            setState(() => _busy = false);
          }
          return;
        }
        pem = await loadPrivateKeyFromPath(kp);
        if (pem == null || pem.trim().isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l.connectionPrivateKeyEmpty)),
            );
            setState(() => _busy = false);
          }
          return;
        }
        passwordForLaunch = _keyPassphrase.text;
        keyPathForLaunch = kp;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.snackbarPrivateKeyReadFailed('$e'))),
        );
      }
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    ProxyConfig? proxy;
    final jumpId = _jumpProfileId;
    final store = widget.profiles;
    if (_protocol == ConnectionProtocol.ssh &&
        jumpId != null &&
        store != null) {
      SavedHostProfile? jump;
      for (final other in store.profiles) {
        if (other.id == jumpId) {
          jump = other;
          break;
        }
      }
      if (jump != null) {
        String? jumpPem;
        try {
          jumpPem = await loadPrivateKeyFromPath(jump.keyPath);
        } catch (_) {}
        if (!mounted) return;
        proxy = ProxyConfig(
          type: ProxyType.sshJump,
          host: jump.host,
          port: jump.port,
          username: jump.username,
          password: jump.password,
          keyPath: jump.keyPath,
          // 仅内存；持久化走 keyPath，不会写入 JSON。
          privateKeyPem: jumpPem,
        );
      }
    } else if (_protocol == ConnectionProtocol.telnet &&
        (_tcpProxyType == ProxyType.socks5 ||
            _tcpProxyType == ProxyType.http)) {
      final ph = _proxyHost.text.trim();
      final pp = int.tryParse(_proxyPort.text.trim()) ??
          (_tcpProxyType == ProxyType.http ? 8080 : 1080);
      if (ph.isNotEmpty) {
        proxy = ProxyConfig(
          type: _tcpProxyType!,
          host: ph,
          port: pp,
          username: _proxyUser.text.trim(),
          password: _proxyPassword.text,
        );
      }
    }

    if (!mounted) return;
    final timeout = int.tryParse(_connectTimeout.text.trim());
    Navigator.of(context).pop(
      ConnectionLaunch(
        protocol: _protocol,
        host: host,
        port: port,
        username: user,
        password: passwordForLaunch,
        privateKeyPem: pem,
        keyPath: keyPathForLaunch,
        deviceLabel: _label.text.trim().isEmpty ? null : _label.text.trim(),
        existingProfileId: edit?.id,
        proxyConfig: proxy,
        connectTimeoutSec: timeout,
        encoding: _protocol == ConnectionProtocol.telnet ? _encoding : null,
        autoInjectCredentials:
            _protocol == ConnectionProtocol.telnet ? _autoInject : true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final wb = context.wb;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final editing = widget.editingProfile != null;
    // 与顶栏标题同级，避免默认 titleLarge 偏大。
    final sheetTitleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      color: wb.primaryText,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    );
    final fieldStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: wb.primaryText);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 8,
        bottom: 16 + bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              editing ? l.connectionEditTitle : l.connectionNewTitle,
              style: sheetTitleStyle,
            ),
            const SizedBox(height: 12),
            SegmentedButton<ConnectionProtocol>(
              segments: const [
                ButtonSegment(
                  value: ConnectionProtocol.ssh,
                  label: Text('SSH'),
                  icon: Icon(Icons.terminal, size: 16),
                ),
                ButtonSegment(
                  value: ConnectionProtocol.telnet,
                  label: Text('Telnet'),
                  icon: Icon(Icons.lan_outlined, size: 16),
                ),
                ButtonSegment(
                  value: ConnectionProtocol.serial,
                  label: Text('Serial'),
                  icon: Icon(Icons.cable, size: 16),
                ),
              ],
              selected: {_protocol},
              onSelectionChanged: (s) => _onProtocolChanged(s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              focusNode: _firstFieldFocus,
              controller: _label,
              style: fieldStyle,
              decoration: InputDecoration(
                labelText: l.connectionDeviceNameLabel,
                hintText: l.connectionDeviceNameHint,
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 10),
            if (_protocol == ConnectionProtocol.serial) ...[
              DropdownButtonFormField<String>(
                // ignore: deprecated_member_use
                value: _serialPorts.contains(_serialPortName)
                    ? _serialPortName
                    : null,
                decoration: const InputDecoration(labelText: '串口'),
                items: [
                  for (final p in _serialPorts)
                    DropdownMenuItem(value: p, child: Text(p)),
                ],
                onChanged: (v) => setState(() => _serialPortName = v),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                // ignore: deprecated_member_use
                value: _baudRate,
                decoration: const InputDecoration(labelText: '波特率'),
                items: [
                  for (final b in [9600, 19200, 38400, 57600, 115200, 230400])
                    DropdownMenuItem(value: b, child: Text('$b')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _baudRate = v);
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      // ignore: deprecated_member_use
                      value: _dataBits,
                      decoration: const InputDecoration(labelText: '数据位'),
                      items: [
                        for (final b in [5, 6, 7, 8])
                          DropdownMenuItem(value: b, child: Text('$b')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _dataBits = v);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<SerialParity>(
                      // ignore: deprecated_member_use
                      value: _parity,
                      decoration: const InputDecoration(labelText: '校验'),
                      items: [
                        for (final p in SerialParity.values)
                          DropdownMenuItem(value: p, child: Text(p.name)),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _parity = v);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      // ignore: deprecated_member_use
                      value: _stopBits,
                      decoration: const InputDecoration(labelText: '停止位'),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1')),
                        DropdownMenuItem(value: 2, child: Text('2')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _stopBits = v);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<SerialFlowControl>(
                      // ignore: deprecated_member_use
                      value: _flowControl,
                      decoration: const InputDecoration(labelText: '流控'),
                      items: [
                        for (final f in SerialFlowControl.values)
                          DropdownMenuItem(value: f, child: Text(f.name)),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _flowControl = v);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<TerminalEncoding>(
                // ignore: deprecated_member_use
                value: _encoding,
                decoration: const InputDecoration(labelText: '字符集'),
                items: [
                  for (final e in TerminalEncoding.values)
                    DropdownMenuItem(value: e, child: Text(e.displayName)),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _encoding = v);
                },
              ),
            ] else ...[
              TextField(
                controller: _host,
                style: fieldStyle,
                decoration: InputDecoration(
                  labelText: l.connectionHostLabel,
                  hintText: l.connectionHostHint,
                ),
                textInputAction: TextInputAction.next,
                autocorrect: false,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _port,
                style: fieldStyle,
                decoration: InputDecoration(labelText: l.connectionPortLabel),
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
              ),
              if (_protocol == ConnectionProtocol.ssh ||
                  _protocol == ConnectionProtocol.telnet) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _user,
                  style: fieldStyle,
                  decoration: InputDecoration(
                    labelText: _protocol == ConnectionProtocol.telnet
                        ? '用户名（可选）'
                        : l.connectionUserLabel,
                  ),
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                ),
              ],
              if (_protocol == ConnectionProtocol.telnet) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _sshPassword,
                  style: fieldStyle,
                  decoration: const InputDecoration(
                    labelText: '密码（可选，自动注入）',
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<TerminalEncoding>(
                  // ignore: deprecated_member_use
                  value: _encoding,
                  decoration: const InputDecoration(labelText: '字符集'),
                  items: [
                    for (final e in TerminalEncoding.values)
                      DropdownMenuItem(value: e, child: Text(e.displayName)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _encoding = v);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动注入登录凭据'),
                  value: _autoInject,
                  onChanged: (v) => setState(() => _autoInject = v),
                ),
              ],
              if (_protocol == ConnectionProtocol.ssh) ...[
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l.connectionAuthMethodLabel,
                    style: fieldStyle?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 360;
                    return SegmentedButton<_ConnectionAuthMode>(
                      segments: [
                        ButtonSegment<_ConnectionAuthMode>(
                          value: _ConnectionAuthMode.password,
                          icon: Icon(
                            Icons.password_rounded,
                            size: 18,
                            color: wb.textMuted,
                          ),
                          label: narrow
                              ? null
                              : Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 6),
                                  child: Text(l.connectionAuthPassword),
                                ),
                          tooltip: l.connectionAuthPassword,
                        ),
                        ButtonSegment<_ConnectionAuthMode>(
                          value: _ConnectionAuthMode.privateKey,
                          icon: Icon(
                            Icons.key_rounded,
                            size: 18,
                            color: wb.textMuted,
                          ),
                          label: narrow
                              ? null
                              : Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 6),
                                  child: Text(l.connectionAuthPrivateKey),
                                ),
                          tooltip: l.connectionAuthPrivateKey,
                        ),
                      ],
                      selected: {_authMode},
                      onSelectionChanged: (next) {
                        setState(() => _authMode = next.first);
                      },
                    );
                  },
                ),
                const SizedBox(height: 12),
                if (_authMode == _ConnectionAuthMode.password) ...[
                  TextField(
                    controller: _sshPassword,
                    style: fieldStyle,
                    decoration: InputDecoration(
                      labelText: l.connectionSshPasswordLabel,
                      hintText:
                          editing ? l.connectionSshPasswordHintEdit : null,
                    ),
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!_busy) _submit();
                    },
                  ),
                ] else ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _keyPath,
                          style:
                              fieldStyle?.copyWith(fontFamily: 'monospace'),
                          decoration: InputDecoration(
                            labelText: l.connectionKeyPathLabel,
                            hintText: l.connectionKeyPathHint,
                          ),
                          autocorrect: false,
                          textInputAction: TextInputAction.next,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: l.connectionPickKeyTooltip,
                        onPressed: _pickKeyFile,
                        icon: const Icon(Icons.folder_open_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _keyPassphrase,
                    style: fieldStyle,
                    decoration: InputDecoration(
                      labelText: l.connectionKeyPassphraseLabel,
                      hintText:
                          editing ? l.connectionKeyPassphraseHintEdit : null,
                    ),
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!_busy) _submit();
                    },
                  ),
                ],
              ],
            ],
            if (_protocol != ConnectionProtocol.serial) ...[
            const SizedBox(height: 12),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: _advancedOpen,
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(
                  '高级',
                  style: fieldStyle?.copyWith(fontWeight: FontWeight.w600),
                ),
                onExpansionChanged: (v) => _advancedOpen = v,
                children: [
                  if (_protocol == ConnectionProtocol.ssh)
                    Builder(
                      builder: (context) {
                        final store = widget.profiles;
                        final jumpOptions = <DropdownMenuItem<String?>>[
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text('无'),
                          ),
                        ];
                        if (store != null) {
                          final editingId = widget.editingProfile?.id;
                          for (final other in store.profiles) {
                            if (other.id == editingId) continue;
                            jumpOptions.add(
                              DropdownMenuItem<String?>(
                                value: other.id,
                                child: Text(
                                  '${other.label} (${other.subtitle})',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            );
                          }
                        }
                        return DropdownButtonFormField<String?>(
                          // ignore: deprecated_member_use
                          value: _jumpProfileId,
                          decoration: const InputDecoration(
                            labelText: '跳板机',
                          ),
                          items: jumpOptions,
                          onChanged: (v) => setState(() => _jumpProfileId = v),
                        );
                      },
                    ),
                  if (_protocol == ConnectionProtocol.ssh)
                    const SizedBox(height: 10),
                  if (_protocol == ConnectionProtocol.telnet) ...[
                    DropdownButtonFormField<ProxyType?>(
                      // ignore: deprecated_member_use
                      value: _tcpProxyType,
                      decoration: const InputDecoration(
                        labelText: 'TCP 代理',
                      ),
                      items: const [
                        DropdownMenuItem<ProxyType?>(
                          value: null,
                          child: Text('无'),
                        ),
                        DropdownMenuItem<ProxyType?>(
                          value: ProxyType.socks5,
                          child: Text('SOCKS5'),
                        ),
                        DropdownMenuItem<ProxyType?>(
                          value: ProxyType.http,
                          child: Text('HTTP CONNECT'),
                        ),
                      ],
                      onChanged: (v) => setState(() {
                        _tcpProxyType = v;
                        if (v == ProxyType.http &&
                            (_proxyPort.text.trim().isEmpty ||
                                _proxyPort.text.trim() == '1080')) {
                          _proxyPort.text = '8080';
                        } else if (v == ProxyType.socks5 &&
                            (_proxyPort.text.trim().isEmpty ||
                                _proxyPort.text.trim() == '8080')) {
                          _proxyPort.text = '1080';
                        }
                      }),
                    ),
                    if (_tcpProxyType != null) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: _proxyHost,
                        style: fieldStyle,
                        decoration: const InputDecoration(
                          labelText: '代理主机',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _proxyPort,
                        style: fieldStyle,
                        decoration: const InputDecoration(
                          labelText: '代理端口',
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _proxyUser,
                        style: fieldStyle,
                        decoration: const InputDecoration(
                          labelText: '代理用户名（可选）',
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _proxyPassword,
                        style: fieldStyle,
                        decoration: const InputDecoration(
                          labelText: '代理密码（可选）',
                        ),
                        obscureText: true,
                      ),
                    ],
                    const SizedBox(height: 10),
                  ],
                  TextField(
                    controller: _connectTimeout,
                    style: fieldStyle,
                    decoration: const InputDecoration(
                      labelText: '连接超时（秒）',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
            ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: _busy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        editing
                            ? l.connectionSubmitSave
                            : l.connectionSubmitConnect,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
