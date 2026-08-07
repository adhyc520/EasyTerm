import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/browser_bookmarks_store.dart';
import '../../services/browser_history_store.dart';
import '../../services/browser_gateway_rewrite.dart';
import '../../services/remote_browser_backend.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../util/launch_external_url.dart';
import '../desktop_tab_strip.dart';
import '../desktop_window_manager.dart';
import '../widgets/desktop_scrollable_actions.dart';

/// 桌面浏览器：默认经 [GatewayBrowserBackend] 访问远端内网；可切「直连端口」。
class BrowserApp extends StatefulWidget {
  const BrowserApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final SshWorkspaceController controller;

  @override
  State<BrowserApp> createState() => _BrowserAppState();
}

class _BrowserTab implements DesktopTabModel {
  _BrowserTab({
    required this.id,
    String initialAddress = '',
    void Function(_BrowserTab tab)? onFindResult,
  })  : addressCtrl = TextEditingController(text: initialAddress),
        addressFocus = FocusNode() {
    findInteraction = FindInteractionController(
      onFindResultReceived:
          (controller, activeMatchOrdinal, numberOfMatches, isDoneCounting) {
        findActive = activeMatchOrdinal;
        findTotal = numberOfMatches;
        onFindResult?.call(this);
      },
    );
  }

  final String id;
  final TextEditingController addressCtrl;
  final FocusNode addressFocus;
  late final FindInteractionController findInteraction;
  InAppWebViewController? web;
  String? currentUrl;
  String? pageTitle;
  bool loading = false;
  double progress = 0;
  bool canGoBack = false;
  bool canGoForward = false;
  bool lastNavPublicDirect = false;
  String? pendingNavigate;
  String? error;
  DateTime lastAccessed = DateTime.now();
  int findActive = 0;
  int findTotal = 0;
  /// 自签/未验证证书已放行时为 true，用于地址栏提示。
  bool untrustedCert = false;
  /// Page zoom factor (1.0 = 100%). Clamped to [minZoom]..[maxZoom].
  double zoom = 1.0;

  static const minZoom = 0.5;
  static const maxZoom = 3.0;

  @override
  Object get tabKey => id;

  bool get showsStartPage {
    final addr = addressCtrl.text.trim();
    if (addr.isNotEmpty) return false;
    final url = (currentUrl ?? '').trim();
    return url.isEmpty || url == 'about:blank';
  }

  @override
  String get title {
    if (pageTitle != null && pageTitle!.trim().isNotEmpty) {
      return pageTitle!.trim();
    }
    final addr = addressCtrl.text.trim();
    if (addr.isEmpty) return '新标签页';
    try {
      final parsed = parseBrowserAddressBar(addr);
      final host = parsed.host;
      if (parsed.port != 80 && parsed.port != 443) {
        return '$host:${parsed.port}';
      }
      return host;
    } catch (_) {
      return addr.length > 24 ? '${addr.substring(0, 24)}…' : addr;
    }
  }

  @override
  bool get dirty => false;

  @override
  bool get pinned => false;

  void touch() => lastAccessed = DateTime.now();

  void dispose() {
    findInteraction.dispose();
    addressCtrl.dispose();
    addressFocus.dispose();
  }
}

class _BrowserAppState extends State<BrowserApp> {
  static const _maxTabs = 8;
  static const _kJsHintDismissPrefs = 'desktop_browser_js_hint_dismissed';
  static const _kZoomPrefsPrefix = 'desktop_browser_zoom_';
  static const _zoomStep = 0.1;

  final List<_BrowserTab> _tabs = [];
  int _active = 0;
  int _tabIdSeq = 0;

  RemoteBrowserBackend? _backend;
  bool _useGateway = true;
  String? _error;
  bool _booting = true;
  late final BrowserBookmarksStore _bookmarks;
  late final BrowserHistoryStore _history;
  List<BrowserBookmark> _bookmarkList = const [];
  /// null = 全部；否则按 [BrowserBookmark.displayGroup] 过滤。
  String? _bookmarkGroupFilter;
  List<String> _historyList = const [];
  bool _dismissJsHint = false;
  bool _wasConnected = false;
  bool _addressFocused = false;
  bool _wasWindowFocused = false;
  bool _findOpen = false;
  DateTime? _lastProgressUiAt;
  final _findCtrl = TextEditingController();
  final FocusNode _findFocus = FocusNode(debugLabel: 'browserFind');

  FocusNode? _boundAddressFocus;

  SshWorkspaceController get c => widget.controller;

  String get _hostKey => '${c.username}@${c.host}:${c.port}';

  _BrowserTab? get _tab => _tabs.isEmpty
      ? null
      : _tabs[_active.clamp(0, _tabs.length - 1)];

  bool get _lastNavPublicDirect => _tab?.lastNavPublicDirect ?? false;

  @override
  void initState() {
    super.initState();
    c.addListener(_onController);
    widget.wm.addListener(_onWm);
    _wasWindowFocused = widget.window.focused;
    _wasConnected = c.connected && !c.dropped;
    _bookmarks = BrowserBookmarksStore(_hostKey);
    _history = BrowserHistoryStore(_hostKey);
    final mode = widget.window.args['mode']?.toString();
    _useGateway = mode != 'direct';
    final initial = widget.window.args['url']?.toString();
    final addr = (initial != null && initial.isNotEmpty)
        ? initial
        : 'localhost:3000';
    _tabs.add(
      _BrowserTab(
        id: _nextTabId(),
        initialAddress: addr,
        onFindResult: _onTabFindResult,
      ),
    );
    _bindActiveTabFocus();
    unawaited(_loadLists());
    unawaited(_loadJsHintDismissed());
    unawaited(_boot());
  }

  void _onWm() {
    final focused = widget.window.focused;
    final lost = !focused && _wasWindowFocused;
    _wasWindowFocused = focused;
    if (lost) {
      final tab = _tab;
      if (tab != null) unawaited(_releaseWebViewKeyboard(tab));
    }
  }

  String _nextTabId() => '${++_tabIdSeq}';

  void _bindActiveTabFocus() {
    final tab = _tab;
    if (tab == null) return;
    if (identical(_boundAddressFocus, tab.addressFocus)) return;
    _boundAddressFocus?.removeListener(_onAddressFocusChange);
    _boundAddressFocus = tab.addressFocus;
    tab.addressFocus.addListener(_onAddressFocusChange);
  }

  /// WebView（PlatformView）常抢走键盘焦点；编辑地址栏时主动让出。
  void _onAddressFocusChange() {
    final tab = _tab;
    if (tab == null) return;
    final focused = tab.addressFocus.hasFocus;
    final gained = focused && !_addressFocused;
    if (_addressFocused != focused) {
      setState(() => _addressFocused = focused);
    }
    if (!focused) return;
    if (gained) {
      final text = tab.addressCtrl.text;
      tab.addressCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: text.length,
      );
    }
    unawaited(_releaseWebViewKeyboard(tab));
  }

  Future<void> _releaseWebViewKeyboard(_BrowserTab tab) async {
    final web = tab.web;
    if (web == null) return;
    try {
      await web.clearFocus();
    } catch (_) {}
    try {
      await web.evaluateJavascript(
        source:
            'try{document.activeElement&&document.activeElement.blur()}catch(e){}',
      );
    } catch (_) {}
  }

  Future<void> _loadJsHintDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dismissed = prefs.getBool(_kJsHintDismissPrefs) ?? false;
      if (!mounted) return;
      if (dismissed) setState(() => _dismissJsHint = true);
    } catch (_) {}
  }

  Future<void> _dismissJsHintPersist() async {
    setState(() => _dismissJsHint = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kJsHintDismissPrefs, true);
    } catch (_) {}
  }

  Future<void> _loadLists() async {
    final bookmarks = await _bookmarks.load();
    final history = await _history.load();
    if (!mounted) return;
    setState(() {
      _bookmarkList = bookmarks;
      _historyList = history;
    });
  }

  List<String> get _filteredHistorySuggestions {
    final tab = _tab;
    if (tab == null || !_addressFocused) return const [];
    final q = tab.addressCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _historyList.take(8).toList();
    // 前缀匹配优先，便于地址栏 inline 补全（B9）。
    final prefix = <String>[];
    final rest = <String>[];
    for (final h in _historyList) {
      final hl = h.toLowerCase();
      if (hl.startsWith(q)) {
        prefix.add(h);
      } else if (hl.contains(q)) {
        rest.add(h);
      }
      if (prefix.length + rest.length >= 8) break;
    }
    return [...prefix, ...rest].take(8).toList();
  }

  /// 首条历史与当前输入共享前缀时，填入并选中补全段（B9）。
  void _tryInlineAddressComplete(_BrowserTab tab) {
    final ctrl = tab.addressCtrl;
    final q = ctrl.text;
    if (q.isEmpty) return;
    final sel = ctrl.selection;
    // 已有选区（含上次补全高亮）或光标不在末尾时不打扰。
    if (!sel.isCollapsed || sel.baseOffset != q.length) return;
    final ql = q.toLowerCase();
    String? match;
    for (final h in _historyList) {
      final hl = h.toLowerCase();
      if (hl.startsWith(ql) && h.length > q.length) {
        match = h;
        break;
      }
    }
    if (match == null) return;
    ctrl.value = TextEditingValue(
      text: match,
      selection: TextSelection(
        baseOffset: q.length,
        extentOffset: match.length,
      ),
    );
  }

  @override
  void dispose() {
    c.removeListener(_onController);
    widget.wm.removeListener(_onWm);
    _boundAddressFocus?.removeListener(_onAddressFocusChange);
    _findCtrl.dispose();
    _findFocus.dispose();
    unawaited(_backend?.close());
    _backend = null;
    for (final t in _tabs) {
      t.dispose();
    }
    super.dispose();
  }

  void _onTabFindResult(_BrowserTab tab) {
    if (!mounted || !identical(tab, _tab) || !_findOpen) return;
    setState(() {});
  }

  void _toggleFind() {
    final tab = _tab;
    final next = !_findOpen;
    setState(() => _findOpen = next);
    if (!next) {
      unawaited(tab?.findInteraction.clearMatches());
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _findFocus.requestFocus();
    });
    if (_findCtrl.text.isNotEmpty) {
      unawaited(_runFind());
    }
  }

  Future<void> _runFind() async {
    final tab = _tab;
    if (tab == null) return;
    final q = _findCtrl.text;
    if (q.isEmpty) {
      await tab.findInteraction.clearMatches();
      setState(() {
        tab.findActive = 0;
        tab.findTotal = 0;
      });
      return;
    }
    await tab.findInteraction.findAll(find: q);
  }

  Future<void> _findNext({bool forward = true}) async {
    final tab = _tab;
    if (tab == null) return;
    if (_findCtrl.text.isEmpty) return;
    await tab.findInteraction.findNext(forward: forward);
  }

  void _onController() {
    if (!mounted) return;
    final nowConnected = c.connected && !c.dropped;

    if (!nowConnected) {
      unawaited(_backend?.close());
      _backend = null;
      _wasConnected = false;
      setState(() {});
      return;
    }

    if (!_wasConnected) {
      _wasConnected = true;
      unawaited(_rebindAfterReconnect());
      return;
    }
  }

  Future<void> _rebindAfterReconnect() async {
    setState(() {
      _error = null;
      _booting = true;
    });
    try {
      await _ensureBackend();
      if (!mounted) return;
      setState(() => _booting = false);
      final tab = _tab;
      final url = tab?.addressCtrl.text.trim() ?? '';
      if (url.isNotEmpty) {
        await _navigate(url, tab: tab);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _error = '$e';
      });
    }
  }

  Future<void> _boot() async {
    setState(() {
      _booting = true;
      _error = null;
    });
    try {
      await _ensureBackend();
      if (!mounted) return;
      setState(() => _booting = false);
      final tab = _tab;
      if (tab == null) return;
      tab.pendingNavigate = tab.addressCtrl.text;
      if (tab.web != null) {
        await _navigate(tab.pendingNavigate!, tab: tab);
        tab.pendingNavigate = null;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _error = '$e';
      });
    }
  }

  Future<void> _ensureBackend() async {
    await _backend?.close();
    _backend = null;
    if (c.clientForDesktop == null) {
      throw StateError('SSH 未连接');
    }
    if (_useGateway) {
      final gw = await c.getOrCreateGateway();
      _backend = GatewayBrowserBackend(gw);
    } else {
      _backend = LocalForwardBrowserBackend(
        openForward: (host, port) => c.openLocalForward(host, port),
        releaseForward: c.releaseLocalForward,
      );
    }
  }

  Future<void> _navigate(String raw, {_BrowserTab? tab}) async {
    final t = tab ?? _tab;
    if (t == null) return;
    final input = raw.trim();
    if (input.isEmpty) return;
    if (!c.connected || c.clientForDesktop == null) {
      setState(() {
        t.error = '未连接';
        _error = '未连接';
      });
      return;
    }
    _patchTab(t, () {
      t.loading = true;
      t.error = null;
    });
    try {
      if (_backend == null) await _ensureBackend();
      final parsed = parseBrowserAddressBar(input);
      final publicDirect = !isSshTunneledBrowserHost(parsed.host);
      final uri = await _backend!.resolveUrl(input);
      widget.window.args['url'] = input;
      widget.window.args['mode'] = _useGateway ? 'gateway' : 'direct';
      // Avoid focus()+notifyListeners on every navigate — that rebuilds the
      // whole desktop (all PlatformViews) and can freeze the app.
      if (!widget.window.focused) {
        widget.wm.focus(widget.window.id);
      }
      final hist = await _history.push(input);
      t.addressCtrl.text = input;
      t.lastNavPublicDirect = publicDirect;
      await _restoreZoom(t);
      await t.web?.loadUrl(urlRequest: URLRequest(url: WebUri(uri.toString())));
      unawaited(_applyZoom(t));
      if (mounted) {
        setState(() {
          t.error = null;
          _historyList = hist;
        });
        _syncWindowTitle();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        t.error = '$e';
        t.loading = false;
      });
    }
  }

  /// 地址栏聚焦时避免整树 setState 打断输入；否则正常刷新 UI。
  void _patchTab(_BrowserTab tab, VoidCallback fn) {
    if (identical(tab, _tab) && tab.addressFocus.hasFocus) {
      fn();
      return;
    }
    setState(fn);
  }

  void _selectTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    setState(() {
      _active = index;
      _tabs[index].touch();
    });
    _bindActiveTabFocus();
    _syncWindowTitle();
  }

  void _addBlankTab({String address = ''}) {
    if (_tabs.length >= _maxTabs) return;
    setState(() {
      _tabs.add(
        _BrowserTab(
          id: _nextTabId(),
          initialAddress: address,
          onFindResult: _onTabFindResult,
        ),
      );
      _active = _tabs.length - 1;
      _tabs[_active].touch();
    });
    _bindActiveTabFocus();
    _syncWindowTitle();
  }

  /// 达上限时复用最久未访问的非当前标签，否则在当前标签打开。
  _BrowserTab _tabForNewWindow() {
    if (_tabs.length < _maxTabs) {
      _addBlankTab();
      return _tabs[_active];
    }
    _BrowserTab? lru;
    for (var i = 0; i < _tabs.length; i++) {
      if (i == _active) continue;
      final candidate = _tabs[i];
      if (lru == null ||
          candidate.lastAccessed.isBefore(lru.lastAccessed)) {
        lru = candidate;
      }
    }
    if (lru != null) {
      setState(() {
        _active = _tabs.indexOf(lru!);
        lru.touch();
      });
      _bindActiveTabFocus();
      return lru;
    }
    _tab?.touch();
    return _tab!;
  }

  Future<bool> _handleCreateWindow(
    InAppWebViewController controller,
    CreateWindowAction action,
  ) async {
    final req = action.request;
    final url = req.url?.toString();
    if (url == null || url.isEmpty) return false;
    final tab = _tabForNewWindow();
    tab.addressCtrl.text = url;
    tab.pendingNavigate = url;
    if (tab.web != null) {
      await _navigate(url, tab: tab);
      tab.pendingNavigate = null;
    }
    return true;
  }

  Future<void> _closeTab(int index) async {
    if (index < 0 || index >= _tabs.length) return;
    if (_tabs.length == 1) {
      final tab = _tabs[0];
      setState(() {
        tab.addressCtrl.clear();
        tab.pageTitle = null;
        tab.currentUrl = null;
        tab.loading = false;
        tab.progress = 0;
        tab.canGoBack = false;
        tab.canGoForward = false;
        tab.lastNavPublicDirect = false;
        tab.pendingNavigate = null;
        tab.error = null;
        tab.untrustedCert = false;
        tab.zoom = 1.0;
      });
      _syncWindowTitle();
      return;
    }
    final tab = _tabs[index];
    tab.dispose();
    setState(() {
      _tabs.removeAt(index);
      if (_active >= _tabs.length) {
        _active = _tabs.length - 1;
      } else if (_active > index) {
        _active--;
      }
      _tabs[_active].touch();
    });
    _bindActiveTabFocus();
    _syncWindowTitle();
  }

  void _reorderTabs(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final tab = _tabs.removeAt(oldIndex);
      _tabs.insert(newIndex, tab);
      if (_active == oldIndex) {
        _active = newIndex;
      } else if (oldIndex < _active && newIndex >= _active) {
        _active--;
      } else if (oldIndex > _active && newIndex <= _active) {
        _active++;
      }
    });
  }

  String _shortHost(String input) {
    try {
      final parsed = parseBrowserAddressBar(input);
      final host = parsed.host;
      if (parsed.port != 80 && parsed.port != 443) {
        return '$host:${parsed.port}';
      }
      return host;
    } catch (_) {
      return input.length > 24 ? '${input.substring(0, 24)}…' : input;
    }
  }

  void _syncWindowTitle() {
    final tab = _tab;
    if (tab == null) {
      widget.window.title = '浏览器';
    } else if (tab.pageTitle != null && tab.pageTitle!.trim().isNotEmpty) {
      widget.window.title = tab.pageTitle!.trim();
    } else {
      final addr = tab.addressCtrl.text.trim();
      widget.window.title = addr.isEmpty ? '浏览器' : _shortHost(addr);
    }
    widget.wm.requestRebuild();
  }

  Future<void> _toggleMode() async {
    final switchingToDirect = _useGateway;
    final tab = _tab;
    if (switchingToDirect && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final wb = ctx.wb;
          return AlertDialog(
            backgroundColor: wb.panelElevated,
            title: Text('切换到直连', style: TextStyle(color: wb.primaryText)),
            content: Text(
              '直连只转发当前地址栏的 host:port，站内跳到其他主机/端口可能失败。\n\n'
              '当前目标：${tab == null || tab.addressCtrl.text.trim().isEmpty ? '（空）' : tab.addressCtrl.text.trim()}',
              style: TextStyle(color: wb.secondaryText, height: 1.4),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('直连'),
              ),
            ],
          );
        },
      );
      if (ok != true || !mounted) return;
    }
    setState(() {
      _useGateway = !_useGateway;
      _error = null;
    });
    widget.window.args['mode'] = _useGateway ? 'gateway' : 'direct';
    widget.wm.requestRebuild();
    try {
      await _ensureBackend();
      final addr = _tab?.addressCtrl.text ?? '';
      if (addr.trim().isNotEmpty) {
        await _navigate(addr);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _toggleBookmark() async {
    final tab = _tab;
    if (tab == null) return;
    final addr = tab.addressCtrl.text.trim();
    if (addr.isEmpty) return;
    if (_bookmarkList.any((b) => b.url == addr)) {
      await _removeBookmark(addr);
    } else {
      await _addBookmark();
    }
  }

  Future<void> _addBookmark() async {
    final tab = _tab;
    if (tab == null) return;
    final pageTitle = tab.pageTitle?.trim();
    final list = await _bookmarks.add(
      tab.addressCtrl.text,
      title: (pageTitle != null && pageTitle.isNotEmpty) ? pageTitle : null,
    );
    if (!mounted) return;
    setState(() => _bookmarkList = list);
  }

  List<String> get _bookmarkGroups {
    final seen = <String>{};
    final out = <String>[];
    for (final b in _bookmarkList) {
      final g = b.displayGroup;
      if (seen.add(g)) out.add(g);
    }
    return out;
  }

  List<BrowserBookmark> get _filteredBookmarks {
    final filter = _bookmarkGroupFilter;
    if (filter == null) return _bookmarkList;
    return _bookmarkList.where((b) => b.displayGroup == filter).toList();
  }

  Future<void> _renameBookmark(String url) async {
    final i = _bookmarkList.indexWhere((b) => b.url == url);
    if (i < 0 || !mounted) return;
    final existing = _bookmarkList[i];
    final titleCtrl = TextEditingController(text: existing.displayTitle);
    final groupCtrl = TextEditingController(
      text: existing.group.trim().isEmpty ? '' : existing.group,
    );
    final next = await showDialog<({String title, String group})>(
      context: context,
      builder: (ctx) {
        final wb = ctx.wb;
        return AlertDialog(
          backgroundColor: wb.panelElevated,
          title: Text('重命名书签', style: TextStyle(color: wb.primaryText)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                autofocus: true,
                style: TextStyle(color: wb.primaryText),
                decoration: InputDecoration(
                  labelText: '标题',
                  hintText: existing.url,
                  hintStyle: TextStyle(color: wb.textMuted),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: groupCtrl,
                style: TextStyle(color: wb.primaryText),
                decoration: InputDecoration(
                  labelText: '分组（可选）',
                  hintText: '默认',
                  hintStyle: TextStyle(color: wb.textMuted),
                ),
                onSubmitted: (_) => Navigator.pop(ctx, (
                  title: titleCtrl.text,
                  group: groupCtrl.text,
                )),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, (
                title: titleCtrl.text,
                group: groupCtrl.text,
              )),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    titleCtrl.dispose();
    groupCtrl.dispose();
    if (next == null || !mounted) return;
    final list = await _bookmarks.rename(
      url,
      next.title,
      group: next.group,
    );
    if (!mounted) return;
    setState(() {
      _bookmarkList = list;
      if (_bookmarkGroupFilter != null &&
          !_bookmarkGroups.contains(_bookmarkGroupFilter)) {
        _bookmarkGroupFilter = null;
      }
    });
  }

  Future<void> _openDevTools() async {
    final web = _tab?.web;
    if (web == null) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('当前平台不支持')),
      );
      return;
    }
    try {
      await web.openDevTools();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('当前平台不支持')),
      );
    }
  }

  Future<void> _openExternal() async {
    final tab = _tab;
    if (tab == null) return;
    final input = tab.addressCtrl.text.trim();
    if (input.isEmpty) return;
    final uri = externalBrowserNavigationUri(input);
    if (uri == null) {
      setState(
        () => _error = '内网地址需经 SSH 在应用内浏览，无法用系统浏览器打开',
      );
      return;
    }
    try {
      await launchExternalBrowserUri(uri);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '外部打开失败：$e');
    }
  }

  Future<void> _removeBookmark(String url) async {
    final list = await _bookmarks.remove(url);
    if (!mounted) return;
    setState(() {
      _bookmarkList = list;
      if (_bookmarkGroupFilter != null &&
          !_bookmarkGroups.contains(_bookmarkGroupFilter)) {
        _bookmarkGroupFilter = null;
      }
    });
  }

  Future<void> _clearHistory() async {
    final list = await _history.clear();
    if (!mounted) return;
    setState(() => _historyList = list);
  }

  Future<void> _removeHistory(String url) async {
    final list = await _history.remove(url);
    if (!mounted) return;
    setState(() => _historyList = list);
  }

  String? _hostForZoom(_BrowserTab tab) {
    final raw = tab.addressCtrl.text.trim();
    if (raw.isEmpty) {
      final url = (tab.currentUrl ?? '').trim();
      if (url.isEmpty || url == 'about:blank') return null;
      try {
        return Uri.parse(url).host;
      } catch (_) {
        return null;
      }
    }
    try {
      return parseBrowserAddressBar(raw).host;
    } catch (_) {
      return raw;
    }
  }

  Future<void> _restoreZoom(_BrowserTab tab) async {
    final host = _hostForZoom(tab);
    if (host == null || host.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble('$_kZoomPrefsPrefix$host');
      if (saved == null) return;
      final next = saved.clamp(_BrowserTab.minZoom, _BrowserTab.maxZoom);
      if ((tab.zoom - next).abs() < 0.001) return;
      tab.zoom = next;
      await _applyZoom(tab);
    } catch (_) {}
  }

  Future<void> _persistZoom(_BrowserTab tab) async {
    final host = _hostForZoom(tab);
    if (host == null || host.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('$_kZoomPrefsPrefix$host', tab.zoom);
    } catch (_) {}
  }

  Future<void> _applyZoom(_BrowserTab tab) async {
    final web = tab.web;
    if (web == null) return;
    // Prefer absolute pageZoom (macOS/iOS WKWebView). textZoom covers Android.
    // No setZoomScale API in flutter_inappwebview 6.x.
    try {
      await web.setSettings(
        settings: InAppWebViewSettings(
          pageZoom: tab.zoom,
          textZoom: (tab.zoom * 100).round(),
        ),
      );
    } catch (_) {}
  }

  void _nudgeZoom(double delta) {
    final tab = _tab;
    if (tab == null || tab.showsStartPage) return;
    unawaited(_setZoom(tab.zoom + delta));
  }

  Future<void> _setZoom(double value) async {
    final tab = _tab;
    if (tab == null) return;
    final next = value.clamp(_BrowserTab.minZoom, _BrowserTab.maxZoom);
    if ((tab.zoom - next).abs() < 0.001) return;
    setState(() => tab.zoom = next);
    await _applyZoom(tab);
    unawaited(_persistZoom(tab));
    if (!mounted) return;
    final pct = (tab.zoom * 100).round();
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('缩放 $pct%'),
        duration: const Duration(milliseconds: 900),
      ),
    );
  }

  String _suggestedDownloadName(DownloadStartRequest req) {
    final suggested = req.suggestedFilename?.trim();
    if (suggested != null && suggested.isNotEmpty) return suggested;
    final path = req.url.path;
    if (path.isNotEmpty) {
      final base = p.basename(path);
      if (base.isNotEmpty && base != '/' && base != '.') return base;
    }
    return 'download';
  }

  void _onDownloadStartRequest(
    _BrowserTab tab,
    DownloadStartRequest request,
  ) {
    if (!mounted) return;
    final url = request.url.toString();
    final name = _suggestedDownloadName(request);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('下载：$name', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
              url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              children: [
                TextButton(
                  onPressed: () {
                    messenger.hideCurrentSnackBar();
                    unawaited(_saveDownload(url: url, filename: name));
                  },
                  child: const Text('保存'),
                ),
                TextButton(
                  onPressed: () {
                    messenger.hideCurrentSnackBar();
                    unawaited(Clipboard.setData(ClipboardData(text: url)));
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('已复制下载链接'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: const Text('复制链接'),
                ),
                TextButton(
                  onPressed: () {
                    messenger.hideCurrentSnackBar();
                    unawaited(_openDownloadExternally(url));
                  },
                  child: const Text('外部打开'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDownloadExternally(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('无法用系统浏览器打开该链接')),
      );
      return;
    }
    try {
      await launchExternalBrowserUri(uri);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('外部打开失败：$e')),
      );
    }
  }

  Future<void> _saveDownload({
    required String url,
    required String filename,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      var safe = filename.replaceAll(RegExp(r'[\\/:*?"<>|\0]'), '_').trim();
      if (safe.isEmpty) safe = 'download';

      Directory? dir;
      try {
        dir = await getDownloadsDirectory();
      } catch (_) {}
      dir ??= await getApplicationDocumentsDirectory();

      var outPath = p.join(dir.path, safe);
      if (await File(outPath).exists()) {
        final stem = p.basenameWithoutExtension(safe);
        final ext = p.extension(safe);
        var i = 1;
        do {
          outPath = p.join(dir.path, '$stem ($i)$ext');
          i++;
        } while (await File(outPath).exists());
      }

      final res = await http.get(Uri.parse(url));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('HTTP ${res.statusCode}');
      }
      await File(outPath).writeAsBytes(res.bodyBytes, flush: true);
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(
          content: Text('已保存：${p.basename(outPath)}'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: '复制路径',
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: outPath)));
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(
          content: Text('保存失败：$e'),
          action: SnackBarAction(
            label: '复制链接',
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: url)));
            },
          ),
        ),
      );
    }
  }

  Future<void> _refreshNavFlags(_BrowserTab tab) async {
    final w = tab.web;
    if (w == null) return;
    final back = await w.canGoBack();
    final forward = await w.canGoForward();
    if (!mounted) return;
    if (tab.canGoBack == back && tab.canGoForward == forward) return;
    if (identical(tab, _tab) && tab.addressFocus.hasFocus) {
      tab.canGoBack = back;
      tab.canGoForward = forward;
      return;
    }
    setState(() {
      tab.canGoBack = back;
      tab.canGoForward = forward;
    });
  }

  void _syncAddressFromLoad(_BrowserTab tab, WebUri? url) {
    if (url == null) return;
    tab.currentUrl = url.toString();
    final host = url.host.toLowerCase();
    final isLoopback = host == '127.0.0.1' || host == 'localhost';
    if (isLoopback) {
      tab.lastNavPublicDirect = false;
      return;
    }
    final display = url.toString();
    if (tab.addressCtrl.text == display) {
      tab.lastNavPublicDirect = true;
      return;
    }
    if (tab.addressFocus.hasFocus) return;
    tab.addressCtrl.text = display;
    tab.lastNavPublicDirect = true;
  }

  Widget _buildWebView(_BrowserTab tab) {
    return InAppWebView(
      key: ValueKey('wv-${widget.window.id}-${tab.id}'),
      findInteractionController: tab.findInteraction,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
        supportMultipleWindows: true,
        transparentBackground: false,
        isFraudulentWebsiteWarningEnabled: false,
        allowsInlineMediaPlayback: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        useShouldOverrideUrlLoading: false,
        useOnDownloadStart: true,
        supportZoom: true,
        pageZoom: tab.zoom,
        textZoom: (tab.zoom * 100).round(),
      ),
      onWebViewCreated: (controller) {
        tab.web = controller;
        unawaited(_applyZoom(tab));
        final pending = tab.pendingNavigate;
        if (pending != null && pending.isNotEmpty) {
          tab.pendingNavigate = null;
          unawaited(_navigate(pending, tab: tab));
        }
      },
      onCreateWindow: (controller, action) =>
          _handleCreateWindow(controller, action),
      onDownloadStartRequest: (controller, request) {
        _onDownloadStartRequest(tab, request);
      },
      onTitleChanged: (controller, title) {
        if (title == null || title.trim().isEmpty) return;
        tab.pageTitle = title.trim();
        if (identical(tab, _tab)) {
          if (tab.addressFocus.hasFocus) {
            _syncWindowTitle();
            return;
          }
          setState(() {});
          _syncWindowTitle();
        }
      },
      onLoadStart: (controller, url) {
        // 新导航先清除；若仍需放行自签证书，会再次触发 trust 回调。
        final clearedCert = tab.untrustedCert;
        tab.untrustedCert = false;
        if (identical(tab, _tab) && tab.addressFocus.hasFocus) {
          tab.loading = true;
          tab.progress = 0;
          if (clearedCert) setState(() {});
          return;
        }
        setState(() {
          tab.loading = true;
          tab.progress = 0;
        });
        _syncAddressFromLoad(tab, url);
      },
      onProgressChanged: (controller, progress) {
        final p = progress / 100.0;
        tab.progress = p;
        if (identical(tab, _tab) && tab.addressFocus.hasFocus) return;
        // Progress fires many times per navigation; rebuilding the whole app
        // (incl. PlatformView WebViews) on every tick can freeze the UI.
        final now = DateTime.now();
        final last = _lastProgressUiAt;
        if (progress < 100 &&
            last != null &&
            now.difference(last) < const Duration(milliseconds: 100)) {
          return;
        }
        _lastProgressUiAt = now;
        setState(() {});
      },
      onLoadStop: (controller, url) async {
        if (!(identical(tab, _tab) && tab.addressFocus.hasFocus)) {
          setState(() {
            tab.loading = false;
            tab.progress = 1;
          });
        } else {
          tab.loading = false;
          tab.progress = 1;
        }
        _syncAddressFromLoad(tab, url);
        await _refreshNavFlags(tab);
        await _restoreZoom(tab);
        await _applyZoom(tab);
        if (identical(tab, _tab)) _syncWindowTitle();
      },
      onReceivedError: (controller, request, error) {
        setState(() {
          tab.loading = false;
          tab.error = error.description;
        });
      },
      onWindowFocus: (controller) {
        if (identical(tab, _tab) && tab.addressFocus.hasFocus) {
          unawaited(_releaseWebViewKeyboard(tab));
          tab.addressFocus.requestFocus();
        }
      },
      onReceivedServerTrustAuthRequest: (controller, challenge) async {
        tab.untrustedCert = true;
        if (identical(tab, _tab) && mounted) {
          setState(() {});
        }
        return ServerTrustAuthResponse(
          action: ServerTrustAuthResponseAction.PROCEED,
        );
      },
    );
  }

  Widget _buildTabSurface(_BrowserTab tab) {
    final start = tab.showsStartPage;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          ignoring: start,
          child: _buildWebView(tab),
        ),
        if (start)
          _BrowserStartPage(
            bookmarks: _filteredBookmarks,
            bookmarkGroups: _bookmarkGroups,
            bookmarkGroupFilter: _bookmarkGroupFilter,
            onBookmarkGroupFilter: (g) =>
                setState(() => _bookmarkGroupFilter = g),
            history: _historyList,
            onOpen: (url) => unawaited(_navigate(url, tab: tab)),
            onRenameBookmark: (url) => unawaited(_renameBookmark(url)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final offline = !c.connected || c.dropped;
    final tab = _tab;
    final suggestions = _filteredHistorySuggestions;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyT, meta: true): () =>
            _addBlankTab(),
        const SingleActivator(LogicalKeyboardKey.keyT, control: true): () =>
            _addBlankTab(),
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true): () =>
            unawaited(_closeTab(_active)),
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () =>
            unawaited(_closeTab(_active)),
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): () {
          unawaited(_tab?.web?.reload());
        },
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): () {
          unawaited(_tab?.web?.reload());
        },
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true): () {
          final t = _tab;
          if (t == null) return;
          t.addressFocus.requestFocus();
          final text = t.addressCtrl.text;
          t.addressCtrl.selection = TextSelection(
            baseOffset: 0,
            extentOffset: text.length,
          );
          unawaited(_releaseWebViewKeyboard(t));
        },
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
          final t = _tab;
          if (t == null) return;
          t.addressFocus.requestFocus();
          final text = t.addressCtrl.text;
          t.addressCtrl.selection = TextSelection(
            baseOffset: 0,
            extentOffset: text.length,
          );
          unawaited(_releaseWebViewKeyboard(t));
        },
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _toggleFind,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _toggleFind,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_findOpen) {
            setState(() => _findOpen = false);
            unawaited(_tab?.findInteraction.clearMatches());
          }
        },
        const SingleActivator(LogicalKeyboardKey.tab, control: true): () {
          if (_tabs.isEmpty) return;
          _selectTab((_active + 1) % _tabs.length);
        },
        const SingleActivator(LogicalKeyboardKey.tab, meta: true): () {
          if (_tabs.isEmpty) return;
          _selectTab((_active + 1) % _tabs.length);
        },
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () {
          if (_tabs.isNotEmpty) _selectTab(0);
        },
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true): () {
          if (_tabs.length > 1) _selectTab(1);
        },
        const SingleActivator(LogicalKeyboardKey.digit3, meta: true): () {
          if (_tabs.length > 2) _selectTab(2);
        },
        const SingleActivator(LogicalKeyboardKey.digit4, meta: true): () {
          if (_tabs.length > 3) _selectTab(3);
        },
        const SingleActivator(LogicalKeyboardKey.digit5, meta: true): () {
          if (_tabs.length > 4) _selectTab(4);
        },
        const SingleActivator(LogicalKeyboardKey.digit6, meta: true): () {
          if (_tabs.length > 5) _selectTab(5);
        },
        const SingleActivator(LogicalKeyboardKey.digit7, meta: true): () {
          if (_tabs.length > 6) _selectTab(6);
        },
        const SingleActivator(LogicalKeyboardKey.digit8, meta: true): () {
          if (_tabs.length > 7) _selectTab(7);
        },
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () {
          if (_tabs.isNotEmpty) _selectTab(0);
        },
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () {
          if (_tabs.length > 1) _selectTab(1);
        },
        const SingleActivator(LogicalKeyboardKey.digit3, control: true): () {
          if (_tabs.length > 2) _selectTab(2);
        },
        const SingleActivator(LogicalKeyboardKey.digit4, control: true): () {
          if (_tabs.length > 3) _selectTab(3);
        },
        const SingleActivator(LogicalKeyboardKey.digit5, control: true): () {
          if (_tabs.length > 4) _selectTab(4);
        },
        const SingleActivator(LogicalKeyboardKey.digit6, control: true): () {
          if (_tabs.length > 5) _selectTab(5);
        },
        const SingleActivator(LogicalKeyboardKey.digit7, control: true): () {
          if (_tabs.length > 6) _selectTab(6);
        },
        const SingleActivator(LogicalKeyboardKey.digit8, control: true): () {
          if (_tabs.length > 7) _selectTab(7);
        },
        const SingleActivator(LogicalKeyboardKey.equal, meta: true): () =>
            _nudgeZoom(_zoomStep),
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () =>
            _nudgeZoom(_zoomStep),
        const SingleActivator(LogicalKeyboardKey.equal, meta: true, shift: true):
            () => _nudgeZoom(_zoomStep),
        const SingleActivator(
          LogicalKeyboardKey.equal,
          control: true,
          shift: true,
        ): () => _nudgeZoom(_zoomStep),
        const SingleActivator(LogicalKeyboardKey.add, meta: true): () =>
            _nudgeZoom(_zoomStep),
        const SingleActivator(LogicalKeyboardKey.add, control: true): () =>
            _nudgeZoom(_zoomStep),
        const SingleActivator(LogicalKeyboardKey.minus, meta: true): () =>
            _nudgeZoom(-_zoomStep),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () =>
            _nudgeZoom(-_zoomStep),
        const SingleActivator(LogicalKeyboardKey.digit0, meta: true): () =>
            unawaited(_setZoom(1.0)),
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): () =>
            unawaited(_setZoom(1.0)),
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: wb.panel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: wb.panelElevated,
                child: Row(
                  children: [
                    Expanded(
                      child: DesktopTabStrip<_BrowserTab>(
                        tabs: _tabs,
                        activeIndex: _active,
                        maxTabs: _maxTabs,
                        onSelect: _selectTab,
                        onClose: (i) => unawaited(_closeTab(i)),
                        onReorder: _reorderTabs,
                        buildIcon: (context, tab) {
                          if (!tab.loading) return null;
                          return SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: context.wb.accentBlue,
                            ),
                          );
                        },
                      ),
                    ),
                    IconButton(
                      tooltip: _tabs.length >= _maxTabs
                          ? '已达 $_maxTabs 个标签上限'
                          : '新标签',
                      onPressed: _tabs.length >= _maxTabs
                          ? null
                          : () => _addBlankTab(),
                      icon: Icon(
                        Icons.add,
                        size: 18,
                        color: _tabs.length >= _maxTabs
                            ? wb.textMuted
                            : wb.primaryText,
                      ),
                    ),
                  ],
                ),
              ),
              if (tab != null)
                _Toolbar(
              addressCtrl: tab.addressCtrl,
              addressFocus: tab.addressFocus,
              loading: tab.loading,
              progress: tab.progress,
              canGoBack: tab.canGoBack,
              canGoForward: tab.canGoForward,
              modeLabel: _backend?.modeLabel ?? (_useGateway ? '网关' : '直连'),
              useGateway: _useGateway,
              offline: offline,
              bookmarks: _bookmarkList,
              bookmarkGroups: _bookmarkGroups,
              bookmarkGroupFilter: _bookmarkGroupFilter,
              onBookmarkGroupFilter: (g) =>
                  setState(() => _bookmarkGroupFilter = g),
              history: _historyList,
              currentAddress: tab.addressCtrl.text.trim(),
              currentUrl: tab.currentUrl ?? tab.addressCtrl.text.trim(),
              untrustedCert: tab.untrustedCert,
              historySuggestions: suggestions,
              showHistorySuggestions:
                  _addressFocused && suggestions.isNotEmpty,
              onBack: () async {
                await tab.web?.goBack();
                await _refreshNavFlags(tab);
              },
              onForward: () async {
                await tab.web?.goForward();
                await _refreshNavFlags(tab);
              },
              onReload: () async {
                await tab.web?.reload();
              },
              onSubmit: () => unawaited(_navigate(tab.addressCtrl.text)),
              onAddressTap: () {
                if (!tab.addressFocus.hasFocus) {
                  tab.addressFocus.requestFocus();
                }
                final t = tab.addressCtrl.text;
                tab.addressCtrl.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: t.length,
                );
                unawaited(_releaseWebViewKeyboard(tab));
              },
              onAddressChanged: () {
                final t = _tab;
                if (t != null) _tryInlineAddressComplete(t);
                if (_addressFocused) setState(() {});
              },
              onPickHistorySuggestion: (url) {
                tab.addressFocus.unfocus();
                unawaited(_navigate(url));
              },
              onToggleMode: () => unawaited(_toggleMode()),
              onToggleBookmark: () => unawaited(_toggleBookmark()),
              onOpenExternal: () => unawaited(_openExternal()),
              onOpenBookmark: (url) => unawaited(_navigate(url)),
              onRemoveBookmark: (url) => unawaited(_removeBookmark(url)),
              onRenameBookmark: (url) => unawaited(_renameBookmark(url)),
              onOpenHistory: (url) => unawaited(_navigate(url)),
              onRemoveHistory: (url) => unawaited(_removeHistory(url)),
              onClearHistory: () => unawaited(_clearHistory()),
              onToggleFind: _toggleFind,
              onOpenDevTools: () => unawaited(_openDevTools()),
            ),
          if (tab != null && _findOpen)
            Material(
              color: wb.panelElevated,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _findCtrl,
                        focusNode: _findFocus,
                        style: TextStyle(fontSize: 13, color: wb.primaryText),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '在页面中查找',
                          hintStyle: TextStyle(color: wb.textMuted),
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) => unawaited(_runFind()),
                        onSubmitted: (_) => unawaited(_findNext()),
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(_findNext(forward: false)),
                      child: const Text('上一个'),
                    ),
                    TextButton(
                      onPressed: () => unawaited(_findNext()),
                      child: const Text('下一个'),
                    ),
                    Text(
                      tab.findTotal <= 0
                          ? ''
                          : '${tab.findActive + 1}/${tab.findTotal}',
                      style: TextStyle(fontSize: 11, color: wb.textMuted),
                    ),
                    IconButton(
                      iconSize: 18,
                      onPressed: () {
                        setState(() => _findOpen = false);
                        unawaited(tab.findInteraction.clearMatches());
                      },
                      icon: Icon(Icons.close, color: wb.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          if (_useGateway && !_dismissJsHint)
            Material(
              color: wb.accentBlue.withValues(alpha: 0.12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: wb.accentBlue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '网关只改写内网 HTML/CSS 链接；公网站点由本机 WebView 直连。仍打不开内网站时可切「直连」。',
                        style: TextStyle(fontSize: 11, color: wb.secondaryText),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭提示',
                      onPressed: () => unawaited(_dismissJsHintPersist()),
                      icon: Icon(Icons.close, size: 16, color: wb.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          if (tab?.error != null)
            Material(
              color: const Color(0xFF7F1D1D).withValues(alpha: 0.35),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        tab!.error!,
                        style: TextStyle(color: wb.primaryText, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        final url = tab.currentUrl ??
                            tab.addressCtrl.text.trim();
                        if (url.isNotEmpty) {
                          unawaited(_navigate(url, tab: tab));
                        } else {
                          unawaited(tab.web?.reload());
                        }
                      },
                      child: const Text('重试'),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      iconSize: 16,
                      onPressed: () => setState(() => tab.error = null),
                      icon: Icon(Icons.close, size: 16, color: wb.textMuted),
                    ),
                  ],
                ),
              ),
            )
          else if (_error != null)
            Material(
              color: const Color(0xFF7F1D1D).withValues(alpha: 0.35),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text(
                  _error!,
                  style: TextStyle(color: wb.primaryText, fontSize: 12),
                ),
              ),
            ),
          Expanded(
            child: offline
                ? _Hint(
                    text: c.dropped ? '连接已断开，重连后刷新' : '未连接',
                    actionLabel: c.dropped ? '重连' : null,
                    onAction: c.dropped
                        ? () => unawaited(c.reconnect())
                        : null,
                  )
                : _booting
                    ? const _Hint(text: '正在启动浏览器…', progress: true)
                    : IndexedStack(
                        index: _active.clamp(0, _tabs.length - 1),
                        sizing: StackFit.expand,
                        children: [
                          for (final t in _tabs) _buildTabSurface(t),
                        ],
                      ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
            child: Text(
              _lastNavPublicDirect
                  ? '公网直连：本机 WebView 访问 · 不经 SSH'
                  : _useGateway
                      ? '网关模式：内网站内链接经 SSH 漫游 · 公网资源本机直连'
                      : '直连模式：仅转发当前 host:port · 自签已放行',
              style: TextStyle(fontSize: 10, color: wb.textMuted),
            ),
          ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.addressCtrl,
    required this.addressFocus,
    required this.loading,
    required this.progress,
    required this.canGoBack,
    required this.canGoForward,
    required this.modeLabel,
    required this.useGateway,
    required this.offline,
    required this.bookmarks,
    required this.bookmarkGroups,
    required this.bookmarkGroupFilter,
    required this.onBookmarkGroupFilter,
    required this.history,
    required this.currentAddress,
    required this.currentUrl,
    required this.untrustedCert,
    required this.historySuggestions,
    required this.showHistorySuggestions,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onSubmit,
    required this.onAddressTap,
    required this.onAddressChanged,
    required this.onPickHistorySuggestion,
    required this.onToggleMode,
    required this.onToggleBookmark,
    required this.onOpenExternal,
    required this.onOpenBookmark,
    required this.onRemoveBookmark,
    required this.onRenameBookmark,
    required this.onOpenHistory,
    required this.onRemoveHistory,
    required this.onClearHistory,
    required this.onToggleFind,
    required this.onOpenDevTools,
  });

  final TextEditingController addressCtrl;
  final FocusNode addressFocus;
  final bool loading;
  final double progress;
  final bool canGoBack;
  final bool canGoForward;
  final String modeLabel;
  final bool useGateway;
  final bool offline;
  final List<BrowserBookmark> bookmarks;
  final List<String> bookmarkGroups;
  final String? bookmarkGroupFilter;
  final void Function(String? group) onBookmarkGroupFilter;
  final List<String> history;
  final String currentAddress;
  final String currentUrl;
  final bool untrustedCert;
  final List<String> historySuggestions;
  final bool showHistorySuggestions;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReload;
  final VoidCallback onSubmit;
  final VoidCallback onAddressTap;
  final VoidCallback onAddressChanged;
  final void Function(String url) onPickHistorySuggestion;
  final VoidCallback onToggleMode;
  final VoidCallback onToggleBookmark;
  final VoidCallback onOpenExternal;
  final void Function(String url) onOpenBookmark;
  final void Function(String url) onRemoveBookmark;
  final void Function(String url) onRenameBookmark;
  final void Function(String url) onOpenHistory;
  final void Function(String url) onRemoveHistory;
  final VoidCallback onClearHistory;
  final VoidCallback onToggleFind;
  final VoidCallback onOpenDevTools;

  bool get _bookmarked =>
      currentAddress.isNotEmpty &&
      bookmarks.any((b) => b.url == currentAddress);

  (IconData icon, String tip, Color? color) get _securityHint {
    if (untrustedCert) {
      return (
        Icons.warning_amber_rounded,
        '证书未验证（已放行）',
        const Color(0xFFEAB308),
      );
    }
    final u = currentUrl.trim().toLowerCase();
    if (u.startsWith('https://')) {
      return (Icons.lock_rounded, '安全连接 (HTTPS)', null);
    }
    if (u.startsWith('http://')) {
      return (Icons.lock_open_rounded, '非加密连接 (HTTP)', null);
    }
    if (u.isEmpty || u.startsWith('about:blank')) {
      return (Icons.help_outline_rounded, '空白页', null);
    }
    return (Icons.help_outline_rounded, '未知协议', null);
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Material(
      color: wb.panelElevated,
      child: Column(
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '后退',
                  onPressed: !offline && canGoBack ? onBack : null,
                  icon: Icon(
                    Icons.arrow_back_rounded,
                    size: 18,
                    color: canGoBack ? wb.primaryText : wb.textMuted,
                  ),
                ),
                IconButton(
                  tooltip: '前进',
                  onPressed: !offline && canGoForward ? onForward : null,
                  icon: Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: canGoForward ? wb.primaryText : wb.textMuted,
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: offline ? null : onReload,
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: 18,
                    color: wb.primaryText,
                  ),
                ),
                Builder(
                  builder: (context) {
                    final hint = _securityHint;
                    return Tooltip(
                      message: hint.$2,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 2, right: 4),
                        child: Icon(
                          hint.$1,
                          size: 16,
                          color: hint.$3 ?? wb.textMuted,
                        ),
                      ),
                    );
                  },
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.enter): () {
                          if (!offline) onSubmit();
                        },
                      },
                      child: TextField(
                        controller: addressCtrl,
                        focusNode: addressFocus,
                        // B11：断线仍可输入地址；仅提交/导航禁用。
                        enabled: true,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.go,
                        onChanged: (_) => onAddressChanged(),
                        style: TextStyle(
                          fontSize: 13,
                          color: wb.primaryText,
                          fontFamily: 'Menlo',
                        ),
                        onTap: onAddressTap,
                        onSubmitted: (_) {
                          if (!offline) onSubmit();
                        },
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'localhost:3000 或 http://host:port/path',
                          hintStyle:
                              TextStyle(color: wb.textMuted, fontSize: 12),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          filled: true,
                          fillColor: wb.panel,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide(color: wb.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide(color: wb.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide(color: wb.accentBlue),
                          ),
                          suffixIconConstraints: const BoxConstraints(
                            minWidth: 68,
                            minHeight: 28,
                          ),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PopupMenuButton<String>(
                                tooltip: '地址操作',
                                padding: EdgeInsets.zero,
                                position: PopupMenuPosition.under,
                                color: wb.panelElevated,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: BorderSide(color: wb.border),
                                ),
                                onSelected: (v) {
                                  if (v == 'copy') {
                                    final t = currentUrl.trim().isNotEmpty
                                        ? currentUrl.trim()
                                        : addressCtrl.text.trim();
                                    if (t.isEmpty) return;
                                    unawaited(
                                      Clipboard.setData(ClipboardData(text: t)),
                                    );
                                    return;
                                  }
                                  if (v == 'paste') {
                                    unawaited((() async {
                                      final data = await Clipboard.getData(
                                        Clipboard.kTextPlain,
                                      );
                                      final text = data?.text?.trim() ?? '';
                                      if (text.isEmpty) return;
                                      addressCtrl.text = text;
                                      addressCtrl.selection =
                                          TextSelection.collapsed(
                                        offset: text.length,
                                      );
                                      onAddressChanged();
                                      if (!offline) onSubmit();
                                    })());
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'copy',
                                    child: Text('复制 URL'),
                                  ),
                                  PopupMenuItem(
                                    value: 'paste',
                                    child: Text('粘贴并跳转'),
                                  ),
                                ],
                                icon: Icon(
                                  Icons.more_horiz_rounded,
                                  size: 16,
                                  color: wb.textMuted,
                                ),
                              ),
                              IconButton(
                                tooltip: '前往',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 28,
                                ),
                                onPressed: offline ? null : onSubmit,
                                icon: Icon(
                                  Icons.keyboard_return_rounded,
                                  size: 16,
                                  color: wb.accentBlue,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Flexible(
                  child: DesktopScrollableActions(
                    height: 40,
                    children: [
                      IconButton(
                        tooltip: _bookmarked ? '取消收藏' : '收藏当前地址',
                        onPressed: offline || currentAddress.isEmpty
                            ? null
                            : onToggleBookmark,
                        icon: Icon(
                          _bookmarked
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          size: 18,
                          color: _bookmarked
                              ? const Color(0xFFEAB308)
                              : wb.textMuted,
                        ),
                      ),
                      IconButton(
                        tooltip: '在页面中查找',
                        onPressed: onToggleFind,
                        icon: Icon(
                          Icons.search_rounded,
                          size: 18,
                          color: wb.textMuted,
                        ),
                      ),
                      IconButton(
                        tooltip: '用系统浏览器打开（仅公网地址）',
                        onPressed: offline || currentAddress.isEmpty
                            ? null
                            : onOpenExternal,
                        icon: Icon(
                          Icons.open_in_new_rounded,
                          size: 18,
                          color: wb.textMuted,
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '书签',
                        enabled: !offline,
                        position: PopupMenuPosition.under,
                        color: wb.panelElevated,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(color: wb.border),
                        ),
                        onSelected: (v) {
                          if (v.startsWith('open:')) {
                            onOpenBookmark(v.substring(5));
                          } else if (v.startsWith('del:')) {
                            onRemoveBookmark(v.substring(4));
                          } else if (v.startsWith('rename:')) {
                            onRenameBookmark(v.substring(7));
                          } else if (v == 'filter:all') {
                            onBookmarkGroupFilter(null);
                          } else if (v.startsWith('filter:')) {
                            onBookmarkGroupFilter(v.substring(7));
                          }
                        },
                        itemBuilder: (context) {
                          if (bookmarks.isEmpty) {
                            return [
                              const PopupMenuItem(
                                enabled: false,
                                child: Text('暂无书签'),
                              ),
                            ];
                          }
                          final visible = bookmarkGroupFilter == null
                              ? bookmarks
                              : bookmarks
                                  .where(
                                    (b) =>
                                        b.displayGroup == bookmarkGroupFilter,
                                  )
                                  .toList();
                          final items = <PopupMenuEntry<String>>[];
                          if (bookmarkGroups.length > 1) {
                            items.add(
                              PopupMenuItem(
                                enabled: false,
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: [
                                    FilterChip(
                                      label: const Text(
                                        '全部',
                                        style: TextStyle(fontSize: 11),
                                      ),
                                      selected: bookmarkGroupFilter == null,
                                      visualDensity: VisualDensity.compact,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      onSelected: (_) {
                                        Navigator.pop(context, 'filter:all');
                                      },
                                    ),
                                    for (final g in bookmarkGroups)
                                      FilterChip(
                                        label: Text(
                                          g,
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        selected: bookmarkGroupFilter == g,
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        onSelected: (_) {
                                          Navigator.pop(context, 'filter:$g');
                                        },
                                      ),
                                  ],
                                ),
                              ),
                            );
                            items.add(const PopupMenuDivider());
                          }
                          if (visible.isEmpty) {
                            items.add(
                              const PopupMenuItem(
                                enabled: false,
                                child: Text('该分组暂无书签'),
                              ),
                            );
                            return items;
                          }
                          final byGroup = <String, List<BrowserBookmark>>{};
                          for (final b in visible) {
                            byGroup
                                .putIfAbsent(b.displayGroup, () => [])
                                .add(b);
                          }
                          final groupOrder = bookmarkGroupFilter != null
                              ? <String>[bookmarkGroupFilter!]
                              : [
                                  for (final g in bookmarkGroups)
                                    if (byGroup.containsKey(g)) g,
                                ];
                          final multi = groupOrder.length > 1 ||
                              visible.any((b) => b.group.trim().isNotEmpty);
                          for (var gi = 0; gi < groupOrder.length; gi++) {
                            final g = groupOrder[gi];
                            final groupItems = byGroup[g] ?? const [];
                            if (groupItems.isEmpty) continue;
                            if (multi) {
                              if (gi > 0) items.add(const PopupMenuDivider());
                              items.add(
                                PopupMenuItem(
                                  enabled: false,
                                  height: 28,
                                  child: Text(
                                    g,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: wb.textMuted,
                                    ),
                                  ),
                                ),
                              );
                            }
                            for (final b in groupItems) {
                              items.add(
                                PopupMenuItem(
                                  value: 'open:${b.url}',
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              b.displayTitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (b.hasDistinctTitle)
                                              Text(
                                                b.url,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: wb.textMuted,
                                                  fontFamily: 'Menlo',
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '重命名',
                                        onPressed: () {
                                          Navigator.pop(context);
                                          onRenameBookmark(b.url);
                                        },
                                        icon: Icon(
                                          Icons.edit_outlined,
                                          size: 14,
                                          color: wb.textMuted,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '删除',
                                        onPressed: () {
                                          Navigator.pop(context);
                                          onRemoveBookmark(b.url);
                                        },
                                        icon: Icon(
                                          Icons.close_rounded,
                                          size: 14,
                                          color: wb.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }
                          }
                          return items;
                        },
                        icon: Icon(
                          Icons.bookmarks_outlined,
                          size: 18,
                          color: wb.textMuted,
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '历史',
                        enabled: !offline,
                        position: PopupMenuPosition.under,
                        color: wb.panelElevated,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(color: wb.border),
                        ),
                        onSelected: (v) {
                          if (v == 'clear') {
                            onClearHistory();
                          } else if (v.startsWith('open:')) {
                            onOpenHistory(v.substring(5));
                          } else if (v.startsWith('del:')) {
                            onRemoveHistory(v.substring(4));
                          }
                        },
                        itemBuilder: (context) {
                          if (history.isEmpty) {
                            return [
                              const PopupMenuItem(
                                enabled: false,
                                child: Text('暂无历史'),
                              ),
                            ];
                          }
                          return [
                            for (final h in history.take(20))
                              PopupMenuItem(
                                value: 'open:$h',
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        h,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '删除',
                                      onPressed: () {
                                        Navigator.pop(context);
                                        onRemoveHistory(h);
                                      },
                                      icon: Icon(
                                        Icons.close_rounded,
                                        size: 14,
                                        color: wb.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const PopupMenuDivider(),
                            const PopupMenuItem(
                              value: 'clear',
                              child: Text('清空历史'),
                            ),
                          ];
                        },
                        icon: Icon(
                          Icons.history_rounded,
                          size: 18,
                          color: wb.textMuted,
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        enabled: !offline,
                        position: PopupMenuPosition.under,
                        color: wb.panelElevated,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: BorderSide(color: wb.border),
                        ),
                        onSelected: (v) {
                          if (v == 'devtools') onOpenDevTools();
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'devtools',
                            child: Text('开发者工具'),
                          ),
                        ],
                        icon: Icon(
                          Icons.more_vert_rounded,
                          size: 18,
                          color: wb.textMuted,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: TextButton(
                          onPressed: offline ? null : onToggleMode,
                          style: TextButton.styleFrom(
                            foregroundColor:
                                useGateway ? wb.accentBlue : wb.secondaryText,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            modeLabel,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (showHistorySuggestions)
            Material(
              color: wb.panel,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: historySuggestions.length,
                  itemBuilder: (context, i) {
                    final h = historySuggestions[i];
                    return InkWell(
                      onTap: () => onPickHistorySuggestion(h),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.history_rounded,
                              size: 14,
                              color: wb.textMuted,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                h,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: wb.primaryText,
                                  fontFamily: 'Menlo',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          if (loading)
            LinearProgressIndicator(
              value: progress > 0 && progress < 1 ? progress : null,
              minHeight: 2,
              backgroundColor: wb.border.withValues(alpha: 0.3),
              color: wb.accentBlue,
            )
          else
            const SizedBox(height: 2),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({
    required this.text,
    this.progress = false,
    this.actionLabel,
    this.onAction,
  });

  final String text;
  final bool progress;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (progress) ...[
            CircularProgressIndicator(color: wb.accentBlue),
            const SizedBox(height: 12),
          ],
          Text(text, style: TextStyle(color: wb.textMuted)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class _BrowserStartPage extends StatelessWidget {
  const _BrowserStartPage({
    required this.bookmarks,
    required this.bookmarkGroups,
    required this.bookmarkGroupFilter,
    required this.onBookmarkGroupFilter,
    required this.history,
    required this.onOpen,
    required this.onRenameBookmark,
  });

  final List<BrowserBookmark> bookmarks;
  final List<String> bookmarkGroups;
  final String? bookmarkGroupFilter;
  final void Function(String? group) onBookmarkGroupFilter;
  final List<String> history;
  final void Function(String url) onOpen;
  final void Function(String url) onRenameBookmark;

  String _chipLabelForUrl(String url) {
    try {
      final parsed = parseBrowserAddressBar(url);
      final host = parsed.host;
      if (parsed.port != 80 && parsed.port != 443) {
        return '$host:${parsed.port}';
      }
      return host.isNotEmpty ? host : url;
    } catch (_) {
      return url.length > 28 ? '${url.substring(0, 28)}…' : url;
    }
  }

  String _chipLabelForBookmark(BrowserBookmark b) {
    if (b.hasDistinctTitle) {
      final t = b.displayTitle;
      return t.length > 28 ? '${t.substring(0, 28)}…' : t;
    }
    return _chipLabelForUrl(b.url);
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final recent = history.take(12).toList();
    final marks = bookmarks.take(16).toList();

    return Material(
      color: wb.panel,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '新标签页',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: wb.primaryText,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '从书签或最近访问打开，或在上方地址栏输入地址',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: wb.textMuted),
                ),
                const SizedBox(height: 28),
                _StartSection(
                  title: '书签',
                  emptyHint: '暂无书签',
                  child: marks.isEmpty && bookmarkGroups.length <= 1
                      ? null
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (bookmarkGroups.length > 1) ...[
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  FilterChip(
                                    label: const Text('全部'),
                                    selected: bookmarkGroupFilter == null,
                                    visualDensity: VisualDensity.compact,
                                    onSelected: (_) =>
                                        onBookmarkGroupFilter(null),
                                  ),
                                  for (final g in bookmarkGroups)
                                    FilterChip(
                                      label: Text(g),
                                      selected: bookmarkGroupFilter == g,
                                      visualDensity: VisualDensity.compact,
                                      onSelected: (_) =>
                                          onBookmarkGroupFilter(g),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                            ],
                            if (marks.isEmpty)
                              Text(
                                bookmarkGroupFilter == null
                                    ? '暂无书签'
                                    : '该分组暂无书签',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: wb.textMuted,
                                ),
                              )
                            else
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final b in marks)
                                    GestureDetector(
                                      onLongPress: () =>
                                          onRenameBookmark(b.url),
                                      child: ActionChip(
                                        avatar: Icon(
                                          Icons.star_rounded,
                                          size: 16,
                                          color: const Color(0xFFEAB308),
                                        ),
                                        label: Text(_chipLabelForBookmark(b)),
                                        onPressed: () => onOpen(b.url),
                                      ),
                                    ),
                                ],
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 20),
                _StartSection(
                  title: '最近访问',
                  emptyHint: '暂无历史',
                  child: recent.isEmpty
                      ? null
                      : Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final h in recent)
                              ActionChip(
                                avatar: Icon(
                                  Icons.history_rounded,
                                  size: 16,
                                  color: wb.textMuted,
                                ),
                                label: Text(_chipLabelForUrl(h)),
                                onPressed: () => onOpen(h),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StartSection extends StatelessWidget {
  const _StartSection({
    required this.title,
    required this.emptyHint,
    required this.child,
  });

  final String title;
  final String emptyHint;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: wb.secondaryText,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 10),
        if (child != null)
          child!
        else
          Text(
            emptyHint,
            style: TextStyle(fontSize: 12, color: wb.textMuted),
          ),
      ],
    );
  }
}
