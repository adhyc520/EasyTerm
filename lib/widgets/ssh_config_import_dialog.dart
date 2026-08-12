import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/host_profiles_store.dart';
import '../services/ssh_config_importer.dart';
import '../theme/workbench_theme.dart';

Future<ImportResult?> showSshConfigImportDialog(
  BuildContext context, {
  required HostProfilesStore profiles,
}) {
  return showDialog<ImportResult>(
    context: context,
    builder: (ctx) => SshConfigImportDialog(profiles: profiles),
  );
}

class SshConfigImportDialog extends StatefulWidget {
  const SshConfigImportDialog({super.key, required this.profiles});

  final HostProfilesStore profiles;

  @override
  State<SshConfigImportDialog> createState() => _SshConfigImportDialogState();
}

class _SshConfigImportDialogState extends State<SshConfigImportDialog> {
  final SshConfigImporter _importer = SshConfigImporter();
  List<SshConfigEntry>? _entries;
  final Set<int> _selected = {};
  ConflictResolution _conflict = ConflictResolution.skip;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  late final String _path;

  @override
  void initState() {
    super.initState();
    _path = SshConfigImporter.defaultConfigPath();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _importer.parseConfig(_path);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _selected
          ..clear()
          ..addAll(List.generate(entries.length, (i) => i));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _entries = const [];
      });
    }
  }

  Future<void> _import({required bool all}) async {
    final entries = _entries;
    if (entries == null || entries.isEmpty) return;
    final chosen = <SshConfigEntry>[];
    for (var i = 0; i < entries.length; i++) {
      if (all || _selected.contains(i)) chosen.add(entries[i]);
    }
    if (chosen.isEmpty) return;
    setState(() => _busy = true);
    try {
      final result = await _importer.importTo(
        widget.profiles,
        entries: chosen,
        conflict: _conflict,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final wb = context.wb;
    final entries = _entries;
    final size = MediaQuery.sizeOf(context);
    final dialogW = (size.width - 48).clamp(280.0, 480.0);

    return AlertDialog(
      title: Text(
        l.sshConfigImportTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: dialogW,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.sshConfigImportSource(_path),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: wb.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_error != null)
              Text(_error!, style: TextStyle(color: Colors.red.shade300))
            else if (entries == null || entries.isEmpty)
              Text(
                l.sshConfigImportEmpty,
                style: TextStyle(color: wb.textMuted),
              )
            else ...[
              Text(
                l.sshConfigImportFound(entries.length),
                style: TextStyle(
                  color: wb.primaryText,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (size.height * 0.4).clamp(120.0, 280.0),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    return CheckboxListTile(
                      dense: true,
                      value: _selected.contains(i),
                      onChanged: _busy
                          ? null
                          : (v) {
                              setState(() {
                                if (v == true) {
                                  _selected.add(i);
                                } else {
                                  _selected.remove(i);
                                }
                              });
                            },
                      title: Text(
                        e.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        e.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l.sshConfigConflictLabel,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: wb.primaryText,
                ),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<ConflictResolution>(
                initialValue: _conflict,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(
                    value: ConflictResolution.skip,
                    child: Text(
                      l.sshConfigConflictSkip,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: ConflictResolution.overwrite,
                    child: Text(
                      l.sshConfigConflictOverwrite,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: ConflictResolution.duplicate,
                    child: Text(
                      l.sshConfigConflictDuplicate,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (next) {
                        if (next == null) return;
                        setState(() => _conflict = next);
                      },
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(l.codeSnippetCancel),
        ),
        if (!_loading && entries != null && entries.isNotEmpty) ...[
          TextButton(
            onPressed: _busy ? null : () => _import(all: true),
            child: Text(l.sshConfigImportAll),
          ),
          FilledButton(
            onPressed: _busy || _selected.isEmpty
                ? null
                : () => _import(all: false),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l.sshConfigImportSelected),
          ),
        ],
      ],
    );
  }
}
