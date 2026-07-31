import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/remote_host_metrics.dart';
import '../services/session_tabs_controller.dart';
import '../services/ssh_workspace_controller.dart';
import '../theme/workbench_theme.dart';

Future<void> showHealthBoardSheet(
  BuildContext context, {
  required SessionTabsController tabs,
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
          child: _DesktopPanelSurface(child: _HealthBoardPanel(tabs: tabs)),
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

class _HealthBoardPanel extends StatefulWidget {
  const _HealthBoardPanel({required this.tabs});

  final SessionTabsController tabs;

  @override
  State<_HealthBoardPanel> createState() => _HealthBoardPanelState();
}

class _HostMetricEntry {
  _HostMetricEntry({required this.controller});

  final SshWorkspaceController controller;
  RemoteHostSnapshot? snap;
  bool loading = false;
  String? error;

  String get key =>
      '${controller.username}@${controller.host}:${controller.port}';
}

class _HealthBoardPanelState extends State<_HealthBoardPanel> {
  final Map<String, _HostMetricEntry> _byHost = {};
  bool _refreshing = false;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    widget.tabs.addListener(_onTabs);
    scheduleMicrotask(_refreshAll);
  }

  @override
  void dispose() {
    widget.tabs.removeListener(_onTabs);
    super.dispose();
  }

  void _onTabs() {
    if (mounted) setState(() {});
    scheduleMicrotask(_refreshAll);
  }

  List<({SessionTab tab, SshWorkspaceController c})> _allPanes() {
    final panes = <({SessionTab tab, SshWorkspaceController c})>[];
    for (final tab in widget.tabs.tabs) {
      for (final leaf in tab.root.leaves) {
        panes.add((tab: tab, c: leaf.controller));
      }
    }
    return panes;
  }

  /// 同一主机多窗格只采一次样。
  List<_HostMetricEntry> _uniqueConnectedHosts(
    List<({SessionTab tab, SshWorkspaceController c})> panes,
  ) {
    final seen = <String>{};
    final out = <_HostMetricEntry>[];
    for (final e in panes) {
      if (!e.c.connected) continue;
      final key = '${e.c.username}@${e.c.host}:${e.c.port}';
      if (!seen.add(key)) continue;
      final existing = _byHost[key];
      if (existing != null) {
        out.add(existing);
      } else {
        final created = _HostMetricEntry(controller: e.c);
        _byHost[key] = created;
        out.add(created);
      }
    }
    _byHost.removeWhere((k, _) => !seen.contains(k));
    return out;
  }

  Future<void> _refreshAll() async {
    final panes = _allPanes();
    final hosts = _uniqueConnectedHosts(panes);
    if (!mounted) return;
    setState(() => _refreshing = true);
    final gen = ++_gen;
    await Future.wait(hosts.map((h) => _pollOne(h, gen)));
    if (!mounted || gen != _gen) return;
    setState(() => _refreshing = false);
  }

  Future<void> _pollOne(_HostMetricEntry entry, int gen) async {
    if (!entry.controller.connected) {
      entry.snap = null;
      entry.error = null;
      entry.loading = false;
      return;
    }
    entry.loading = true;
    entry.error = null;
    if (mounted && gen == _gen) setState(() {});
    try {
      final snap = await fetchRemoteHostSnapshot(entry.controller);
      if (gen != _gen) return;
      entry.snap = snap;
      if (snap == null) {
        entry.error = 'unavailable';
      }
    } catch (_) {
      if (gen != _gen) return;
      entry.snap = null;
      entry.error = 'unavailable';
    } finally {
      entry.loading = false;
      if (mounted && gen == _gen) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final panes = _allPanes();
    final hosts = _uniqueConnectedHosts(panes);
    final active = panes.where((e) => e.c.connected).length;
    final connecting = panes.where((e) => e.c.connecting).length;
    final errors = panes
        .where(
          (e) => e.c.error != null && e.c.error!.isNotEmpty && !e.c.connected,
        )
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 14, 10),
          child: Row(
            children: [
              Icon(
                Icons.monitor_heart_outlined,
                color: context.wb.accentBlue,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.healthBoardTitle,
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
              TextButton.icon(
                onPressed: _refreshing ? null : _refreshAll,
                icon: _refreshing
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: context.wb.accentBlue,
                        ),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: Text(l10n.healthBoardRefresh),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: context.wb.border),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              Text(
                l10n.healthBoardSessions,
                style: TextStyle(
                  color: context.wb.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _StatCard(
                    label: l10n.healthBoardActive,
                    value: '$active',
                    color: context.wb.online,
                  ),
                  _StatCard(
                    label: l10n.healthBoardConnecting,
                    value: '$connecting',
                    color: const Color(0xFFEAB308),
                  ),
                  _StatCard(
                    label: l10n.healthBoardErrors,
                    value: '$errors',
                    color: const Color(0xFFEF4444),
                  ),
                  _StatCard(
                    label: l10n.healthBoardPanes,
                    value: '${panes.length}',
                    color: context.wb.accentBlue,
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Text(
                l10n.healthBoardHost,
                style: TextStyle(
                  color: context.wb.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              if (panes.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: _HealthEmptyHint(text: l10n.healthBoardNoSessions),
                )
              else if (hosts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: _HealthEmptyHint(text: l10n.healthBoardNoConnected),
                )
              else
                ...hosts.map((h) => _HostCard(entry: h, l10n: l10n)),
              if (panes.isNotEmpty && hosts.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  l10n.healthBoardSessionStatus,
                  style: TextStyle(
                    color: context.wb.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ...panes.map((e) {
                  final c = e.c;
                  final ok = c.connected;
                  final status = c.connecting
                      ? l10n.healthBoardConnecting
                      : ok
                      ? l10n.healthBoardConnected
                      : l10n.healthBoardDisconnected;
                  final color = c.connecting
                      ? const Color(0xFFEAB308)
                      : ok
                      ? context.wb.online
                      : (c.error != null && c.error!.isNotEmpty)
                      ? const Color(0xFFEF4444)
                      : context.wb.offline;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: context.wb.panelElevated,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: context.wb.border),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        leading: Icon(Icons.circle, size: 10, color: color),
                        title: Text(
                          '${c.username}@${c.host}:${c.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.wb.primaryText,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          status +
                              (c.error != null &&
                                      c.error!.isNotEmpty &&
                                      !ok
                                  ? ' · ${c.error}'
                                  : ''),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.wb.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({required this.entry, required this.l10n});

  final _HostMetricEntry entry;
  final AppLocalizations l10n;

  String _pct(double? v) {
    if (v == null || !v.isFinite) return '—';
    return '${(v * 100).toStringAsFixed(0)}%';
  }

  @override
  Widget build(BuildContext context) {
    final c = entry.controller;
    final s = entry.snap;
    final loading = entry.loading && s == null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.wb.panelElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.wb.border),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.dns_outlined, size: 16, color: context.wb.online),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${c.username}@${c.host}:${c.port}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.wb.primaryText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (entry.loading)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.wb.accentBlue,
                      ),
                    ),
                ],
              ),
              if (s?.uptimeLine != null && s!.uptimeLine!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  s.uptimeLine!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.wb.textMuted,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (loading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    l10n.healthBoardFetching,
                    style: TextStyle(color: context.wb.textMuted, fontSize: 13),
                  ),
                )
              else if (entry.error != null && s == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    l10n.healthBoardMetricsUnavailable,
                    style: TextStyle(color: context.wb.textMuted, fontSize: 13),
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MetricChip(
                      label: l10n.healthBoardCpu,
                      value: _pct(s?.cpuUsed01),
                      tone: s?.cpuUsed01,
                    ),
                    _MetricChip(
                      label: l10n.healthBoardMemory,
                      value: _pct(s?.memUsed01),
                      tone: s?.memUsed01,
                    ),
                    _MetricChip(
                      label: l10n.healthBoardDisk,
                      value: _pct(s?.diskUsed01),
                      tone: s?.diskUsed01,
                    ),
                    _MetricChip(
                      label: l10n.healthBoardLoad,
                      value: s?.loadLine ?? '—',
                      tone: s?.loadPressure01,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.label,
    required this.value,
    required this.tone,
  });

  final String label;
  final String value;
  final double? tone;

  Color _valueColor(BuildContext context) {
    final t = tone;
    if (t == null) return context.wb.primaryText;
    if (t >= 0.9) return const Color(0xFFEF4444);
    if (t >= 0.75) return const Color(0xFFEAB308);
    return context.wb.online;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 148,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: context.wb.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.wb.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: context.wb.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: _valueColor(context),
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthEmptyHint extends StatelessWidget {
  const _HealthEmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.wb.panelElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.wb.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.wb.textMuted, height: 1.35),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 134,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: context.wb.panelElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.wb.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: context.wb.textMuted),
          ),
        ],
      ),
    );
  }
}
