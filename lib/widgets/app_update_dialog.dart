import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/app_update/app_update_service.dart';
import '../services/app_update/github_release_client.dart';
import '../theme/workbench_theme.dart';

/// Shows update UI: check result, download progress, install & restart.
Future<void> showAppUpdateDialog(
  BuildContext context, {
  required AppUpdateService service,
  AppUpdateCheckResult? initialResult,
  bool manualCheck = false,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _AppUpdateDialog(
      service: service,
      initialResult: initialResult,
      manualCheck: manualCheck,
    ),
  );
}

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({
    required this.service,
    this.initialResult,
    required this.manualCheck,
  });

  final AppUpdateService service;
  final AppUpdateCheckResult? initialResult;
  final bool manualCheck;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  AppUpdateCheckResult? _result;
  String? _statusMessage;
  double _progress = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialResult != null) {
      _result = widget.initialResult;
    } else {
      unawaited(_check());
    }
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    final result = await widget.service.checkForUpdates(respectSkipped: false);
    if (!mounted) return;
    setState(() {
      _result = result;
      _busy = false;
    });
  }

  Future<void> _install(GithubRelease release) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _progress = 0;
      _statusMessage = l10n.updateDownloading(0);
    });
    try {
      await widget.service.downloadAndInstall(
        release,
        onProgress: (p) {
          if (!mounted) return;
          final percent = (p * 100).round();
          setState(() {
            _progress = p;
            _statusMessage = p >= 1
                ? l10n.updateInstalling
                : l10n.updateDownloading(percent);
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = l10n.updateError(e.toString());
        _result = AppUpdateCheckResult.error(e.toString());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final wb = context.wb;
    final result = _result;

    if (_busy && result == null) {
      return AlertDialog(
        title: Text(l10n.updateChecking),
        content: SizedBox(
          width: 280,
          child: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(l10n.updateChecking)),
            ],
          ),
        ),
      );
    }

    if (result == null) {
      return const SizedBox.shrink();
    }

    switch (result.kind) {
      case AppUpdateCheckKind.updateAvailable:
        final release = result.release!;
        return AlertDialog(
          title: Text(l10n.updateAvailableTitle),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.updateAvailableMessage(release.tagName),
                  style: TextStyle(color: wb.textMuted),
                ),
                if (release.body.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.updateReleaseNotes,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        release.body,
                        style: TextStyle(
                          fontSize: 13,
                          color: wb.primaryText,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: _progress > 0 ? _progress : null),
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _statusMessage!,
                      style: TextStyle(fontSize: 12, color: wb.textMuted),
                    ),
                  ],
                ],
              ],
            ),
          ),
          actions: _busy
              ? null
              : [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l10n.updateLater),
                  ),
                  TextButton(
                    onPressed: () async {
                      await widget.service.skipVersion(release.tagName);
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: Text(l10n.updateSkipVersion),
                  ),
                  FilledButton(
                    onPressed: () => unawaited(_install(release)),
                    child: Text(l10n.updateDownloadInstall),
                  ),
                ],
        );

      case AppUpdateCheckKind.upToDate:
        return AlertDialog(
          title: Text(l10n.updateUpToDateTitle),
          content: Text(l10n.updateUpToDateMessage),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.updateOk),
            ),
          ],
        );

      case AppUpdateCheckKind.error:
        return AlertDialog(
          title: Text(l10n.updateErrorTitle),
          content: Text(
            _statusMessage ??
                l10n.updateError(result.errorMessage ?? l10n.updateErrorUnknown),
          ),
          actions: [
            if (widget.manualCheck)
              TextButton(
                onPressed: () => unawaited(_check()),
                child: Text(l10n.updateRetry),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.updateOk),
            ),
          ],
        );

      case AppUpdateCheckKind.unsupported:
        return AlertDialog(
          title: Text(l10n.updateErrorTitle),
          content: Text(l10n.updateUnsupported),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.updateOk),
            ),
          ],
        );
    }
  }
}
