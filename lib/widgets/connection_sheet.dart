import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/saved_host_profile.dart';
import '../theme/workbench_theme.dart';
import '../services/ssh_workspace_controller.dart';

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
  late final TextEditingController _password;
  late final TextEditingController _keyPath;
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
    _password = TextEditingController(text: p?.password ?? '');
    _keyPath = TextEditingController(text: p?.keyPath ?? '');
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
    _password.dispose();
    _keyPath.dispose();
    super.dispose();
  }

  Future<void> _pickKeyFile() async {
    final r = await FilePicker.pickFiles();
    if (r == null || r.files.isEmpty) return;
    final path = r.files.single.path;
    if (path != null && path.isNotEmpty) {
      setState(() => _keyPath.text = path);
    }
  }

  Future<void> _submit() async {
    final host = _host.text.trim();
    final user = _user.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 22;
    if (host.isEmpty || user.isEmpty) {
      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.connectionMissingHostUser)));
      return;
    }

    setState(() => _busy = true);
    final pem = await loadPrivateKeyFromPath(_keyPath.text.trim().isEmpty ? null : _keyPath.text);
    if (!mounted) return;
    setState(() => _busy = false);

    final edit = widget.editingProfile;
    Navigator.of(context).pop(
      ConnectionLaunch(
        host: host,
        port: port,
        username: user,
        password: _password.text,
        privateKeyPem: pem,
        keyPath: _keyPath.text.trim().isEmpty ? null : _keyPath.text.trim(),
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
    final fieldStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(color: wb.primaryText);
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 8, bottom: 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(editing ? l.connectionEditTitle : l.connectionNewTitle, style: sheetTitleStyle),
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
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              style: fieldStyle,
              decoration: InputDecoration(
                labelText: l.connectionPasswordLabel,
                hintText: editing ? l.connectionPasswordHintEdit : null,
              ),
              obscureText: true,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 10),
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
                    : Text(editing ? l.connectionSubmitSave : l.connectionSubmitConnect),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
