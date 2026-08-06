import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/remote_disk_usage.dart';
import '../../services/remote_process_list.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../desktop_window_manager.dart';

/// 目录磁盘占用分析（du）。
class DiskUsageApp extends StatefulWidget {
  const DiskUsageApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<DiskUsageApp> createState() => _DiskUsageAppState();
}

class _DiskUsageAppState extends State<DiskUsageApp> {
  RemoteDiskUsageSnapshot? _snap;
  bool _loading = false;
  String? _error;
  RemoteOsKind? _os;

  String get _path {
    final p = widget.window.args['path']?.toString();
    if (p != null && p.isNotEmpty) return p;
    return widget.controller.remoteCwd;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (!mounted) return;
    final connected =
        widget.controller.connected && !widget.controller.dropped;
    if (!connected) {
      setState(() {
        _error = '连接已断开';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await fetchRemoteDiskUsage(
        widget.controller,
        path: _path,
        osHint: _os,
      );
      if (!mounted) return;
      if (snap == null) {
        setState(() {
          _error = '无法获取占用';
          _loading = false;
        });
        return;
      }
      if (snap.os != RemoteOsKind.unknown) _os = snap.os;
      final titlePath = snap.path;
      final short = titlePath == '/'
          ? '占用 /'
          : titlePath.split(RegExp(r'[/\\]')).where((e) => e.isNotEmpty).last;
      if (widget.window.title != '占用 · $short') {
        widget.window.title = '占用 · $short';
        widget.wm.requestRebuild();
      }
      setState(() {
        _snap = snap;
        _loading = false;
        _error = snap.error;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _openChild(RemoteDiskUsageEntry e) {
    if (e.isTotal) return;
    final base = _path.replaceAll(RegExp(r'[/\\]+$'), '');
    final sep = _path.contains('\\') && !_path.startsWith('/') ? '\\' : '/';
    final child = base.endsWith(sep) ? '$base${e.name}' : '$base$sep${e.name}';
    widget.wm.open(
      DesktopAppType.diskUsage,
      args: {'path': child},
    );
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final snap = _snap;
    final children = [
      for (final e in snap?.entries ?? const <RemoteDiskUsageEntry>[])
        if (!e.isTotal) e,
    ];
    final total = snap?.totalBytes;
    final maxBytes = children.isEmpty
        ? 1
        : children.map((e) => e.bytes).reduce((a, b) => a > b ? a : b);

    return ColoredBox(
      color: wb.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
            child: Row(
              children: [
                Icon(Icons.pie_chart_rounded, size: 18, color: wb.accentBlue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: wb.primaryText,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
                if (_loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: '刷新',
                    iconSize: 18,
                    onPressed: () => unawaited(_load()),
                    icon: Icon(Icons.refresh_rounded, color: wb.textMuted),
                  ),
              ],
            ),
          ),
          if (total != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                '合计 ${formatUsageBytes(total)} · ${children.length} 项',
                style: TextStyle(fontSize: 12, color: wb.textMuted),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                _error!,
                style: TextStyle(color: wb.offline, fontSize: 12),
              ),
            ),
          Divider(height: 1, color: wb.border),
          Expanded(
            child: children.isEmpty
                ? Center(
                    child: Text(
                      _loading ? '分析中…（大目录可能较慢）' : '无子项数据',
                      style: TextStyle(color: wb.textMuted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    itemCount: children.length,
                    itemBuilder: (context, i) {
                      final e = children[i];
                      final frac = (e.bytes / maxBytes).clamp(0.0, 1.0);
                      final ofTotal = total != null && total > 0
                          ? e.bytes / total
                          : null;
                      return InkWell(
                        onTap: () => _openChild(e),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      e.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: wb.primaryText,
                                        fontSize: 13,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                  Text(
                                    formatUsageBytes(e.bytes),
                                    style: TextStyle(
                                      color: wb.secondaryText,
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (ofTotal != null) ...[
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      width: 40,
                                      child: Text(
                                        '${(ofTotal * 100).toStringAsFixed(0)}%',
                                        textAlign: TextAlign.right,
                                        style: TextStyle(
                                          color: wb.textMuted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: LinearProgressIndicator(
                                  value: frac,
                                  minHeight: 6,
                                  backgroundColor: wb.border,
                                  color: frac >= 0.85
                                      ? const Color(0xFFEF4444)
                                      : frac >= 0.6
                                          ? const Color(0xFFEAB308)
                                          : wb.accentBlue,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
