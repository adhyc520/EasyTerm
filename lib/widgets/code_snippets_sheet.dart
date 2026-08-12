import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/code_snippets_store.dart';
import '../services/session_tabs_controller.dart';
import '../services/terminal_session_controller.dart';
import '../services/remote_exec_capable.dart';
import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';

Future<void> showCodeSnippetsSheet(
  BuildContext context, {
  required CodeSnippetsStore store,
  required SessionTabsController tabs,
  required void Function(String body) onRequestClickTarget,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      return Dialog(
        insetPadding: const EdgeInsets.all(32),
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 760,
            maxHeight: size.height * 0.82,
          ),
          child: _DesktopPanelSurface(
            child: _CodeSnippetsPanel(
              store: store,
              tabs: tabs,
              onRequestClickTarget: onRequestClickTarget,
            ),
          ),
        ),
      );
    },
  );
}

class _DesktopPanelSurface extends StatelessWidget {
  const _DesktopPanelSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.wb.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.wb.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.24),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: child),
    );
  }
}

class _CodeSnippetsPanel extends StatefulWidget {
  const _CodeSnippetsPanel({
    required this.store,
    required this.tabs,
    required this.onRequestClickTarget,
  });

  final CodeSnippetsStore store;
  final SessionTabsController tabs;
  final void Function(String body) onRequestClickTarget;

  @override
  State<_CodeSnippetsPanel> createState() => _CodeSnippetsPanelState();
}

class _CodeSnippetsPanelState extends State<_CodeSnippetsPanel> {
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStore);
    widget.store.ensureLoaded();
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  Future<void> _edit([CodeSnippet? existing]) async {
    final result = await showDialog<_SnippetDraft>(
      context: context,
      builder: (ctx) => _SnippetEditorDialog(existing: existing),
    );
    if (result == null) return;
    if (existing == null) {
      await widget.store.create(name: result.name, body: result.body);
    } else {
      await widget.store.update(
        id: existing.id,
        name: result.name,
        body: result.body,
      );
    }
  }

  Future<void> _delete(CodeSnippet item) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.codeSnippetDelete),
        content: Text(l10n.codeSnippetDeleteConfirm(item.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.codeSnippetCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.codeSnippetDelete),
          ),
        ],
      ),
    );
    if (ok == true) await widget.store.remove(item.id);
  }

  List<({int tabIndex, int paneId, TerminalSessionController controller})>
  _connectedTargets() {
    final out =
        <({int tabIndex, int paneId, TerminalSessionController controller})>[];
    final tabs = widget.tabs.tabs;
    for (var ti = 0; ti < tabs.length; ti++) {
      for (final leaf in tabs[ti].root.leaves) {
        if (!leaf.controller.connected) continue;
        out.add((
          tabIndex: ti,
          paneId: leaf.paneId,
          controller: leaf.controller,
        ));
      }
    }
    return out;
  }

  void _run(CodeSnippet item) {
    final l10n = AppLocalizations.of(context)!;
    final body = item.body.trimRight();
    if (body.trim().isEmpty) return;

    final targets = _connectedTargets();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.codeSnippetNeedSession)));
      return;
    }

    if (targets.length > 1) {
      final onPick = widget.onRequestClickTarget;
      Navigator.pop(context);
      onPick(body);
      return;
    }

    final target = targets.first;
    widget.tabs.selectTab(target.tabIndex);
    widget.tabs.focusPane(target.tabIndex, target.paneId);
    target.controller.pasteRemoteInputWithLineSubmit(body);

    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(content: Text(l10n.codeSnippetRan)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final items = widget.store.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 14, 10),
          child: Row(
            children: [
              Icon(Icons.code_rounded, color: context.wb.accentBlue, size: 20),
              const SizedBox(width: 8),
              Text(
                l10n.codeSnippetsTitle,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: context.wb.primaryText,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.close_rounded, color: context.wb.textMuted),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(l10n.codeSnippetNew),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: context.wb.border),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _CodeSnippetEmpty(text: l10n.codeSnippetsEmpty),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    final runnable = item.body.trim().isNotEmpty;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: context.wb.panelElevated,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: context.wb.border),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.fromLTRB(
                            14,
                            8,
                            8,
                            8,
                          ),
                          title: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.wb.primaryText,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              item.body,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: context.wb.textMuted,
                              ),
                            ),
                          ),
                          trailing: Wrap(
                            spacing: 0,
                            children: [
                              IconButton(
                                tooltip: l10n.codeSnippetRun,
                                onPressed: runnable ? () => _run(item) : null,
                                icon: Icon(
                                  Icons.play_arrow_rounded,
                                  color: runnable
                                      ? context.wb.accentBlue
                                      : context.wb.offline,
                                ),
                              ),
                              IconButton(
                                tooltip: l10n.codeSnippetEdit,
                                onPressed: () => _edit(item),
                                icon: Icon(
                                  Icons.edit_outlined,
                                  color: context.wb.textMuted,
                                ),
                              ),
                              IconButton(
                                tooltip: l10n.codeSnippetDelete,
                                onPressed: () => _delete(item),
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  color: context.wb.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _CodeSnippetEmpty extends StatelessWidget {
  const _CodeSnippetEmpty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: context.wb.panelElevated,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.wb.border),
          ),
          child: Icon(
            Icons.code_rounded,
            color: context.wb.textMuted.withValues(alpha: 0.78),
          ),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.wb.textMuted, height: 1.35),
          ),
        ),
      ],
    );
  }
}

class _SnippetDraft {
  const _SnippetDraft({required this.name, required this.body});
  final String name;
  final String body;
}

class _SnippetEditorDialog extends StatefulWidget {
  const _SnippetEditorDialog({this.existing});

  final CodeSnippet? existing;

  @override
  State<_SnippetEditorDialog> createState() => _SnippetEditorDialogState();
}

class _SnippetEditorDialogState extends State<_SnippetEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _body;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _body = TextEditingController(text: widget.existing?.body ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(
        widget.existing == null ? l10n.codeSnippetNew : l10n.codeSnippetEdit,
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: l10n.codeSnippetNameLabel,
                hintText: l10n.codeSnippetNameHint,
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              minLines: 6,
              maxLines: 14,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                labelText: l10n.codeSnippetBodyLabel,
                hintText: l10n.codeSnippetBodyHint,
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.codeSnippetCancel),
        ),
        AnimatedBuilder(
          animation: _body,
          builder: (context, _) {
            final canSave = _body.text.trim().isNotEmpty;
            return FilledButton(
              onPressed: canSave
                  ? () {
                      Navigator.pop(
                        context,
                        _SnippetDraft(
                          name: _name.text,
                          body: _body.text.trimRight(),
                        ),
                      );
                    }
                  : null,
              child: Text(l10n.codeSnippetSave),
            );
          },
        ),
      ],
    );
  }
}
