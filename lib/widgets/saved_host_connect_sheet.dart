import 'package:flutter/material.dart';

import '../models/saved_host_profile.dart';
import '../services/ssh_workspace_controller.dart';

/// 从已保存主机发起连接时采集的凭据（在弹层内读取私钥文件）。
class SavedHostCredentials {
  const SavedHostCredentials({
    required this.password,
    this.privateKeyPem,
  });

  final String password;
  final String? privateKeyPem;
}

Future<SavedHostCredentials?> showSavedHostConnectSheet(
  BuildContext context,
  SavedHostProfile profile,
) {
  return showModalBottomSheet<SavedHostCredentials>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _SavedHostConnectBody(profile: profile),
  );
}

class _SavedHostConnectBody extends StatefulWidget {
  const _SavedHostConnectBody({required this.profile});

  final SavedHostProfile profile;

  @override
  State<_SavedHostConnectBody> createState() => _SavedHostConnectBodyState();
}

class _SavedHostConnectBodyState extends State<_SavedHostConnectBody> {
  late final TextEditingController _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    String? pem;
    try {
      pem = await loadPrivateKeyFromPath(widget.profile.keyPath);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    Navigator.of(context).pop(
      SavedHostCredentials(
        password: _password.text,
        privateKeyPem: pem,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final hasKey = p.keyPath != null && p.keyPath!.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 8, bottom: 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('连接到「${p.label}」', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              p.subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
            if (hasKey) ...[
              const SizedBox(height: 8),
              Text(
                '已配置私钥路径，口令仅用于解密私钥（若私钥无加密可留空）。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 20),
            TextField(
              controller: _password,
              decoration: InputDecoration(
                labelText: hasKey ? '私钥口令 / SSH 密码' : 'SSH 密码',
                helperText: hasKey ? '无加密私钥且使用公钥登录时可留空' : '使用密钥登录时请先在「新建主机」里为该设备配置私钥路径',
              ),
              obscureText: true,
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            const SizedBox(height: 20),
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
