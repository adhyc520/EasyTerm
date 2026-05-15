import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
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
  final FocusNode _passwordFocus = FocusNode();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _passwordFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _passwordFocus.dispose();
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
    final l = AppLocalizations.of(context)!;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final hasKey = p.keyPath != null && p.keyPath!.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 8, bottom: 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.savedHostConnectTitle(p.label), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              p.subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
            if (hasKey) ...[
              const SizedBox(height: 8),
              Text(
                l.savedHostKeyPassphraseHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 20),
            TextField(
              focusNode: _passwordFocus,
              controller: _password,
              decoration: InputDecoration(
                labelText: hasKey ? l.savedHostPasswordFieldKey : l.savedHostPasswordFieldPassword,
                helperText: hasKey ? l.savedHostPasswordHelperKey : l.savedHostPasswordHelperPassword,
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
                    : Text(l.savedHostConnect),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
