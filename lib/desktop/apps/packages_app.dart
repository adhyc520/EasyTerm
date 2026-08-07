import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote_packages.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../util/remote_paths.dart';
import '../../widgets/destructive_action_dialog.dart';
import '../../widgets/package_op_log_dialog.dart';
import '../../widgets/remote_state_view.dart';
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
  final _versionCtrl = TextEditingController();
  final _filterFocus = FocusNode();
  final _searchFocus = FocusNode();
  final _installFocus = FocusNode();
  final _versionFocus = FocusNode();
  List<String> _versionCandidates = const [];
  bool _loadingVersions = false;
  String? _versionCandidatesFor;
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
    _versionFocus.addListener(_onVersionFocus);
    unawaited(_reload());
    WidgetsBinding.instance.addPostFrameCallback((_) => _claimTextFocus());
  }

  @override
  void dispose() {
    widget.window.onConnectionRestored = null;
    widget.wm.removeListener(_onWm);
    _versionFocus.removeListener(_onVersionFocus);
    _tabs.dispose();
    _filterCtrl.dispose();
    _searchCtrl.dispose();
    _installCtrl.dispose();
    _versionCtrl.dispose();
    _filterFocus.dispose();
    _searchFocus.dispose();
    _installFocus.dispose();
    _versionFocus.dispose();
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

  void _onVersionFocus() {
    if (_versionFocus.hasFocus) {
      unawaited(_loadVersionCandidates());
    }
  }

  Future<void> _loadVersionCandidates({String? packageName}) async {
    final name = (packageName ?? _installCtrl.text).trim();
    if (!_connected ||
        name.isEmpty ||
        !isSafePackageName(name) ||
        packageVersionsCommand(_pm, name) == null) {
      if (mounted) {
        setState(() {
          _versionCandidates = const [];
          _versionCandidatesFor = null;
          _loadingVersions = false;
        });
      }
      return;
    }
    if (_loadingVersions && _versionCandidatesFor == name) return;
    setState(() {
      _loadingVersions = true;
      _versionCandidatesFor = name;
    });
    final list = await fetchPackageVersions(
      widget.controller,
      manager: _pm,
      name: name,
    );
    if (!mounted) return;
    if (_versionCandidatesFor != name) return;
    setState(() {
      _loadingVersions = false;
      _versionCandidates = list ?? const [];
    });
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
    final snap = await fetchInstalledPackages(widget.controller, limit: 400);
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

  Future<void> _mutate(
    String name, {
    required bool install,
    String? version,
  }) async {
    if (_busy || _pm == RemotePackageManager.unknown) return;
    if (!isSafePackageName(name)) {
      setState(() => _error = '非法包名');
      return;
    }
    final ver = (version ?? '').trim();
    if (install && ver.isNotEmpty && !isSafePackageVersion(ver)) {
      setState(() => _error = '非法版本号');
      return;
    }
    final bool ok;
    if (install) {
      final label = ver.isEmpty ? name : '$name@$ver';
      ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('安装软件包'),
              content: Text('将安装「$label」。若远端需要 sudo，会弹出密码输入框。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('安装'),
                ),
              ],
            ),
          ) ==
          true;
    } else {
      var body = '将尝试卸载「$name」。此操作可能影响系统，确定继续？';
      if (simulateRemoveCommand(_pm, name) != null) {
        final impact = await fetchRemoveImpact(
          widget.controller,
          manager: _pm,
          name: name,
        );
        if (!mounted) return;
        if (impact != null && impact.isNotEmpty) {
          final shown = impact.take(20).toList();
          final more = impact.length > 20 ? '\n…' : '';
          body =
              '将卸载「$name」，可能同时移除以下软件包：\n\n${shown.join('\n')}$more';
        }
      }
      ok = await confirmDestructiveAction(
        context,
        title: '卸载软件包',
        body: body,
        confirmLabel: '卸载',
      );
    }
    if (!ok || !mounted) return;
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
      version: install && ver.isNotEmpty ? ver : null,
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

  String _cwdForPackagePath(String path, List<String> all) {
    final normalized = path.replaceAll('\\', '/');
    final asDir = normalized.endsWith('/') && normalized.length > 1
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final looksLikeDir = normalized.endsWith('/') ||
        all.any((o) {
          final on = o.replaceAll('\\', '/');
          return on != asDir && on.startsWith('$asDir/');
        });
    if (looksLikeDir) return asDir.isEmpty ? '/' : asDir;
    return remoteDirname(normalized);
  }

  Future<void> _showPackageFiles(String name) async {
    if (_pm == RemotePackageManager.unknown ||
        _pm == RemotePackageManager.brew) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前包管理器不支持列出文件')),
      );
      return;
    }
    final future = listPackageFiles(
      widget.controller,
      pm: _pm,
      name: name,
    );
    if (!mounted) return;
    final wb = context.wb;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: wb.panelElevated,
          title: Text(
            '$name · 文件',
            style: TextStyle(color: wb.primaryText, fontSize: 16),
          ),
          content: SizedBox(
            width: 480,
            height: 420,
            child: FutureBuilder<List<String>?>(
              future: future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                final files = snap.data;
                if (files == null) {
                  return Center(
                    child: Text(
                      '无法列出包文件',
                      style: TextStyle(color: wb.textMuted),
                    ),
                  );
                }
                final truncated = files.length >= 500;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (truncated)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '已截断（仅前 500 条）',
                          style: TextStyle(fontSize: 11, color: wb.textMuted),
                        ),
                      ),
                    Expanded(
                      child: files.isEmpty
                          ? Center(
                              child: Text(
                                '无文件条目',
                                style: TextStyle(color: wb.textMuted),
                              ),
                            )
                          : ListView.builder(
                              itemCount: files.length,
                              itemBuilder: (context, i) {
                                final path = files[i];
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: SelectableText(
                                    path,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                      color: wb.primaryText,
                                    ),
                                  ),
                                  trailing: IconButton(
                                    tooltip: '在文件管理器打开',
                                    icon: Icon(
                                      Icons.folder_open_outlined,
                                      size: 18,
                                      color: wb.accentBlue,
                                    ),
                                    onPressed: () {
                                      final cwd =
                                          _cwdForPackagePath(path, files);
                                      Navigator.pop(ctx);
                                      widget.wm.open(
                                        DesktopAppType.files,
                                        args: {'cwd': cwd},
                                      );
                                    },
                                  ),
                                  onTap: () {
                                    final cwd =
                                        _cwdForPackagePath(path, files);
                                    Navigator.pop(ctx);
                                    widget.wm.open(
                                      DesktopAppType.files,
                                      args: {'cwd': cwd},
                                    );
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Set<String> get _installedNames => {for (final p in _installed) p.name};

  Future<void> _upgradeAll() async {
    if (_busy || _pm == RemotePackageManager.unknown) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('升级全部软件包'),
        content: Text(
          '将执行：${upgradeAllPackagesTerminalHint(_pm)}\n可能需要较长时间，确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('升级'),
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
      packageName: '',
      install: true,
      upgradeAll: true,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('升级完成')),
      );
      await _reload();
    } else if (result == false) {
      setState(() => _error = '升级失败，详见日志');
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
              if (_pm != RemotePackageManager.unknown)
                TextButton(
                  onPressed: _connected && !_busy && !_loading
                      ? () => unawaited(_upgradeAll())
                      : null,
                  child: const Text('全部升级'),
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
          child: RemoteStateView(
            state: !_connected
                ? RemoteState.disconnected
                : (_loading && _installed.isEmpty)
                    ? RemoteState.loading
                    : (_error != null && _installed.isEmpty)
                        ? RemoteState.error
                        : RemoteState.data,
            message: !_connected
                ? '未连接'
                : (_error != null && _installed.isEmpty)
                    ? _error
                    : null,
            onRetry: () => unawaited(_reload()),
            data: TabBarView(
              controller: _tabs,
              children: [
                _installedPane(wb),
                _searchPane(wb),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _installedPane(WorkbenchColors wb) {
    final items = _filteredInstalled;
    final truncated = _installed.length >= 400;
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
        if (truncated)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '已截断（仅前 400）。可用筛选缩小范围。',
                style: TextStyle(fontSize: 11, color: wb.textMuted),
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
                      onLongPress: () => unawaited(_showPackageFiles(p.name)),
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
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '查看文件',
                            icon: Icon(
                              Icons.folder_open_outlined,
                              size: 18,
                              color: wb.accentBlue,
                            ),
                            onPressed: () =>
                                unawaited(_showPackageFiles(p.name)),
                          ),
                          IconButton(
                            tooltip: '卸载',
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                              color: Colors.red.shade300,
                            ),
                            onPressed: _busy
                                ? null
                                : () =>
                                    unawaited(_mutate(p.name, install: false)),
                          ),
                        ],
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
                flex: 3,
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
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _versionCtrl,
                  focusNode: _versionFocus,
                  style: TextStyle(fontSize: 12, color: wb.primaryText),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '版本（可选）',
                    hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    suffixIcon: (_pm == RemotePackageManager.apt ||
                            _pm == RemotePackageManager.dnf ||
                            _pm == RemotePackageManager.yum)
                        ? PopupMenuButton<String>(
                            tooltip: '可选版本',
                            padding: EdgeInsets.zero,
                            icon: _loadingVersions
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    Icons.arrow_drop_down,
                                    size: 18,
                                    color: wb.textMuted,
                                  ),
                            enabled: !_busy && _connected,
                            onOpened: () => unawaited(_loadVersionCandidates()),
                            onSelected: (v) {
                              _versionCtrl.text = v;
                              _versionCtrl.selection = TextSelection.collapsed(
                                offset: v.length,
                              );
                            },
                            itemBuilder: (context) {
                              final name = _installCtrl.text.trim();
                              if (name.isEmpty || !isSafePackageName(name)) {
                                return [
                                  const PopupMenuItem(
                                    enabled: false,
                                    child: Text('先输入包名'),
                                  ),
                                ];
                              }
                              if (_loadingVersions) {
                                return [
                                  const PopupMenuItem(
                                    enabled: false,
                                    child: Text('加载中…'),
                                  ),
                                ];
                              }
                              if (_versionCandidates.isEmpty) {
                                return [
                                  const PopupMenuItem(
                                    enabled: false,
                                    child: Text('无可用版本'),
                                  ),
                                ];
                              }
                              return [
                                for (final v in _versionCandidates.take(30))
                                  PopupMenuItem(
                                    value: v,
                                    child: Text(
                                      v,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                              ];
                            },
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () {
                        final n = _installCtrl.text.trim();
                        if (n.isNotEmpty) {
                          unawaited(
                            _mutate(
                              n,
                              install: true,
                              version: _versionCtrl.text.trim(),
                            ),
                          );
                        }
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
                    final installed = _installedNames.contains(p.name);
                    return ListTile(
                      dense: true,
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              p.name,
                              style: TextStyle(
                                fontSize: 12,
                                color: wb.primaryText,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                          if (installed)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: wb.online.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '已安装',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: wb.online,
                                ),
                              ),
                            ),
                        ],
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
                        tooltip: installed ? '已安装' : '安装',
                        icon: Icon(
                          installed
                              ? Icons.check_circle_outline_rounded
                              : Icons.download_rounded,
                          size: 18,
                          color: installed ? wb.textMuted : wb.accentBlue,
                        ),
                        onPressed: _busy || installed
                            ? null
                            : () => unawaited(
                                  _mutate(
                                    p.name,
                                    install: true,
                                    version: _versionCtrl.text.trim(),
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
