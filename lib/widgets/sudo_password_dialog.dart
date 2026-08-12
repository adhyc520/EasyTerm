import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/remote_sudo.dart';
import '../services/ssh_workspace_controller.dart';

/// 弹出远端 sudo 密码输入框；取消返回 `null`。
Future<String?> promptSudoPassword(
  BuildContext context, {
  String? errorText,
  bool offerSshPassword = false,
  String? sshPassword,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _SudoPasswordDialog(
      errorText: errorText,
      offerSshPassword: offerSshPassword && (sshPassword?.isNotEmpty ?? false),
      sshPassword: sshPassword,
    ),
  );
}

/// 执行 [attempt]；若需密码则弹窗并用 [SshWorkspaceController.cachedSudoPassword] 重试。
///
/// [attempt] 传入 `null` 表示 `sudo -n`；非空则用 `sudo -S`。
/// 返回 `null` 表示成功；用户取消返回 [RemoteSudo.cancelled]。
Future<String?> runWithSudoPasswordPrompt(
  BuildContext context,
  Object controller, {
  required Future<String?> Function(String? sudoPassword) attempt,
}) async {
  final ssh = controller is SshWorkspaceController ? controller : null;
  String? pwd = ssh?.cachedSudoPassword;
  var err = await attempt(pwd);

  // 缓存密码失效
  if (RemoteSudo.isAuthFailed(err) && pwd != null) {
    if (ssh != null) ssh.cachedSudoPassword = null;
    pwd = null;
  }

  while (RemoteSudo.isPasswordRequired(err) || RemoteSudo.isAuthFailed(err)) {
    // 勿把内部哨兵串泄漏到 UI（例如 widget 已卸但 context 仍短暂有效）。
    if (!context.mounted) return RemoteSudo.cancelled;
    final next = await promptSudoPassword(
      context,
      errorText: RemoteSudo.isAuthFailed(err)
          ? (AppLocalizations.of(context)?.sudoPasswordIncorrect ??
              '密码不正确，请重试')
          : null,
      offerSshPassword: ssh?.password.isNotEmpty ?? false,
      sshPassword: (ssh?.password.isNotEmpty ?? false) ? ssh!.password : null,
    );
    if (next == null) return RemoteSudo.cancelled;
    if (!context.mounted) return RemoteSudo.cancelled;
    pwd = next;
    err = await attempt(pwd);
    if (err == null) {
      if (ssh != null) ssh.cachedSudoPassword = pwd;
      ssh?.touchSudoPassword();
      return null;
    }
    if (RemoteSudo.isAuthFailed(err)) {
      if (ssh != null) ssh.cachedSudoPassword = null;
      continue;
    }
    if (RemoteSudo.isPasswordRequired(err)) {
      // 理论上带密码不应再返回 passwordRequired；当作鉴权失败。
      if (ssh != null) ssh.cachedSudoPassword = null;
      err = RemoteSudo.authFailed;
      continue;
    }
    return err;
  }

  if (err == null && pwd != null && pwd.isNotEmpty) {
    if (ssh != null) ssh.cachedSudoPassword = pwd;
    ssh?.touchSudoPassword();
  } else if (err == null && ssh?.cachedSudoPassword != null) {
    ssh?.touchSudoPassword();
  }
  return err;
}

class _SudoPasswordDialog extends StatefulWidget {
  const _SudoPasswordDialog({
    this.errorText,
    required this.offerSshPassword,
    this.sshPassword,
  });

  final String? errorText;
  final bool offerSshPassword;
  final String? sshPassword;

  @override
  State<_SudoPasswordDialog> createState() => _SudoPasswordDialogState();
}

class _SudoPasswordDialogState extends State<_SudoPasswordDialog> {
  late final TextEditingController _ctrl;
  late bool _useSshPassword;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _useSshPassword = widget.offerSshPassword;
    _ctrl = TextEditingController(
      text: _useSshPassword ? (widget.sshPassword ?? '') : '',
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final pwd = _ctrl.text;
    if (pwd.isEmpty) return;
    Navigator.pop(context, pwd);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l?.sudoNeedAuthTitle ?? '需要 sudo 授权'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l?.sudoAuthBody ??
                  '远端执行特权命令需要 sudo 密码。密码将在本次会话内复用（15 分钟空闲后失效），不会保存到本地。',
              style: const TextStyle(fontSize: 13),
            ),
            if (widget.errorText != null) ...[
              const SizedBox(height: 10),
              Text(
                widget.errorText!,
                style: TextStyle(color: Colors.red.shade300, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _ctrl,
              obscureText: _obscure,
              autofocus: !_useSshPassword,
              enabled: !_useSshPassword,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: l?.sudoPasswordLabel ?? 'sudo 密码',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _obscure
                      ? (l?.sudoShowPassword ?? '显示')
                      : (l?.sudoHidePassword ?? '隐藏'),
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 20,
                  ),
                ),
              ),
            ),
            if (widget.offerSshPassword) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _useSshPassword,
                title: Text(
                  l?.sudoUseSshPassword ?? '使用 SSH 登录密码',
                  style: const TextStyle(fontSize: 13),
                ),
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (v) {
                  final use = v ?? false;
                  setState(() {
                    _useSshPassword = use;
                    if (use) {
                      _ctrl.text = widget.sshPassword ?? '';
                    } else {
                      _ctrl.clear();
                    }
                  });
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l?.sudoCancel ?? '取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l?.sudoAuthorize ?? '授权'),
        ),
      ],
    );
  }
}
