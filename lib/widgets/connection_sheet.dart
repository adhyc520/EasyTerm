import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../models/saved_host_profile.dart';
import '../services/ssh_workspace_controller.dart';

class ConnectionLaunch {
  ConnectionLaunch({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.privateKeyPem,
    this.keyPath,
    this.saveAsDevice = false,
    this.deviceLabel,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String? privateKeyPem;
  final String? keyPath;
  final bool saveAsDevice;
  final String? deviceLabel;
}

/// 新建主机（完整表单）；已保存列表仅在主页展示，此处不再重复。
Future<ConnectionLaunch?> showNewHostSheet(
  BuildContext context, {
  SavedHostProfile? preset,
}) {
  return showModalBottomSheet<ConnectionLaunch>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _NewHostSheetBody(preset: preset),
  );
}

class _NewHostSheetBody extends StatefulWidget {
  const _NewHostSheetBody({this.preset});

  final SavedHostProfile? preset;

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
  bool _saveDevice = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final p = widget.preset;
    _host = TextEditingController(text: p?.host ?? '');
    _port = TextEditingController(text: (p?.port ?? 22).toString());
    _user = TextEditingController(text: p?.username ?? '');
    _password = TextEditingController();
    _keyPath = TextEditingController(text: p?.keyPath ?? '');
    if (p != null) {
      _label.text = p.label;
    }
  }

  @override
  void dispose() {
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请填写主机与用户名')));
      return;
    }

    setState(() => _busy = true);
    final pem = await loadPrivateKeyFromPath(_keyPath.text.trim().isEmpty ? null : _keyPath.text);
    if (!mounted) return;
    setState(() => _busy = false);

    Navigator.of(context).pop(
      ConnectionLaunch(
        host: host,
        port: port,
        username: user,
        password: _password.text,
        privateKeyPem: pem,
        keyPath: _keyPath.text.trim().isEmpty ? null : _keyPath.text.trim(),
        saveAsDevice: _saveDevice,
        deviceLabel: _label.text.trim().isEmpty ? null : _label.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 8, bottom: 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('新建主机', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _label,
              decoration: const InputDecoration(
                labelText: '设备名称（保存时用）',
                hintText: '例如：公司 GPU 服务器',
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _host,
              decoration: const InputDecoration(labelText: '主机', hintText: 'IP 或域名'),
              textInputAction: TextInputAction.next,
              autocorrect: false,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _port,
              decoration: const InputDecoration(labelText: '端口'),
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: '用户名'),
              textInputAction: TextInputAction.next,
              autocorrect: false,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              decoration: const InputDecoration(
                labelText: '密码 / 密钥口令',
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
                    decoration: const InputDecoration(
                      labelText: '私钥路径（可选）',
                      hintText: '桌面端可点右侧浏览',
                    ),
                    autocorrect: false,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: '选择私钥文件',
                  onPressed: _pickKeyFile,
                  icon: const Icon(Icons.folder_open_rounded),
                ),
              ],
            ),
            if (!kIsWeb)
              CheckboxListTile(
                value: _saveDevice,
                onChanged: (v) => setState(() => _saveDevice = v ?? false),
                title: const Text('保存为设备（仅主机、用户、端口、密钥路径）'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
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
                    : const Text('连接'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
