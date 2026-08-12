import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/host_group.dart';
import '../models/saved_host_profile.dart';
import '../services/host_profiles_store.dart';
import '../theme/workbench_theme.dart';

Future<void> showHostGroupEditor(
  BuildContext context, {
  required HostProfilesStore profiles,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => HostGroupEditor(profiles: profiles),
  );
}

class HostGroupEditor extends StatefulWidget {
  const HostGroupEditor({super.key, required this.profiles});

  final HostProfilesStore profiles;

  @override
  State<HostGroupEditor> createState() => _HostGroupEditorState();
}

class _HostGroupEditorState extends State<HostGroupEditor> {
  String? _selectedGroupId;

  HostGroup? get _selected {
    final id = _selectedGroupId;
    if (id == null) return null;
    for (final g in widget.profiles.groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  Future<void> _createGroup() async {
    final l = AppLocalizations.of(context)!;
    final name = await _promptName(title: l.hostGroupCreateTitle);
    if (name == null || name.trim().isEmpty) return;
    final id = await widget.profiles.createGroup(name);
    if (!mounted) return;
    setState(() => _selectedGroupId = id);
  }

  Future<void> _renameGroup(HostGroup g) async {
    final l = AppLocalizations.of(context)!;
    final name = await _promptName(
      title: l.hostGroupRenameTitle,
      initial: g.name,
    );
    if (name == null || name.trim().isEmpty) return;
    await widget.profiles.renameGroup(g.id, name);
    if (mounted) setState(() {});
  }

  Future<void> _deleteGroup(HostGroup g) async {
    final l = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.hostGroupDeleteTitle),
        content: Text(l.hostGroupDeleteConfirm(g.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.codeSnippetCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.contextDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.profiles.deleteGroup(g.id);
    if (!mounted) return;
    setState(() {
      if (_selectedGroupId == g.id) _selectedGroupId = null;
    });
  }

  Future<String?> _promptName({required String title, String? initial}) {
    final l = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: l.hostGroupNameLabel),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.codeSnippetCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(l.connectionSubmitSave),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final wb = context.wb;
    final size = MediaQuery.sizeOf(context);
    final dialogW = (size.width - 48).clamp(280.0, 560.0);
    final dialogH = (size.height * 0.7).clamp(280.0, 420.0);

    return AlertDialog(
      title: Text(
        l.hostGroupEditorTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: dialogW,
        height: dialogH,
        child: ListenableBuilder(
          listenable: widget.profiles,
          builder: (context, _) {
            final groups = widget.profiles.groups;
            final selected = _selected;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l.hostGroupsHeader,
                              style: TextStyle(
                                color: wb.textMuted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: l.hostGroupCreateTitle,
                            onPressed: _createGroup,
                            icon: const Icon(Icons.add_rounded),
                          ),
                        ],
                      ),
                      Expanded(
                        child: groups.isEmpty
                            ? Center(
                                child: Text(
                                  l.hostGroupsEmpty,
                                  style: TextStyle(color: wb.textMuted),
                                ),
                              )
                            : ListView.builder(
                                itemCount: groups.length,
                                itemBuilder: (context, i) {
                                  final g = groups[i];
                                  final selectedTile =
                                      g.id == _selectedGroupId;
                                  return ListTile(
                                    dense: true,
                                    selected: selectedTile,
                                    title: Text(
                                      g.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      l.hostGroupMemberCount(
                                        g.profileIds.length,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => setState(
                                      () => _selectedGroupId = g.id,
                                    ),
                                    trailing: PopupMenuButton<String>(
                                      onSelected: (v) {
                                        if (v == 'rename') {
                                          unawaited(_renameGroup(g));
                                        } else if (v == 'del') {
                                          unawaited(_deleteGroup(g));
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        PopupMenuItem(
                                          value: 'rename',
                                          child: Text(l.hostGroupRenameTitle),
                                        ),
                                        PopupMenuItem(
                                          value: 'del',
                                          child: Text(
                                            l.contextDelete,
                                            style: TextStyle(
                                              color: Colors.red.shade300,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                VerticalDivider(width: 1, color: wb.border),
                Expanded(
                  flex: 3,
                  child: selected == null
                      ? Center(
                          child: Text(
                            l.hostGroupSelectHint,
                            style: TextStyle(color: wb.textMuted),
                          ),
                        )
                      : _GroupMembersPane(
                          store: widget.profiles,
                          group: selected,
                        ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.codeSnippetCancel),
        ),
      ],
    );
  }
}

class _GroupMembersPane extends StatelessWidget {
  const _GroupMembersPane({required this.store, required this.group});

  final HostProfilesStore store;
  final HostGroup group;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final wb = context.wb;
    final members = <SavedHostProfile>[];
    final memberIds = group.profileIds.toSet();
    for (final p in store.profiles) {
      if (memberIds.contains(p.id)) members.add(p);
    }
    final candidates =
        store.profiles.where((p) => !memberIds.contains(p.id)).toList();

    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.hostGroupMembersOf(group.name),
            style: TextStyle(
              color: wb.primaryText,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                if (members.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      l.hostGroupNoMembers,
                      style: TextStyle(color: wb.textMuted, fontSize: 12),
                    ),
                  ),
                for (final p in members)
                  ListTile(
                    dense: true,
                    title: Text(p.label),
                    subtitle: Text(
                      p.subtitle,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: l.hostGroupRemoveMember,
                      icon: const Icon(Icons.remove_circle_outline, size: 18),
                      onPressed: () =>
                          unawaited(store.removeFromGroup(p.id, group.id)),
                    ),
                  ),
                const Divider(),
                Text(
                  l.hostGroupAddMember,
                  style: TextStyle(
                    color: wb.textMuted,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                for (final p in candidates)
                  ListTile(
                    dense: true,
                    title: Text(p.label),
                    subtitle: Text(
                      p.subtitle,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: l.hostGroupAddMember,
                      icon: const Icon(Icons.add_circle_outline, size: 18),
                      onPressed: () =>
                          unawaited(store.addToGroup(p.id, group.id)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
