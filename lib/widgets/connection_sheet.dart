import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../models/saved_host_profile.dart';
import '../theme/workbench_theme.dart';
import '../services/ssh_workspace_controller.dart';

enum _ConnectionAuthMode { password, privateKey }

class ConnectionLaunch {
  ConnectionLaunch({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.privateKeyPem,
    this.keyPath,
    this.deviceLabel,
    this.existingProfileId,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String? privateKeyPem;
  final String? keyPath;
  final String? deviceLabel;

  /// 非空表示在保存到侧边栏时应更新该 id 的条目，而非新建。
  final String? existingProfileId;
}

/// 新建或修改主机（完整表单）；已保存列表仅在主页展示，此处不再重复。
///
/// [editingProfile] 非空时为修改模式，提交后 [ConnectionLaunch.existingProfileId] 为该配置 id。
Future<ConnectionLaunch?> showNewHostSheet(
  BuildContext context, {
  SavedHostProfile? editingProfile,
}) {
  return showModalBottomSheet<ConnectionLaunch>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _NewHostSheetBody(editingProfile: editingProfile),
  );
}

class _NewHostSheetBody extends StatefulWidget {
  const _NewHostSheetBody({this.editingProfile});

  final SavedHostProfile? editingProfile;

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
  late _ConnectionAuthMode _authMode;

  /// 底部弹层出现时，底层 [TerminalView]（hardware keyboard Focus）仍可能占着焦点，Mac 上按键进不了表单。
  final FocusNode _firstFieldFocus = FocusNode();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final p = widget.editingProfile;
    _host = TextEditingController(text: p?.host ?? '');
    _port = TextEditingController(text: (p?.port ?? 22).toString());
    _user = TextEditingController(text: p?.username ?? '');
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
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _firstFieldFocus.requestFocus();
    });
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
    final host = _host.text.trim();
    final user = _user.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 22;
    if (host.isEmpty || user.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.connectionMissingHostUser)));
      return;
    }

    setState(() => _busy = true);
    String passwordForLaunch;
    String? keyPathForLaunch;
    String? pem;
    try {
      if (_authMode == _ConnectionAuthMode.password) {
        passwordForLaunch = _sshPassword.text;
        keyPathForLaunch = null;
        pem = null;
      } else {
        final kp = _keyPath.text.trim();
        if (kp.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(l.connectionMissingKeyPath)));
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

    final edit = widget.editingProfile;
    Navigator.of(context).pop(
      ConnectionLaunch(
        host: host,
        port: port,
        username: user,
        password: passwordForLaunch,
        privateKeyPem: pem,
        keyPath: keyPathForLaunch,
        deviceLabel: _label.text.trim().isEmpty ? null : _label.text.trim(),
        existingProfileId: edit?.id,
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
            const SizedBox(height: 10),
            TextField(
              controller: _user,
              style: fieldStyle,
              decoration: InputDecoration(labelText: l.connectionUserLabel),
              textInputAction: TextInputAction.next,
              autocorrect: false,
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l.connectionAuthMethodLabel,
                style: fieldStyle?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<_ConnectionAuthMode>(
                    segments: [
                      ButtonSegment<_ConnectionAuthMode>(
                        value: _ConnectionAuthMode.password,
                        icon: Icon(
                          Icons.password_rounded,
                          size: 18,
                          color: wb.textMuted,
                        ),
                        label: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(l.connectionAuthPassword),
                        ),
                      ),
                      ButtonSegment<_ConnectionAuthMode>(
                        value: _ConnectionAuthMode.privateKey,
                        icon: Icon(
                          Icons.key_rounded,
                          size: 18,
                          color: wb.textMuted,
                        ),
                        label: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(l.connectionAuthPrivateKey),
                        ),
                      ),
                    ],
                    selected: {_authMode},
                    onSelectionChanged: (next) {
                      setState(() => _authMode = next.first);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_authMode == _ConnectionAuthMode.password) ...[
              TextField(
                controller: _sshPassword,
                style: fieldStyle,
                decoration: InputDecoration(
                  labelText: l.connectionSshPasswordLabel,
                  hintText: editing ? l.connectionSshPasswordHintEdit : null,
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
                      style: fieldStyle?.copyWith(fontFamily: 'monospace'),
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
                  hintText: editing ? l.connectionKeyPassphraseHintEdit : null,
                ),
                obscureText: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!_busy) _submit();
                },
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
