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

class _BrowserAppState extends State<BrowserApp> {
  final TextEditingController _addressCtrl = TextEditingController();
  final FocusNode _addressFocus = FocusNode();

  InAppWebViewController? _web;
  RemoteBrowserBackend? _backend;
  bool _useGateway = true;
  bool _loading = false;
  double _progress = 0;
  String? _error;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _booting = true;
  String? _pendingNavigate;
  late final BrowserBookmarksStore _bookmarks;
  late final BrowserHistoryStore _history;
  List<String> _bookmarkList = const [];
  List<String> _historyList = const [];
  bool _dismissJsHint = false;
  bool _wasConnected = false;
  /// Last resolved navigation used local WebView (public Internet), not SSH.
  bool _lastNavPublicDirect = false;

  static const _kJsHintDismissPrefs = 'desktop_browser_js_hint_dismissed';

  SshWorkspaceController get c => widget.controller;

  String get _hostKey =>
      '${c.username}@${c.host}:${c.port}';

  @override
  void initState() {
    super.initState();
    c.addListener(_onController);
    _addressFocus.addListener(_onAddressFocusChange);
    _wasConnected = c.connected && !c.dropped;
    _bookmarks = BrowserBookmarksStore(_hostKey);
    _history = BrowserHistoryStore(_hostKey);
    final mode = widget.window.args['mode']?.toString();
    _useGateway = mode != 'direct';
    final initial = widget.window.args['url']?.toString();
    if (initial != null && initial.isNotEmpty) {
      _addressCtrl.text = initial;
    } else {
      _addressCtrl.text = 'localhost:3000';
    }
    unawaited(_loadLists());
    unawaited(_loadJsHintDismissed());
    unawaited(_boot());
  }

  /// WebView（PlatformView）常抢走键盘焦点；编辑地址栏时主动让出。
  void _onAddressFocusChange() {
    if (!_addressFocus.hasFocus) return;
    unawaited(_releaseWebViewKeyboard());
  }

  Future<void> _releaseWebViewKeyboard() async {
    final web = _web;
    if (web == null) return;
    try {
      await web.clearFocus();
    } catch (_) {}
    try {
      await web.evaluateJavascript(
        source: 'try{document.activeElement&&document.activeElement.blur()}catch(e){}',
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

  @override
  void dispose() {
    c.removeListener(_onController);
    _addressFocus.removeListener(_onAddressFocusChange);
    unawaited(_backend?.close());
    _backend = null;
    _addressCtrl.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  void _onController() {
    if (!mounted) return;
    final nowConnected = c.connected && !c.dropped;

    if (!nowConnected) {
      // 掉线：释放直连转发；网关由 workspace teardown 停掉
      unawaited(_backend?.close());
      _backend = null;
      _wasConnected = false;
      setState(() {});
      return;
    }

    // 重连成功：重建 backend 并重新导航当前地址
    if (!_wasConnected) {
      _wasConnected = true;
      unawaited(_rebindAfterReconnect());
      return;
    }

    // 已连接时 workspace 的其它通知（SFTP 等）不必重建浏览器，
    // 否则 PlatformView 重建会再次抢走地址栏键盘焦点。
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
      final url = _addressCtrl.text.trim();
      if (url.isNotEmpty) {
        await _navigate(url);
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
      _pendingNavigate = _addressCtrl.text;
      if (_web != null) {
        await _navigate(_pendingNavigate!);
        _pendingNavigate = null;
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

  Future<void> _navigate(String raw) async {
    final input = raw.trim();
    if (input.isEmpty) return;
    if (!c.connected || c.clientForDesktop == null) {
      setState(() => _error = '未连接');
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
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
      await _web?.loadUrl(urlRequest: URLRequest(url: WebUri(uri.toString())));
      if (mounted) {
        setState(() {
          _addressCtrl.text = input;
          _historyList = hist;
          _lastNavPublicDirect = publicDirect;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _toggleMode() async {
    final switchingToDirect = _useGateway;
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
              '当前目标：${_addressCtrl.text.trim().isEmpty ? '（空）' : _addressCtrl.text.trim()}',
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
      await _navigate(_addressCtrl.text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _toggleBookmark() async {
    final addr = _addressCtrl.text.trim();
    if (addr.isEmpty) return;
    if (_bookmarkList.contains(addr)) {
      await _removeBookmark(addr);
    } else {
      await _addBookmark();
    }
  }

  Future<void> _addBookmark() async {
    final list = await _bookmarks.add(_addressCtrl.text);
    if (!mounted) return;
    setState(() => _bookmarkList = list);
  }

  Future<void> _openExternal() async {
    final input = _addressCtrl.text.trim();
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

  Future<void> _refreshNavFlags() async {
    final w = _web;
    if (w == null) return;
    final back = await w.canGoBack();
    final forward = await w.canGoForward();
    if (!mounted) return;
    if (_canGoBack == back && _canGoForward == forward) return;
    if (_addressFocus.hasFocus) {
      _canGoBack = back;
      _canGoForward = forward;
      return;
    }
    setState(() {
      _canGoBack = back;
      _canGoForward = forward;
    });
  }

  /// 网关 / 直连 loopback URL 对用户无意义；公网直连时同步真实地址。
  void _syncAddressFromLoad(WebUri? url) {
    if (url == null) return;
    final host = url.host.toLowerCase();
    final isLoopback = host == '127.0.0.1' || host == 'localhost';
    if (isLoopback) {
      _lastNavPublicDirect = false;
      return;
    }
    final display = url.toString();
    if (_addressCtrl.text == display) {
      _lastNavPublicDirect = true;
      return;
    }
    if (_addressFocus.hasFocus) return;
    _addressCtrl.text = display;
    _lastNavPublicDirect = true;
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final offline = !c.connected || c.dropped;

    return ColoredBox(
      color: wb.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            addressCtrl: _addressCtrl,
            addressFocus: _addressFocus,
            loading: _loading,
            progress: _progress,
            canGoBack: _canGoBack,
            canGoForward: _canGoForward,
            modeLabel: _backend?.modeLabel ?? (_useGateway ? '网关' : '直连'),
            useGateway: _useGateway,
            offline: offline,
            bookmarks: _bookmarkList,
            history: _historyList,
            currentAddress: _addressCtrl.text.trim(),
            onBack: () async {
              await _web?.goBack();
              await _refreshNavFlags();
            },
            onForward: () async {
              await _web?.goForward();
              await _refreshNavFlags();
            },
            onReload: () async {
              await _web?.reload();
            },
            onSubmit: () => unawaited(_navigate(_addressCtrl.text)),
            onAddressTap: () {
              if (!_addressFocus.hasFocus) {
                _addressFocus.requestFocus();
              }
              unawaited(_releaseWebViewKeyboard());
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
                    : InAppWebView(
                        key: ValueKey('wv-${widget.window.id}'),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          transparentBackground: false,
                          isFraudulentWebsiteWarningEnabled: false,
                          allowsInlineMediaPlayback: true,
                          mixedContentMode:
                              MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                          useShouldOverrideUrlLoading: false,
                        ),
                        onWebViewCreated: (controller) {
                          _web = controller;
                          final pending = _pendingNavigate;
                          if (pending != null && pending.isNotEmpty) {
                            _pendingNavigate = null;
                            unawaited(_navigate(pending));
                          }
                        },
                        onLoadStart: (controller, url) {
                          if (_addressFocus.hasFocus) {
                            // 编辑地址时避免整树重建打断输入
                            _loading = true;
                            _progress = 0;
                            return;
                          }
                          setState(() {
                            _loading = true;
                            _progress = 0;
                          });
                          _syncAddressFromLoad(url);
                        },
                        onProgressChanged: (controller, progress) {
                          if (_addressFocus.hasFocus) {
                            _progress = progress / 100.0;
                            return;
                          }
                          setState(() => _progress = progress / 100.0);
                        },
                        onLoadStop: (controller, url) async {
                          if (!_addressFocus.hasFocus) {
                            setState(() {
                              _loading = false;
                              _progress = 1;
                            });
                          } else {
                            _loading = false;
                            _progress = 1;
                          }
                          await _refreshNavFlags();
                        },
                        onReceivedError: (controller, request, error) {
                          setState(() {
                            _loading = false;
                            _error = error.description;
                          });
                        },
                        onWindowFocus: (controller) {
                          // PlatformView 抢到原生焦点时，若用户正在改地址则抢回来
                          if (_addressFocus.hasFocus) {
                            unawaited(_releaseWebViewKeyboard());
                            _addressFocus.requestFocus();
                          }
                        },
                        onReceivedServerTrustAuthRequest:
                            (controller, challenge) async {
                          // 直连 HTTPS 自签：放行
                          return ServerTrustAuthResponse(
                            action: ServerTrustAuthResponseAction.PROCEED,
                          );
                        },
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
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onSubmit,
    required this.onAddressTap,
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
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReload;
  final VoidCallback onSubmit;
  final VoidCallback onAddressTap;
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
