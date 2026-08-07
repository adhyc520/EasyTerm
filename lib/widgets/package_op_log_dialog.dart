import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/remote_packages.dart';
import '../services/remote_stream.dart';
import '../services/remote_sudo.dart';
import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';
import 'sudo_password_dialog.dart';

/// 弹出安装/卸载进度日志框；成功返回 `true`，失败 `false`，取消 `null`。
Future<bool?> showPackageOpLogDialog(
  BuildContext context, {
  required SshWorkspaceController controller,
  required RemotePackageManager manager,
  required String packageName,
  required bool install,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PackageOpLogDialog(
      controller: controller,
      manager: manager,
      packageName: packageName,
      install: install,
    ),
  );
}

class _PackageOpLogDialog extends StatefulWidget {
  const _PackageOpLogDialog({
    required this.controller,
    required this.manager,
    required this.packageName,
    required this.install,
  });

  final SshWorkspaceController controller;
  final RemotePackageManager manager;
  final String packageName;
  final bool install;

  @override
  State<_PackageOpLogDialog> createState() => _PackageOpLogDialogState();
}

class _PackageOpLogDialogState extends State<_PackageOpLogDialog> {
  final _scroll = ScrollController();
  final List<String> _lines = [];
  RemoteStream? _stream;
  int _remoteSynced = 0;
  bool _running = false;
  bool _aborted = false;
  bool _cancelled = false;
  bool _stickBottom = true;
  bool? _success;
  String? _status;

  String get _title =>
      widget.install ? '安装 ${widget.packageName}' : '卸载 ${widget.packageName}';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atBottom =
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 48;
      _stickBottom = atBottom;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_start());
    });
  }

  @override
  void dispose() {
    unawaited(_detachStream(stop: true));
    _scroll.dispose();
    super.dispose();
  }

  void _appendLocal(String line) {
    _lines.add(line);
    while (_lines.length > 4000) {
      _lines.removeAt(0);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_stickBottom || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _detachStream({required bool stop}) async {
    final s = _stream;
    _stream = null;
    _remoteSynced = 0;
    if (s == null) return;
    s.removeListener(_onStream);
    widget.controller.unregisterRemoteStream(s);
    if (stop) await s.stop();
  }

  Future<void> _start() async {
    if (!widget.controller.connected || widget.controller.dropped) {
      setState(() {
        _success = false;
        _status = '未连接';
        _appendLocal('错误：SSH 未连接');
      });
      return;
    }

    String? pwd = widget.controller.cachedSudoPassword;
    var authError = false;

    while (true) {
      if (!mounted) return;
      setState(() {
        _running = true;
        _success = null;
        _status = authError ? '正在用新密码重试…' : '正在执行…';
      });

      final usePwd = pwd != null && pwd.isNotEmpty;
      final sudoPassword = usePwd ? pwd : null;
      final cmd = mutatePackageStreamCommand(
        widget.manager,
        name: widget.packageName,
        install: widget.install,
        sudoWithStdin: usePwd,
      );
      _appendLocal('\$ $cmd');
      if (usePwd) _appendLocal('(已注入 sudo 密码)');
      setState(() {});
      _scrollToEnd();

      await _detachStream(stop: true);
      late final RemoteStream stream;
      try {
        stream = await widget.controller.startRemoteStream(
          cmd,
          maxLines: 4000,
          stdinBytes: sudoPassword != null
              ? RemoteSudo.passwordStdin(sudoPassword)
              : null,
        );
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _running = false;
          _success = false;
          _status = '启动失败';
          _appendLocal('错误：$e');
        });
        return;
      }
      if (!mounted) {
        widget.controller.unregisterRemoteStream(stream);
        await stream.stop();
        return;
      }
      _stream = stream;
      _remoteSynced = 0;
      stream.addListener(_onStream);
      _onStream();
      await stream.waitUntilClosed();
      if (!mounted || _aborted) return;

      final out = stream.lines.join('\n');
      final ec = stream.exitCode ?? 1;
      final err = stream.error;

      if (err != null) {
        setState(() {
          _running = false;
          _success = false;
          _status = '失败';
          _appendLocal('错误：$err');
        });
        return;
      }

      if (ec == 0) {
        if (usePwd) widget.controller.cachedSudoPassword = pwd;
        setState(() {
          _running = false;
          _success = true;
          _status = widget.install ? '安装完成' : '卸载完成';
          _appendLocal('—— 退出码 0 ——');
        });
        _scrollToEnd();
        return;
      }

      final needPwd = RemoteSudo.looksLikePasswordRequired(out) ||
          (!usePwd &&
              out.toLowerCase().contains('sudo') &&
              out.toLowerCase().contains('password'));
      final badPwd = usePwd &&
          (RemoteSudo.looksLikeAuthFailed(out) ||
              RemoteSudo.looksLikePasswordRequired(out));

      if (needPwd || badPwd) {
        if (usePwd) widget.controller.cachedSudoPassword = null;
        if (!mounted) return;
        final next = await promptSudoPassword(
          context,
          errorText: badPwd ? '密码不正确，请重试' : null,
          offerSshPassword: widget.controller.password.isNotEmpty,
          sshPassword: widget.controller.password.isNotEmpty
              ? widget.controller.password
              : null,
        );
        if (next == null || _aborted) {
          _cancelled = true;
          if (!mounted) return;
          setState(() {
            _running = false;
            _success = false;
            _status = '已取消';
            _appendLocal('—— 已取消授权 ——');
          });
          return;
        }
        pwd = next;
        authError = badPwd;
        _appendLocal('—— 重新执行 ——');
        continue;
      }

      setState(() {
        _running = false;
        _success = false;
        _status = '失败 (退出码 $ec)';
        _appendLocal('—— 退出码 $ec ——');
      });
      _scrollToEnd();
      return;
    }
  }

  void _onStream() {
    final s = _stream;
    if (s == null || !mounted) return;
    final remote = s.lines;
    if (remote.length > _remoteSynced) {
      _lines.addAll(remote.sublist(_remoteSynced));
      _remoteSynced = remote.length;
      while (_lines.length > 4000) {
        _lines.removeAt(0);
      }
    }
    setState(() {});
    _scrollToEnd();
  }

  Future<void> _cancel() async {
    if (_aborted) return;
    _aborted = true;
    _cancelled = true;
    await _detachStream(stop: true);
    if (!mounted) return;
    setState(() {
      _running = false;
      _success = false;
      _status = '已中止';
      _appendLocal('—— 用户中止 ——');
    });
  }

  void _closeDialog() {
    // 取消 / 中止 → null；成功 true；失败 false（与 showPackageOpLogDialog 约定一致）。
    if (_cancelled) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, _success == true);
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final done = !_running && _success != null;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            widget.install
                ? Icons.download_rounded
                : Icons.delete_outline_rounded,
            size: 20,
            color: wb.accentBlue,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(_title)),
          if (_running)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _status!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _success == true
                        ? Colors.green.shade400
                        : _success == false
                            ? Colors.red.shade300
                            : wb.textMuted,
                  ),
                ),
              ),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: wb.terminalBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: wb.border),
                ),
                child: _lines.isEmpty
                    ? Center(
                        child: Text(
                          '等待输出…',
                          style: TextStyle(color: wb.textMuted),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                        itemCount: _lines.length,
                        itemBuilder: (context, i) {
                          return SelectableText(
                            _lines[i],
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.35,
                              color: wb.secondaryText,
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _lines.isEmpty
              ? null
              : () {
                  unawaited(
                    Clipboard.setData(ClipboardData(text: _lines.join('\n'))),
                  );
                },
          icon: const Icon(Icons.copy_rounded, size: 16),
          label: const Text('复制日志'),
        ),
        if (_running)
          TextButton(
            onPressed: () => unawaited(_cancel()),
            child: const Text('中止'),
          )
        else
          FilledButton(
            onPressed: _closeDialog,
            child: Text(done && _success == true ? '完成' : '关闭'),
          ),
      ],
    );
  }
}
