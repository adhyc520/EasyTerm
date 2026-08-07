import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote_packages.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../widgets/package_op_log_dialog.dart';
import '../desktop_window_manager.dart';

/// 包管理器：检测 apt/dnf/yum/pacman/brew/zypper，列表 / 搜索 / 安装 / 卸载。
/// 特权操作弹出实时日志框；需密码时再弹 sudo 授权。
class PackagesApp extends StatefulWidget {
  const PackagesApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<PackagesApp> createState() => _PackagesAppState();
}

class _PackagesAppState extends State<PackagesApp>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  RemotePackageManager _pm = RemotePackageManager.unknown;
  List<RemotePackage> _installed = const [];
  List<RemotePackage> _searchHits = const [];
  bool _loading = false;
  bool _searching = false;
  bool _busy = false;
  String? _error;
  String? _selected;
  final _filterCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _installCtrl = TextEditingController();
  final _filterFocus = FocusNode();
  final _searchFocus = FocusNode();
  final _installFocus = FocusNode();
  bool _wasFocused = false;

  bool get _connected =>
      widget.controller.connected && !widget.controller.dropped;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _wasFocused = widget.window.focused;
    widget.window.onConnectionRestored = _onRestored;
    widget.wm.addListener(_onWm);
    unawaited(_reload());
    WidgetsBinding.instance.addPostFrameCallback((_) => _claimTextFocus());
  }

  @override
  void dispose() {
    widget.window.onConnectionRestored = null;
    widget.wm.removeListener(_onWm);
    _tabs.dispose();
    _filterCtrl.dispose();
    _searchCtrl.dispose();
    _installCtrl.dispose();
    _filterFocus.dispose();
    _searchFocus.dispose();
    _installFocus.dispose();
    super.dispose();
  }

  void _onWm() {
    final focused = widget.window.focused;
    final gained = focused && !_wasFocused;
    _wasFocused = focused;
    if (gained) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _claimTextFocus());
    }
  }

  void _claimTextFocus() {
    if (!mounted || !widget.window.focused) return;
    if (_loading && _installed.isEmpty) return;
    final node = _tabs.index == 0 ? _filterFocus : _searchFocus;
    if (!node.canRequestFocus) return;
    node.requestFocus();
  }

  void _onRestored() {
    if (!mounted) return;
    setState(() => _error = null);
    unawaited(_reload());
  }

  Future<void> _reload() async {
    if (!_connected) {
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
    final snap = await fetchInstalledPackages(widget.controller);
    if (!mounted) return;
    if (snap == null) {
      setState(() {
        _loading = false;
        _error = widget.controller.lastRemoteCommandError == null
            ? '无法读取已安装包'
            : '刷新失败：${widget.controller.lastRemoteCommandError}';
      });
      return;
    }
    setState(() {
      _pm = snap.manager;
      _installed = snap.packages;
      _loading = false;
      _error = snap.error;
      if (_selected != null &&
          !snap.packages.any((p) => p.name == _selected)) {
        _selected = null;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _claimTextFocus());
  }

  List<RemotePackage> get _filteredInstalled {
    final q = _filterCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _installed;
    return [
      for (final p in _installed)
        if (p.name.toLowerCase().contains(q) ||
            p.version.toLowerCase().contains(q))
          p,
    ];
  }

  Future<void> _runSearch() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty || _pm == RemotePackageManager.unknown) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    final hits = await searchRemotePackages(
      widget.controller,
      manager: _pm,
      query: q,
    );
    if (!mounted) return;
    setState(() {
      _searching = false;
      if (hits == null) {
        _error = '搜索失败';
        _searchHits = const [];
      } else {
        _searchHits = hits;
      }
    });
  }

  Future<void> _mutate(String name, {required bool install}) async {
    if (_busy || _pm == RemotePackageManager.unknown) return;
    if (!isSafePackageName(name)) {
      setState(() => _error = '非法包名');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(install ? '安装软件包' : '卸载软件包'),
        content: Text(
          install
              ? '将安装「$name」。若远端需要 sudo，会弹出密码输入框。'
              : '将尝试卸载「$name」。此操作可能影响系统，确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(install ? '安装' : '卸载'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await showPackageOpLogDialog(
      context,
      controller: widget.controller,
      manager: _pm,
      packageName: name,
      install: install,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result == null) return;
    if (result != true) {
      setState(() => _error = install ? '安装失败，详见日志' : '卸载失败，详见日志');
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(install ? '已安装 $name' : '已卸载 $name')),
      );
    }
    await _reload();
  }

  void _openInTerminal(String command) {
    unawaited(Clipboard.setData(ClipboardData(text: command)));
    widget.wm.open(
      DesktopAppType.terminal,
      args: {'inject': command},
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已打开终端并填入命令（未自动执行）')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
          child: Row(
            children: [
              Text(
                '包管理器',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: wb.primaryText,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: wb.panelElevated,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: wb.border),
                ),
                child: Text(
                  _pm.label,
                  style: TextStyle(fontSize: 11, color: wb.textMuted),
                ),
              ),
              const Spacer(),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              IconButton(
                tooltip: '刷新',
                onPressed:
                    _connected && !_loading ? () => unawaited(_reload()) : null,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabs,
          labelColor: wb.accentBlue,
          unselectedLabelColor: wb.textMuted,
          indicatorColor: wb.accentBlue,
          tabs: [
            Tab(text: '已安装 (${_installed.length})'),
            const Tab(text: '搜索 / 安装'),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: SelectableText(
              _error!,
              style: TextStyle(color: Colors.red.shade300, fontSize: 12),
            ),
          ),
        if (_error != null && _error!.contains('sudo'))
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  final hint = mutatePackageTerminalHint(
                    _pm,
                    name: _selected ?? _installCtrl.text.trim(),
                    install: true,
                  );
                  if (hint.isNotEmpty) _openInTerminal(hint);
                },
                icon: const Icon(Icons.terminal_rounded, size: 16),
                label: const Text('在终端打开命令'),
              ),
            ),
          ),
        Expanded(
          child: _loading && _installed.isEmpty
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _installedPane(wb),
                    _searchPane(wb),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _installedPane(WorkbenchColors wb) {
    final items = _filteredInstalled;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _filterCtrl,
            focusNode: _filterFocus,
            onChanged: (_) => setState(() {}),
            style: TextStyle(fontSize: 12, color: wb.primaryText),
            decoration: InputDecoration(
              isDense: true,
              hintText: '筛选已安装（如 openjdk）…',
              hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
              prefixIcon: Icon(Icons.search, size: 16, color: wb.textMuted),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text('无匹配软件包', style: TextStyle(color: wb.textMuted)),
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final p = items[i];
                    final sel = p.name == _selected;
                    return ListTile(
                      dense: true,
                      selected: sel,
                      onTap: () => setState(() => _selected = p.name),
                      title: Text(
                        p.name,
                        style: TextStyle(
                          fontSize: 12,
                          color: wb.primaryText,
                          fontFamily: 'monospace',
                        ),
                      ),
                      subtitle: p.version.isEmpty
                          ? null
                          : Text(
                              p.version,
                              style:
                                  TextStyle(fontSize: 11, color: wb.textMuted),
                            ),
                      trailing: IconButton(
                        tooltip: '卸载',
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: Colors.red.shade300,
                        ),
                        onPressed: _busy
                            ? null
                            : () => unawaited(_mutate(p.name, install: false)),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _searchPane(WorkbenchColors wb) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  onSubmitted: (_) => unawaited(_runSearch()),
                  style: TextStyle(fontSize: 12, color: wb.primaryText),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索软件包…',
                    hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _searching ? null : () => unawaited(_runSearch()),
                child: _searching
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('搜索'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _installCtrl,
                  focusNode: _installFocus,
                  style: TextStyle(fontSize: 12, color: wb.primaryText),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '或直接输入包名安装',
                    hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () {
                        final n = _installCtrl.text.trim();
                        if (n.isNotEmpty) unawaited(_mutate(n, install: true));
                      },
                child: const Text('安装'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _searchHits.isEmpty
              ? Center(
                  child: Text(
                    '搜索结果将显示在这里',
                    style: TextStyle(color: wb.textMuted),
                  ),
                )
              : ListView.builder(
                  itemCount: _searchHits.length,
                  itemBuilder: (context, i) {
                    final p = _searchHits[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        p.name,
                        style: TextStyle(
                          fontSize: 12,
                          color: wb.primaryText,
                          fontFamily: 'monospace',
                        ),
                      ),
                      subtitle: p.description.isEmpty && p.version.isEmpty
                          ? null
                          : Text(
                              p.description.isNotEmpty
                                  ? p.description
                                  : p.version,
                              style:
                                  TextStyle(fontSize: 11, color: wb.textMuted),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: IconButton(
                        tooltip: '安装',
                        icon: Icon(
                          Icons.download_rounded,
                          size: 18,
                          color: wb.accentBlue,
                        ),
                        onPressed: _busy
                            ? null
                            : () => unawaited(_mutate(p.name, install: true)),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
