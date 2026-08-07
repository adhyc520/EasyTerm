import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/browser_bookmarks_store.dart';
import '../../services/browser_history_store.dart';
import '../../services/browser_gateway_rewrite.dart';
import '../../services/remote_browser_backend.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../util/launch_external_url.dart';
import '../desktop_window_manager.dart';

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

class _BrowserTab {
  _BrowserTab({required this.id, String initialAddress = ''})
      : addressCtrl = TextEditingController(text: initialAddress),
        addressFocus = FocusNode();

  final String id;
  final TextEditingController addressCtrl;
  final FocusNode addressFocus;
  InAppWebViewController? web;
  String? currentUrl;
  String? pageTitle;
  bool loading = false;
  double progress = 0;
  bool canGoBack = false;
  bool canGoForward = false;
  bool lastNavPublicDirect = false;
  String? pendingNavigate;
  DateTime lastAccessed = DateTime.now();

  void touch() => lastAccessed = DateTime.now();

  void dispose() {
    addressCtrl.dispose();
    addressFocus.dispose();
  }
}

class _BrowserAppState extends State<BrowserApp> {
  static const _maxTabs = 8;
  static const _kJsHintDismissPrefs = 'desktop_browser_js_hint_dismissed';

  final List<_BrowserTab> _tabs = [];
  int _active = 0;
  int _tabIdSeq = 0;

  RemoteBrowserBackend? _backend;
  bool _useGateway = true;
  String? _error;
  bool _booting = true;
  late final BrowserBookmarksStore _bookmarks;
  late final BrowserHistoryStore _history;
  List<String> _bookmarkList = const [];
  List<String> _historyList = const [];
  bool _dismissJsHint = false;
  bool _wasConnected = false;
  bool _addressFocused = false;

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
    _wasConnected = c.connected && !c.dropped;
    _bookmarks = BrowserBookmarksStore(_hostKey);
    _history = BrowserHistoryStore(_hostKey);
    final mode = widget.window.args['mode']?.toString();
    _useGateway = mode != 'direct';
    final initial = widget.window.args['url']?.toString();
    final addr = (initial != null && initial.isNotEmpty)
        ? initial
        : 'localhost:3000';
    _tabs.add(_BrowserTab(id: _nextTabId(), initialAddress: addr));
    _bindActiveTabFocus();
    unawaited(_loadLists());
    unawaited(_loadJsHintDismissed());
    unawaited(_boot());
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
    if (_addressFocused != focused) {
      setState(() => _addressFocused = focused);
    }
    if (!focused) return;
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
    return _historyList
        .where((h) => h.toLowerCase().contains(q))
        .take(8)
        .toList();
  }

  @override
  void dispose() {
    c.removeListener(_onController);
    _boundAddressFocus?.removeListener(_onAddressFocusChange);
    unawaited(_backend?.close());
    _backend = null;
    for (final t in _tabs) {
      t.dispose();
    }
    super.dispose();
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
      setState(() => _error = '未连接');
      return;
    }
    _patchTab(t, () {
      t.loading = true;
      _error = null;
    });
    try {
      if (_backend == null) await _ensureBackend();
      final parsed = parseBrowserAddressBar(input);
      final publicDirect = !isSshTunneledBrowserHost(parsed.host);
      final uri = await _backend!.resolveUrl(input);
      widget.window.args['url'] = input;
      widget.window.args['mode'] = _useGateway ? 'gateway' : 'direct';
      widget.wm.focus(widget.window.id);
      final hist = await _history.push(input);
      await t.web?.loadUrl(urlRequest: URLRequest(url: WebUri(uri.toString())));
      if (mounted) {
        setState(() {
          t.addressCtrl.text = input;
          t.lastNavPublicDirect = publicDirect;
          _historyList = hist;
        });
        _syncWindowTitle();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
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
      _tabs.add(_BrowserTab(id: _nextTabId(), initialAddress: address));
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

  String _tabLabel(_BrowserTab tab) {
    if (tab.pageTitle != null && tab.pageTitle!.trim().isNotEmpty) {
      return tab.pageTitle!.trim();
    }
    final addr = tab.addressCtrl.text.trim();
    if (addr.isEmpty) return '新标签';
    return _shortHost(addr);
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
    if (_bookmarkList.contains(addr)) {
      await _removeBookmark(addr);
    } else {
      await _addBookmark();
    }
  }

  Future<void> _addBookmark() async {
    final tab = _tab;
    if (tab == null) return;
    final list = await _bookmarks.add(tab.addressCtrl.text);
    if (!mounted) return;
    setState(() => _bookmarkList = list);
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
    setState(() => _bookmarkList = list);
  }

  Future<void> _clearHistory() async {
    final list = await _history.clear();
    if (!mounted) return;
    setState(() => _historyList = list);
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
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
        supportMultipleWindows: true,
        transparentBackground: false,
        isFraudulentWebsiteWarningEnabled: false,
        allowsInlineMediaPlayback: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        useShouldOverrideUrlLoading: false,
      ),
      onWebViewCreated: (controller) {
        tab.web = controller;
        final pending = tab.pendingNavigate;
        if (pending != null && pending.isNotEmpty) {
          tab.pendingNavigate = null;
          unawaited(_navigate(pending, tab: tab));
        }
      },
      onCreateWindow: (controller, action) =>
          _handleCreateWindow(controller, action),
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
        if (identical(tab, _tab) && tab.addressFocus.hasFocus) {
          tab.loading = true;
          tab.progress = 0;
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
        if (identical(tab, _tab) && tab.addressFocus.hasFocus) {
          tab.progress = p;
          return;
        }
        setState(() => tab.progress = p);
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
        if (identical(tab, _tab)) _syncWindowTitle();
      },
      onReceivedError: (controller, request, error) {
        setState(() {
          tab.loading = false;
          _error = error.description;
        });
      },
      onWindowFocus: (controller) {
        if (identical(tab, _tab) && tab.addressFocus.hasFocus) {
          unawaited(_releaseWebViewKeyboard(tab));
          tab.addressFocus.requestFocus();
        }
      },
      onReceivedServerTrustAuthRequest: (controller, challenge) async {
        return ServerTrustAuthResponse(
          action: ServerTrustAuthResponseAction.PROCEED,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final offline = !c.connected || c.dropped;
    final tab = _tab;
    final suggestions = _filteredHistorySuggestions;

    return ColoredBox(
      color: wb.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TabStrip(
            tabs: _tabs,
            active: _active,
            maxTabs: _maxTabs,
            labelFor: _tabLabel,
            onSelect: _selectTab,
            onClose: (i) => unawaited(_closeTab(i)),
            onAdd: () => _addBlankTab(),
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
              history: _historyList,
              currentAddress: tab.addressCtrl.text.trim(),
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
                unawaited(_releaseWebViewKeyboard(tab));
              },
              onAddressChanged: () {
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
              onOpenHistory: (url) => unawaited(_navigate(url)),
              onClearHistory: () => unawaited(_clearHistory()),
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
                        '网关只改写内网绝对链接；公网站点由本机 WebView 直连。仍打不开内网站时可切「直连」。',
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
          if (_error != null)
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
                          for (final t in _tabs) _buildWebView(t),
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
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.active,
    required this.maxTabs,
    required this.labelFor,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
  });

  final List<_BrowserTab> tabs;
  final int active;
  final int maxTabs;
  final String Function(_BrowserTab tab) labelFor;
  final void Function(int index) onSelect;
  final void Function(int index) onClose;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Material(
      color: wb.panelElevated,
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: tabs.length,
                itemBuilder: (context, i) {
                  final t = tabs[i];
                  final sel = i == active;
                  return InkWell(
                    onTap: () => onSelect(i),
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: sel ? wb.accentBlue : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (t.loading)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: wb.accentBlue,
                                ),
                              ),
                            ),
                          Flexible(
                            child: Text(
                              labelFor(t),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color:
                                    sel ? wb.primaryText : wb.secondaryText,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => onClose(i),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(
                                Icons.close,
                                size: 14,
                                color: wb.textMuted,
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
            IconButton(
              tooltip: tabs.length >= maxTabs ? '已达 $maxTabs 个标签上限' : '新标签',
              onPressed: tabs.length >= maxTabs ? null : onAdd,
              icon: Icon(
                Icons.add,
                size: 18,
                color: tabs.length >= maxTabs ? wb.textMuted : wb.primaryText,
              ),
            ),
          ],
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
    required this.history,
    required this.currentAddress,
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
    required this.onOpenHistory,
    required this.onClearHistory,
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
  final List<String> bookmarks;
  final List<String> history;
  final String currentAddress;
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
  final void Function(String url) onOpenHistory;
  final VoidCallback onClearHistory;

  bool get _bookmarked =>
      currentAddress.isNotEmpty && bookmarks.contains(currentAddress);

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
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.enter):
                            onSubmit,
                      },
                      child: TextField(
                        controller: addressCtrl,
                        focusNode: addressFocus,
                        enabled: !offline,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.go,
                        onChanged: (_) => onAddressChanged(),
                        style: TextStyle(
                          fontSize: 13,
                          color: wb.primaryText,
                          fontFamily: 'Menlo',
                        ),
                        onTap: onAddressTap,
                        onSubmitted: (_) => onSubmit(),
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
                            minWidth: 36,
                            minHeight: 28,
                          ),
                          suffixIcon: IconButton(
                            tooltip: '前往',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 28,
                            ),
                            onPressed: offline ? null : onSubmit,
                            icon: Icon(
                              Icons.keyboard_return_rounded,
                              size: 16,
                              color: wb.accentBlue,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
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
                    color: _bookmarked ? const Color(0xFFEAB308) : wb.textMuted,
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
                    return [
                      for (final b in bookmarks)
                        PopupMenuItem(
                          value: 'open:$b',
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  b,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                tooltip: '删除',
                                onPressed: () {
                                  Navigator.pop(context);
                                  onRemoveBookmark(b);
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
                    ];
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
                          child: Text(
                            h,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
                    child:
                        Text(modeLabel, style: const TextStyle(fontSize: 12)),
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
