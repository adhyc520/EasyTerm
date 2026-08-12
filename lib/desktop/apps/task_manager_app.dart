import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote_gpu.dart';
import '../../services/remote_host_metrics.dart';
import '../../services/remote_network.dart';
import '../../services/remote_process_list.dart';
import '../../services/terminal_session_controller.dart';
import '../../services/remote_exec_capable.dart';
import '../../services/ssh_workspace_controller.dart';
import '../../theme/workbench_theme.dart';
import '../../widgets/destructive_action_dialog.dart';
import '../desktop_window_manager.dart';
import '../widgets/desktop_monitor_widgets.dart';
import '../widgets/desktop_scrollable_actions.dart';
import '../widgets/desktop_ui.dart';

enum _ProcSort { name, pid, user, cpu, memory }

enum _SvcSort { name, status, startType }

enum _NetSort { port, protocol, address, process }

/// 任务管理器：进程 / 性能 / 网络 / 服务。
class TaskManagerApp extends StatefulWidget {
  const TaskManagerApp({
    super.key,
    required this.window,
    required this.wm,
    required this.controller,
  });

  final DesktopWindow window;
  final DesktopWindowManager wm;
  final TerminalSessionController controller;

  @override
  State<TaskManagerApp> createState() => _TaskManagerAppState();
}

class _TaskManagerAppState extends State<TaskManagerApp>
    with SingleTickerProviderStateMixin {
  RemoteExecCapable get _exec => widget.controller as RemoteExecCapable;
late final TabController _tabs;
  Timer? _timer;

  RemoteOsKind? _os;

  // Processes
  List<RemoteProcess> _processes = const [];
  String _procFilter = '';
  _ProcSort _procSort = _ProcSort.memory;
  bool _procSortAsc = false;
  int? _selectedPid;
  bool _detailOpen = false;
  int? _detailPid;
  Future<RemoteProcessDetail?>? _detailFuture;
  bool _killing = false;
  final _procFilterCtrl = TextEditingController();
  final _procFilterFocus = FocusNode();
  final _procListFocus = FocusNode();

  // Performance
  RemoteHostSnapshot? _snap;
  RemoteGpuSnapshot? _gpu;
  final List<double> _cpuHist = [];
  final List<double> _memHist = [];
  static const int _histMax = 36;

  // Network
  RemoteNetworkSnapshot? _netSnap;
  RemoteNetworkSnapshot? _netPrev;
  String _netFilter = '';
  _NetSort _netSort = _NetSort.port;
  bool _netSortAsc = true;
  bool _netHideLoopback = true;
  final _netFilterCtrl = TextEditingController();
  final List<double> _rxHist = [];
  final List<double> _txHist = [];

  // Services
  List<RemoteService> _services = const [];
  String _svcFilter = '';
  _SvcSort _svcSort = _SvcSort.status;
  bool _svcSortAsc = false;
  String? _selectedSvc;
  bool _svcBusy = false;
  final _svcFilterCtrl = TextEditingController();

  bool _loading = false;
  String? _error;
  bool _userPaused = false;
  Duration _interval = const Duration(seconds: 3);
  DateTime? _lastTickAt;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _tabs.addListener(_onTab);
    widget.wm.addListener(_onWm);
    widget.controller.addListener(_onController);
    widget.window.onConnectionRestored = _onConnectionRestored;
    unawaited(_tick());
    _armTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tabs.removeListener(_onTab);
    _tabs.dispose();
    _procFilterCtrl.dispose();
    _procFilterFocus.dispose();
    _procListFocus.dispose();
    _svcFilterCtrl.dispose();
    _netFilterCtrl.dispose();
    widget.window.onConnectionRestored = null;
    widget.wm.removeListener(_onWm);
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _onConnectionRestored() {
    if (!mounted) return;
    setState(() => _error = null);
    unawaited(_tick());
  }

  void _onTab() {
    if (_tabs.indexIsChanging) return;
    _armTimer();
    unawaited(_tick());
    if (_tabs.index == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _procListFocus.requestFocus();
      });
    }
  }

  void _onWm() {
    _armTimer();
    if (mounted) setState(() {});
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  bool get _paused =>
      widget.window.state == WindowState.minimized || _userPaused;

  bool get _connected =>
      widget.controller.connected && !widget.controller.dropped;

  void _armTimer() {
    _timer?.cancel();
    if (_paused) {
      _timer = null;
      return;
    }
    _timer = Timer.periodic(_interval, (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (!mounted || _paused) return;
    if (!_connected) {
      setState(() {
        _error = '连接已断开，重连后刷新';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = (_tabs.index == 0 && _processes.isEmpty) ||
          (_tabs.index == 1 && _snap == null) ||
          (_tabs.index == 2 && _netSnap == null) ||
          (_tabs.index == 3 && _services.isEmpty);
      _error = null;
    });
    try {
      switch (_tabs.index) {
        case 0:
          await _loadProcesses();
        case 1:
          await _loadPerf();
        case 2:
          await _loadNetwork();
        case 3:
          await _loadServices();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadProcesses() async {
    final snap =
        await fetchRemoteProcessSnapshot(_exec, osHint: _os);
    if (!mounted) return;
    if (snap == null) {
      setState(() {
        _error = '无法获取进程列表';
        _loading = false;
      });
      return;
    }
    if (snap.os != RemoteOsKind.unknown) _os = snap.os;
    setState(() {
      _processes = snap.processes;
      _loading = false;
      _lastTickAt = DateTime.now();
      _error = snap.processes.isEmpty && snap.os == RemoteOsKind.unknown
          ? '无法识别远端系统（需 Linux 或 Windows OpenSSH）'
          : null;
      if (_selectedPid != null &&
          !snap.processes.any((p) => p.pid == _selectedPid)) {
        _selectedPid = null;
      }
      if (_detailOpen &&
          (_detailPid == null ||
              !snap.processes.any((p) => p.pid == _detailPid))) {
        _detailOpen = false;
        _detailPid = null;
        _detailFuture = null;
      }
    });
  }

  Future<void> _loadPerf() async {
    final results = await Future.wait([
      _exec.snapshot(),
      fetchRemoteGpuSnapshot(_exec, osHint: _os),
    ]);
    if (!mounted) return;
    final snap = results[0] as RemoteHostSnapshot?;
    final gpu = results[1] as RemoteGpuSnapshot?;
    if (snap == null && gpu == null) {
      setState(() {
        final detail = _exec.lastRemoteCommandError;
        _error = detail == null ? '无法获取性能指标' : '刷新失败：$detail';
        _loading = false;
      });
      return;
    }
    if (snap != null) {
      if (snap.cpuUsed01 != null) {
        _cpuHist.add(snap.cpuUsed01!);
        if (_cpuHist.length > _histMax) _cpuHist.removeAt(0);
      }
      if (snap.memUsed01 != null) {
        _memHist.add(snap.memUsed01!);
        if (_memHist.length > _histMax) _memHist.removeAt(0);
      }
    }
    if (gpu != null && gpu.os != RemoteOsKind.unknown) {
      _os = gpu.os;
    }
    setState(() {
      if (snap != null) _snap = snap;
      if (gpu != null) _gpu = gpu;
      _loading = false;
      _lastTickAt = DateTime.now();
      _error = null;
    });
  }

  Future<void> _loadNetwork() async {
    final snap = await fetchRemoteNetworkSnapshot(
      _exec,
      osHint: _os,
    );
    if (!mounted) return;
    if (snap == null) {
      setState(() {
        _error = '无法获取网络信息';
        _loading = false;
      });
      return;
    }
    if (snap.os != RemoteOsKind.unknown) _os = snap.os;
    final prev = _netSnap;
    double rxTotal = 0;
    double txTotal = 0;
    var haveRate = false;
    for (final r in snap.ratesAgainst(prev)) {
      if (r.iface.isLoopback) continue;
      if (r.rxBytesPerSec != null) {
        rxTotal += r.rxBytesPerSec!;
        haveRate = true;
      }
      if (r.txBytesPerSec != null) {
        txTotal += r.txBytesPerSec!;
        haveRate = true;
      }
    }
    if (haveRate) {
      _rxHist.add(rxTotal);
      _txHist.add(txTotal);
      if (_rxHist.length > _histMax) _rxHist.removeAt(0);
      if (_txHist.length > _histMax) _txHist.removeAt(0);
    }
    setState(() {
      _netPrev = prev;
      _netSnap = snap;
      _loading = false;
      _lastTickAt = DateTime.now();
      _error = snap.interfaces.isEmpty && snap.listeners.isEmpty
          ? (_os == RemoteOsKind.windows
              ? '无网络数据（需 PowerShell / Get-NetAdapterStatistics）'
              : '无网络数据（需 /proc/net/dev 或 ss）')
          : null;
    });
  }

  Future<void> _loadServices() async {
    final snap =
        await fetchRemoteServiceSnapshot(_exec, osHint: _os);
    if (!mounted) return;
    if (snap == null) {
      setState(() {
        _error = '无法获取服务列表';
        _loading = false;
      });
      return;
    }
    if (snap.os != RemoteOsKind.unknown) _os = snap.os;
    setState(() {
      _services = snap.services;
      _loading = false;
      _lastTickAt = DateTime.now();
      _error = snap.services.isEmpty
          ? (_os == RemoteOsKind.windows
              ? '无服务数据（需 PowerShell / Get-Service）'
              : '无服务数据（需 systemctl）')
          : null;
      if (_selectedSvc != null &&
          !snap.services.any((s) => s.name == _selectedSvc)) {
        _selectedSvc = null;
      }
    });
  }

  List<RemoteProcess> get _visibleProcs {
    final q = _procFilter.trim().toLowerCase();
    var list = _processes;
    if (q.isNotEmpty) {
      list = list
          .where(
            (p) =>
                p.name.toLowerCase().contains(q) ||
                '${p.pid}'.contains(q) ||
                (p.user?.toLowerCase().contains(q) ?? false),
          )
          .toList();
    } else {
      list = List<RemoteProcess>.from(list);
    }
    int cmp(RemoteProcess a, RemoteProcess b) {
      final int r = switch (_procSort) {
        _ProcSort.name =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        _ProcSort.pid => a.pid.compareTo(b.pid),
        _ProcSort.user =>
          (a.user ?? '').toLowerCase().compareTo((b.user ?? '').toLowerCase()),
        _ProcSort.cpu => (a.cpuPercent ?? -1).compareTo(b.cpuPercent ?? -1),
        _ProcSort.memory =>
          (a.memoryBytes ?? -1).compareTo(b.memoryBytes ?? -1),
      };
      return _procSortAsc ? r : -r;
    }

    list.sort(cmp);
    return list;
  }

  List<RemoteService> get _visibleSvcs {
    final q = _svcFilter.trim().toLowerCase();
    var list = _services;
    if (q.isNotEmpty) {
      list = list
          .where(
            (s) =>
                s.name.toLowerCase().contains(q) ||
                (s.displayName?.toLowerCase().contains(q) ?? false) ||
                s.status.toLowerCase().contains(q),
          )
          .toList();
    } else {
      list = List<RemoteService>.from(list);
    }
    int cmp(RemoteService a, RemoteService b) {
      final int r = switch (_svcSort) {
        _SvcSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        _SvcSort.status => a.status.toLowerCase().compareTo(b.status.toLowerCase()),
        _SvcSort.startType =>
          (a.startType ?? '').compareTo(b.startType ?? ''),
      };
      return _svcSortAsc ? r : -r;
    }

    list.sort(cmp);
    return list;
  }

  void _toggleProcSort(_ProcSort col) {
    setState(() {
      if (_procSort == col) {
        _procSortAsc = !_procSortAsc;
      } else {
        _procSort = col;
        _procSortAsc = col == _ProcSort.name || col == _ProcSort.user;
      }
    });
  }

  void _toggleSvcSort(_SvcSort col) {
    setState(() {
      if (_svcSort == col) {
        _svcSortAsc = !_svcSortAsc;
      } else {
        _svcSort = col;
        _svcSortAsc = col == _SvcSort.name;
      }
    });
  }

  List<RemoteListenSocket> get _visibleListeners {
    final snap = _netSnap;
    if (snap == null) return const [];
    final q = _netFilter.trim().toLowerCase();
    var list = snap.listeners;
    if (q.isNotEmpty) {
      list = list
          .where(
            (s) =>
                '${s.port}'.contains(q) ||
                s.protocol.toLowerCase().contains(q) ||
                s.address.toLowerCase().contains(q) ||
                s.endpoint.toLowerCase().contains(q) ||
                (s.process?.toLowerCase().contains(q) ?? false) ||
                (s.pid != null && '${s.pid}'.contains(q)),
          )
          .toList();
    } else {
      list = List<RemoteListenSocket>.from(list);
    }
    int cmp(RemoteListenSocket a, RemoteListenSocket b) {
      final int r = switch (_netSort) {
        _NetSort.port => a.port.compareTo(b.port),
        _NetSort.protocol => a.protocol.compareTo(b.protocol),
        _NetSort.address => a.address.compareTo(b.address),
        _NetSort.process => (a.process ?? '${a.pid ?? ''}')
            .toLowerCase()
            .compareTo((b.process ?? '${b.pid ?? ''}').toLowerCase()),
      };
      return _netSortAsc ? r : -r;
    }

    list.sort(cmp);
    return list;
  }

  void _toggleNetSort(_NetSort col) {
    setState(() {
      if (_netSort == col) {
        _netSortAsc = !_netSortAsc;
      } else {
        _netSort = col;
        _netSortAsc = col == _NetSort.port || col == _NetSort.protocol;
      }
    });
  }

  void _openListenerInBrowser(RemoteListenSocket sock) {
    final target = sock.browserTarget;
    if (target == null) return;
    widget.wm.open(DesktopAppType.browser, args: {'url': target});
  }

  void _viewProcessListeners(int pid) {
    final q = '$pid';
    setState(() {
      _netFilter = q;
      _netFilterCtrl.text = q;
      _netFilterCtrl.selection = TextSelection.collapsed(offset: q.length);
      _tabs.index = 2;
    });
  }

  void _viewListenerProcess(int pid) {
    final q = '$pid';
    setState(() {
      _selectedPid = pid;
      _procFilter = q;
      _procFilterCtrl.text = q;
      _procFilterCtrl.selection = TextSelection.collapsed(offset: q.length);
      _tabs.index = 0;
    });
  }

  Future<void> _copyText(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制$label'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _copyPid(int pid) async {
    await _copyText(' PID $pid', '$pid');
  }

  Future<void> _copyEndpoint(RemoteListenSocket sock) async {
    await _copyText('端点', sock.endpoint);
  }

  Future<void> _showProcessDetail(RemoteProcess process) async {
    final os = _os ?? RemoteOsKind.unknown;
    setState(() {
      _selectedPid = process.pid;
      _detailOpen = true;
      _detailPid = process.pid;
      _detailFuture = fetchRemoteProcessDetail(
        _exec,
        pid: process.pid,
        os: os,
      );
    });
  }

  void _closeProcessDetail() {
    if (!_detailOpen) return;
    setState(() {
      _detailOpen = false;
      _detailPid = null;
      _detailFuture = null;
    });
  }

  void _clearProcSelection() {
    setState(() {
      if (_detailOpen) {
        _detailOpen = false;
        _detailPid = null;
        _detailFuture = null;
      } else {
        _selectedPid = null;
      }
    });
  }

  void _openProcessLogs(int pid) {
    widget.wm.open(
      DesktopAppType.logs,
      args: {'source': 'journal', 'pid': '$pid'},
    );
  }

  void _openProcessCwd(int pid) {
    if (_os != RemoteOsKind.linux) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('仅 Linux 支持打开进程工作目录')),
      );
      return;
    }
    widget.wm.open(
      DesktopAppType.files,
      args: {'cwd': '/proc/$pid/cwd'},
    );
  }

  Future<void> _endTask({int? pidOverride}) async {
    final pid = pidOverride ?? _selectedPid;
    final os = _os;
    if (pid == null || os == null || os == RemoteOsKind.unknown) return;
    RemoteProcess? proc;
    for (final p in _processes) {
      if (p.pid == pid) {
        proc = p;
        break;
      }
    }
    final name = proc?.name ?? 'PID $pid';
    final result = await confirmKillProcess(
      context,
      name: name,
      pid: pid,
    );
    if (result == null || !mounted) return;
    setState(() {
      _killing = true;
      _selectedPid = pid;
    });
    try {
      await killRemoteProcess(
        _exec,
        os: os,
        pid: pid,
        force: result == true,
      );
      if (!mounted) return;
      setState(() {
        _selectedPid = null;
        _detailOpen = false;
        _detailPid = null;
        _detailFuture = null;
      });
      await _loadProcesses();
    } finally {
      if (mounted) setState(() => _killing = false);
    }
  }

  Future<void> _controlSvc(RemoteServiceAction action) async {
    final name = _selectedSvc;
    final os = _os;
    if (name == null || os == null || os == RemoteOsKind.unknown) return;
    final label = switch (action) {
      RemoteServiceAction.start => '启动',
      RemoteServiceAction.stop => '停止',
      RemoteServiceAction.restart => '重启',
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final wb = ctx.wb;
        return AlertDialog(
          backgroundColor: wb.panelElevated,
          title: Text('$label服务', style: TextStyle(color: wb.primaryText)),
          content: Text(
            '确定$label「$name」？\n可能需要远端管理员权限。',
            style: TextStyle(color: wb.secondaryText, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(label),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    setState(() => _svcBusy = true);
    try {
      final out = await controlRemoteService(
        _exec,
        os: os,
        name: name,
        action: action,
      );
      if (!mounted) return;
      if (out != null &&
          (out.toLowerCase().contains('access denied') ||
              out.toLowerCase().contains('permission'))) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('权限不足：$out')),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _loadServices();
    } finally {
      if (mounted) setState(() => _svcBusy = false);
    }
  }

  String get _osLabel => switch (_os) {
        RemoteOsKind.linux => 'Linux',
        RemoteOsKind.windows => 'Windows',
        RemoteOsKind.unknown || null => '—',
      };

  RemoteProcess? get _detailProcess {
    final pid = _detailPid;
    if (!_detailOpen || pid == null) return null;
    for (final p in _processes) {
      if (p.pid == pid) return p;
    }
    return null;
  }

  bool get _isWindows => _os == RemoteOsKind.windows;

  bool get _windowsHasCpu =>
      _isWindows && _processes.any((p) => p.cpuPercent != null);

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return ColoredBox(
      color: wb.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleBar(
            osLabel: _osLabel,
            loading: _loading,
            connected: _connected,
            paused: _userPaused,
            interval: _interval,
            lastTickAt: _lastTickAt,
            live: !_paused && _connected,
            onPausedChanged: (v) {
              setState(() => _userPaused = v);
              _armTimer();
            },
            onIntervalChanged: (d) {
              setState(() => _interval = d);
              _armTimer();
            },
            onRefresh: () => unawaited(_tick()),
          ),
          Material(
            color: wb.panel,
            child: TabBar(
              controller: _tabs,
              labelColor: wb.accentBlue,
              unselectedLabelColor: wb.textMuted,
              indicatorColor: wb.accentBlue,
              labelStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              tabs: const [
                Tab(text: '进程'),
                Tab(text: '性能'),
                Tab(text: '网络'),
                Tab(text: '服务'),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                _error!,
                style: TextStyle(color: wb.textMuted, fontSize: 12),
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _ProcessesPane(
                  filterCtrl: _procFilterCtrl,
                  filterFocus: _procFilterFocus,
                  listFocus: _procListFocus,
                  listAutofocus: _tabs.index == 0,
                  filter: _procFilter,
                  onFilter: (v) => setState(() => _procFilter = v),
                  rows: _visibleProcs,
                  totalCount: _processes.length,
                  sort: _procSort,
                  sortAsc: _procSortAsc,
                  onSort: _toggleProcSort,
                  selectedPid: _selectedPid,
                  showUser: true,
                  showCpu: !_isWindows || _windowsHasCpu,
                  showWindowsUnavailableBanner:
                      _isWindows && !_windowsHasCpu,
                  isLinux: _os == RemoteOsKind.linux,
                  connected: _connected,
                  canKill: _connected &&
                      _selectedPid != null &&
                      _os != null &&
                      _os != RemoteOsKind.unknown &&
                      !_killing,
                  killing: _killing,
                  detailOpen: _detailOpen,
                  detailProcess: _detailProcess,
                  detailFuture: _detailFuture,
                  onSelect: (pid) => setState(() => _selectedPid = pid),
                  onClearSelection: _clearProcSelection,
                  onCloseDetail: _closeProcessDetail,
                  onOpenDetail: (p) => unawaited(_showProcessDetail(p)),
                  onEndTask: () => unawaited(_endTask()),
                  onEndTaskPid: (pid) => unawaited(_endTask(pidOverride: pid)),
                  onCopyPid: (pid) => unawaited(_copyPid(pid)),
                  onOpenLogs: _openProcessLogs,
                  onOpenCwd: _openProcessCwd,
                  onViewListeners: _viewProcessListeners,
                ),
                _PerformancePane(
                  snap: _snap,
                  gpu: _gpu,
                  cpuHist: _cpuHist,
                  memHist: _memHist,
                ),
                _NetworkPane(
                  snap: _netSnap,
                  prev: _netPrev,
                  rates: _netSnap?.ratesAgainst(_netPrev) ?? const [],
                  rxHist: _rxHist,
                  txHist: _txHist,
                  filterCtrl: _netFilterCtrl,
                  filter: _netFilter,
                  onFilter: (v) => setState(() => _netFilter = v),
                  listeners: _visibleListeners,
                  totalListeners: _netSnap?.listeners.length ?? 0,
                  sort: _netSort,
                  sortAsc: _netSortAsc,
                  onSort: _toggleNetSort,
                  hideLoopback: _netHideLoopback,
                  onHideLoopback: (v) => setState(() => _netHideLoopback = v),
                  connected: _connected,
                  onOpenInBrowser: _openListenerInBrowser,
                  onCopyEndpoint: (sock) => unawaited(_copyEndpoint(sock)),
                  onViewProcess: _viewListenerProcess,
                ),
                _ServicesPane(
                  filterCtrl: _svcFilterCtrl,
                  filter: _svcFilter,
                  onFilter: (v) => setState(() => _svcFilter = v),
                  rows: _visibleSvcs,
                  totalCount: _services.length,
                  sort: _svcSort,
                  sortAsc: _svcSortAsc,
                  onSort: _toggleSvcSort,
                  selected: _selectedSvc,
                  connected: _connected,
                  busy: _svcBusy,
                  canControl: _connected &&
                      _selectedSvc != null &&
                      _os != null &&
                      _os != RemoteOsKind.unknown &&
                      !_svcBusy,
                  onSelect: (n) => setState(() => _selectedSvc = n),
                  onStart: () => unawaited(_controlSvc(RemoteServiceAction.start)),
                  onStop: () => unawaited(_controlSvc(RemoteServiceAction.stop)),
                  onRestart: () =>
                      unawaited(_controlSvc(RemoteServiceAction.restart)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.osLabel,
    required this.loading,
    required this.connected,
    required this.paused,
    required this.interval,
    required this.lastTickAt,
    required this.live,
    required this.onPausedChanged,
    required this.onIntervalChanged,
    required this.onRefresh,
  });

  final String osLabel;
  final bool loading;
  final bool connected;
  final bool paused;
  final Duration interval;
  final DateTime? lastTickAt;
  final bool live;
  final ValueChanged<bool> onPausedChanged;
  final ValueChanged<Duration> onIntervalChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return DesktopAppToolbar(
      height: 44,
      child: Row(
        children: [
          const DesktopAppTitle('任务管理器'),
          const SizedBox(width: 10),
          Flexible(
            child: Align(
              alignment: Alignment.centerLeft,
              child: DesktopMetaChip(label: osLabel),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: DesktopScrollableActions(
              height: 36,
              children: [
                LastUpdatedChip(lastTickAt: lastTickAt, live: live),
                const SizedBox(width: 4),
                PauseToggle(
                  paused: paused,
                  onPausedChanged: onPausedChanged,
                  interval: interval,
                  onIntervalChanged: onIntervalChanged,
                ),
                if (loading)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: wb.accentBlue,
                    ),
                  )
                else
                  DesktopToolIcon(
                    tooltip: '刷新',
                    onPressed: connected ? onRefresh : null,
                    icon: Icons.refresh_rounded,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Processes
// ---------------------------------------------------------------------------

class _ProcessesPane extends StatelessWidget {
  const _ProcessesPane({
    required this.filterCtrl,
    required this.filterFocus,
    required this.listFocus,
    required this.listAutofocus,
    required this.filter,
    required this.onFilter,
    required this.rows,
    required this.totalCount,
    required this.sort,
    required this.sortAsc,
    required this.onSort,
    required this.selectedPid,
    required this.showUser,
    required this.showCpu,
    required this.showWindowsUnavailableBanner,
    required this.isLinux,
    required this.connected,
    required this.canKill,
    required this.killing,
    required this.detailOpen,
    required this.detailProcess,
    required this.detailFuture,
    required this.onSelect,
    required this.onClearSelection,
    required this.onCloseDetail,
    required this.onOpenDetail,
    required this.onEndTask,
    required this.onEndTaskPid,
    required this.onCopyPid,
    required this.onOpenLogs,
    required this.onOpenCwd,
    required this.onViewListeners,
  });

  final TextEditingController filterCtrl;
  final FocusNode filterFocus;
  final FocusNode listFocus;
  final bool listAutofocus;
  final String filter;
  final ValueChanged<String> onFilter;
  final List<RemoteProcess> rows;
  final int totalCount;
  final _ProcSort sort;
  final bool sortAsc;
  final ValueChanged<_ProcSort> onSort;
  final int? selectedPid;
  final bool showUser;
  final bool showCpu;
  final bool showWindowsUnavailableBanner;
  final bool isLinux;
  final bool connected;
  final bool canKill;
  final bool killing;
  final bool detailOpen;
  final RemoteProcess? detailProcess;
  final Future<RemoteProcessDetail?>? detailFuture;
  final ValueChanged<int> onSelect;
  final VoidCallback onClearSelection;
  final VoidCallback onCloseDetail;
  final ValueChanged<RemoteProcess> onOpenDetail;
  final VoidCallback onEndTask;
  final ValueChanged<int> onEndTaskPid;
  final ValueChanged<int> onCopyPid;
  final ValueChanged<int> onOpenLogs;
  final ValueChanged<int> onOpenCwd;
  final ValueChanged<int> onViewListeners;

  void _moveSelection(int delta) {
    if (rows.isEmpty) return;
    final cur = selectedPid == null
        ? -1
        : rows.indexWhere((p) => p.pid == selectedPid);
    var next = cur < 0 ? (delta > 0 ? 0 : rows.length - 1) : cur + delta;
    if (next < 0) next = 0;
    if (next >= rows.length) next = rows.length - 1;
    onSelect(rows[next].pid);
  }

  void _openSelectedDetail() {
    if (selectedPid == null) return;
    for (final p in rows) {
      if (p.pid == selectedPid) {
        onOpenDetail(p);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Row(
            children: [
              Text(
                rows.length == totalCount
                    ? '$totalCount 个进程'
                    : '${rows.length} / $totalCount',
                style: TextStyle(fontSize: 11, color: wb.textMuted),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _FilterField(
                  controller: filterCtrl,
                  focusNode: filterFocus,
                  hint: '筛选名称 / PID / 用户',
                  onChanged: onFilter,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: canKill ? onEndTask : null,
                style: FilledButton.styleFrom(
                  backgroundColor: canKill
                      ? const Color(0xFFEF4444).withValues(alpha: 0.18)
                      : null,
                  foregroundColor:
                      canKill ? const Color(0xFFEF4444) : wb.textMuted,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 32),
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(killing ? '结束中…' : '结束任务'),
              ),
            ],
          ),
        ),
        if (totalCount >= 800)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '仅显示前 800 个进程，请用筛选缩小范围',
                style: TextStyle(fontSize: 11, color: wb.textMuted),
              ),
            ),
          ),
        if (showWindowsUnavailableBanner)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Windows 下 CPU 列不可用（需 PowerShell Get-Process）',
                style: TextStyle(fontSize: 11, color: wb.textMuted),
              ),
            ),
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final table = Column(
                      children: [
                        _ProcHeader(
                          sort: sort,
                          sortAsc: sortAsc,
                          showUser: showUser,
                          showCpu: showCpu,
                          onSort: onSort,
                        ),
                        Expanded(
                          child: Focus(
                            focusNode: listFocus,
                            autofocus: listAutofocus,
                            child: CallbackShortcuts(
                              bindings: {
                                const SingleActivator(
                                  LogicalKeyboardKey.arrowUp,
                                ): () => _moveSelection(-1),
                                const SingleActivator(
                                  LogicalKeyboardKey.arrowDown,
                                ): () => _moveSelection(1),
                                const SingleActivator(
                                  LogicalKeyboardKey.enter,
                                ): _openSelectedDetail,
                                const SingleActivator(
                                  LogicalKeyboardKey.delete,
                                ): () {
                                  if (selectedPid != null) {
                                    onEndTaskPid(selectedPid!);
                                  }
                                },
                                const SingleActivator(
                                  LogicalKeyboardKey.slash,
                                ): () => filterFocus.requestFocus(),
                                const SingleActivator(
                                  LogicalKeyboardKey.keyF,
                                  control: true,
                                ): () => filterFocus.requestFocus(),
                                const SingleActivator(
                                  LogicalKeyboardKey.keyF,
                                  meta: true,
                                ): () => filterFocus.requestFocus(),
                                const SingleActivator(
                                  LogicalKeyboardKey.escape,
                                ): onClearSelection,
                              },
                              child: rows.isEmpty
                                  ? Center(
                                      child: Text(
                                        connected ? '无匹配进程' : '未连接',
                                        style: TextStyle(color: wb.textMuted),
                                      ),
                                    )
                                  : ListView.builder(
                                      itemCount: rows.length,
                                      itemBuilder: (context, i) {
                                        final p = rows[i];
                                        return _ProcRow(
                                          process: p,
                                          selected: p.pid == selectedPid,
                                          showUser: showUser,
                                          showCpu: showCpu,
                                          onTap: () {
                                            onSelect(p.pid);
                                            listFocus.requestFocus();
                                          },
                                          onDoubleTap: () => onOpenDetail(p),
                                          onSecondaryTapDown: (details) async {
                                            onSelect(p.pid);
                                            final action =
                                                await showMenu<String>(
                                              context: context,
                                              position: RelativeRect.fromLTRB(
                                                details.globalPosition.dx,
                                                details.globalPosition.dy,
                                                details.globalPosition.dx,
                                                details.globalPosition.dy,
                                              ),
                                              items: [
                                                const PopupMenuItem(
                                                  value: 'detail',
                                                  child: Text('查看详情'),
                                                ),
                                                const PopupMenuItem(
                                                  value: 'listeners',
                                                  child: Text('查看监听端口'),
                                                ),
                                                PopupMenuItem(
                                                  value: 'copyPid',
                                                  child:
                                                      Text('复制 PID ${p.pid}'),
                                                ),
                                                if (isLinux)
                                                  const PopupMenuItem(
                                                    value: 'logs',
                                                    child: Text('查看日志'),
                                                  ),
                                                if (isLinux)
                                                  const PopupMenuItem(
                                                    value: 'cwd',
                                                    child: Text('打开所在目录'),
                                                  ),
                                                const PopupMenuItem(
                                                  value: 'kill',
                                                  child: Text('结束任务'),
                                                ),
                                              ],
                                            );
                                            if (!context.mounted ||
                                                action == null) {
                                              return;
                                            }
                                            switch (action) {
                                              case 'detail':
                                                onOpenDetail(p);
                                              case 'listeners':
                                                onViewListeners(p.pid);
                                              case 'copyPid':
                                                onCopyPid(p.pid);
                                              case 'logs':
                                                onOpenLogs(p.pid);
                                              case 'cwd':
                                                onOpenCwd(p.pid);
                                              case 'kill':
                                                onEndTaskPid(p.pid);
                                            }
                                          },
                                        );
                                      },
                                    ),
                            ),
                          ),
                        ),
                      ],
                    );
                    if (constraints.maxWidth < 700) {
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: 700,
                            maxHeight: constraints.maxHeight,
                          ),
                          child: SizedBox(
                            width: 700,
                            height: constraints.maxHeight,
                            child: table,
                          ),
                        ),
                      );
                    }
                    return table;
                  },
                ),
              ),
              if (detailOpen && detailProcess != null)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  width: 280,
                  child: _ProcessDetailPanel(
                    process: detailProcess!,
                    detailFuture: detailFuture,
                    canKill: canKill,
                    killing: killing,
                    onClose: onCloseDetail,
                    onEndTask: () => onEndTaskPid(detailProcess!.pid),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProcHeader extends StatelessWidget {
  const _ProcHeader({
    required this.sort,
    required this.sortAsc,
    required this.showUser,
    required this.showCpu,
    required this.onSort,
  });

  final _ProcSort sort;
  final bool sortAsc;
  final bool showUser;
  final bool showCpu;
  final ValueChanged<_ProcSort> onSort;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: wb.panel,
        border: Border(
          top: BorderSide(color: wb.border),
          bottom: BorderSide(color: wb.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: _SortLabel(
              label: '名称',
              active: sort == _ProcSort.name,
              asc: sortAsc,
              onTap: () => onSort(_ProcSort.name),
            ),
          ),
          SizedBox(
            width: 72,
            child: _SortLabel(
              label: 'PID',
              active: sort == _ProcSort.pid,
              asc: sortAsc,
              onTap: () => onSort(_ProcSort.pid),
              alignEnd: true,
            ),
          ),
          if (showUser)
            Expanded(
              flex: 2,
              child: _SortLabel(
                label: '用户',
                active: sort == _ProcSort.user,
                asc: sortAsc,
                onTap: () => onSort(_ProcSort.user),
              ),
            ),
          if (showCpu)
            SizedBox(
              width: 64,
              child: _SortLabel(
                label: 'CPU',
                active: sort == _ProcSort.cpu,
                asc: sortAsc,
                onTap: () => onSort(_ProcSort.cpu),
                alignEnd: true,
              ),
            ),
          SizedBox(
            width: 88,
            child: _SortLabel(
              label: '内存',
              active: sort == _ProcSort.memory,
              asc: sortAsc,
              onTap: () => onSort(_ProcSort.memory),
              alignEnd: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProcRow extends StatelessWidget {
  const _ProcRow({
    required this.process,
    required this.selected,
    required this.showUser,
    required this.showCpu,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTapDown,
  });

  final RemoteProcess process;
  final bool selected;
  final bool showUser;
  final bool showCpu;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final GestureTapDownCallback onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final cpu = process.cpuPercent;
    final mem = formatProcessMemory(process.memoryBytes);
    return Material(
      color: selected
          ? wb.accentBlue.withValues(alpha: 0.16)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        onSecondaryTapDown: onSecondaryTapDown,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: wb.border.withValues(alpha: 0.45)),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Text(
                  process.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: wb.primaryText,
                  ),
                ),
              ),
              SizedBox(
                width: 72,
                child: Text(
                  '${process.pid}',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: wb.secondaryText,
                  ),
                ),
              ),
              if (showUser)
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      process.user ?? '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: wb.secondaryText,
                      ),
                    ),
                  ),
                ),
              if (showCpu)
                SizedBox(
                  width: 64,
                  child: Text(
                    cpu == null ? '—' : '${cpu.toStringAsFixed(1)}%',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: wb.secondaryText,
                    ),
                  ),
                ),
              SizedBox(
                width: 88,
                child: Text(
                  mem,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: wb.secondaryText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Performance
// ---------------------------------------------------------------------------

class _PerformancePane extends StatelessWidget {
  const _PerformancePane({
    required this.snap,
    required this.gpu,
    required this.cpuHist,
    required this.memHist,
  });

  final RemoteHostSnapshot? snap;
  final RemoteGpuSnapshot? gpu;
  final List<double> cpuHist;
  final List<double> memHist;

  String _pct(double? v) {
    if (v == null) return '—';
    return '${(v * 100).clamp(0, 100).toStringAsFixed(0)}%';
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final s = snap;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _PerfCard(
              label: 'CPU',
              value: _pct(s?.cpuUsed01),
              tone: s?.cpuUsed01,
              history: cpuHist,
            ),
            _PerfCard(
              label: '内存',
              value: _pct(s?.memUsed01),
              tone: s?.memUsed01,
              history: memHist,
            ),
            _PerfCard(
              label: '磁盘',
              value: _pct(s?.diskUsed01),
              tone: s?.diskUsed01,
            ),
            _PerfCard(
              label: 'Inode',
              value: _pct(s?.inodeUsed01),
              tone: s?.inodeUsed01,
            ),
            _PerfCard(
              label: '负载',
              value: s?.loadLine ?? '—',
              tone: s?.loadPressure01,
            ),
          ],
        ),
        if (gpu != null && gpu!.available && gpu!.gpus.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('GPU', style: TextStyle(fontSize: 11, color: wb.textMuted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final g in gpu!.gpus)
                _PerfCard(
                  label: 'GPU${g.index} · ${g.name}',
                  value: _pct(g.util01),
                  tone: g.util01,
                  subtitle: [
                    if (g.memUsedMiB != null && g.memTotalMiB != null)
                      '${g.memUsedMiB!.toStringAsFixed(0)}/${g.memTotalMiB!.toStringAsFixed(0)} MiB',
                    if (g.tempC != null) '${g.tempC!.toStringAsFixed(0)}°C',
                  ].where((e) => e.isNotEmpty).join(' · '),
                ),
            ],
          ),
        ] else if (gpu != null && !gpu!.available) ...[
          const SizedBox(height: 16),
          Text(
            gpu!.error == null
                ? '未检测到 NVIDIA GPU（需 nvidia-smi）'
                : 'GPU：${gpu!.error}',
            style: TextStyle(fontSize: 11, color: wb.textMuted),
          ),
        ],
        if (s?.hostInfoLine != null) ...[
          const SizedBox(height: 16),
          Text('主机', style: TextStyle(fontSize: 11, color: wb.textMuted)),
          const SizedBox(height: 4),
          Text(
            s!.hostInfoLine!,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: wb.secondaryText,
            ),
          ),
        ],
        if (s?.uptimeLine != null) ...[
          const SizedBox(height: 12),
          Text('运行时间', style: TextStyle(fontSize: 11, color: wb.textMuted)),
          const SizedBox(height: 4),
          Text(
            s!.uptimeLine!,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: wb.secondaryText,
            ),
          ),
        ],
        if (s != null && s.mounts.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('磁盘挂载', style: TextStyle(fontSize: 11, color: wb.textMuted)),
          const SizedBox(height: 8),
          _MountBars(mounts: s.mounts),
        ] else if (s?.dfSpaceLine != null) ...[
          const SizedBox(height: 12),
          Text('磁盘详情', style: TextStyle(fontSize: 11, color: wb.textMuted)),
          const SizedBox(height: 4),
          Text(
            s!.dfSpaceLine!,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: wb.secondaryText,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'Linux：/proc + df；Windows：CIM；GPU：nvidia-smi（可选）。',
          style: TextStyle(fontSize: 11, color: wb.textMuted),
        ),
      ],
    );
  }
}

class _PerfCard extends StatelessWidget {
  const _PerfCard({
    required this.label,
    required this.value,
    this.tone,
    this.history,
    this.subtitle,
  });

  final String label;
  final String value;
  final double? tone;
  final List<double>? history;
  final String? subtitle;

  Color _toneColor(BuildContext context) {
    final t = tone;
    if (t == null) return context.wb.primaryText;
    if (t >= 0.9) return const Color(0xFFEF4444);
    if (t >= 0.75) return const Color(0xFFEAB308);
    return context.wb.online;
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final hist = history;
    final sub = subtitle?.trim();
    return Container(
      width: sub == null || sub.isEmpty ? 160 : 200,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: wb.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: wb.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: wb.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: _toneColor(context),
              fontFamily: 'monospace',
            ),
          ),
          if (sub != null && sub.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: wb.textMuted),
            ),
          ],
          if (hist != null && hist.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 32,
              width: double.infinity,
              child: CustomPaint(
                painter: _SparkPainter(
                  values: List<double>.from(hist),
                  color: wb.accentBlue,
                ),
              ),
            ),
          ],
          if (tone != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: tone!.clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: wb.border,
                color: _toneColor(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final n = values.length;
    for (var i = 0; i < n; i++) {
      final x = n == 1 ? 0.0 : size.width * i / (n - 1);
      final y = size.height * (1 - values[i].clamp(0.0, 1.0));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.values != values || old.color != color;
}

class _MountBars extends StatelessWidget {
  const _MountBars({required this.mounts});

  final List<RemoteDiskMount> mounts;

  Color _tone(BuildContext context, double t) {
    if (t >= 0.9) return const Color(0xFFEF4444);
    if (t >= 0.75) return const Color(0xFFEAB308);
    return context.wb.online;
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Column(
      children: [
        for (final m in mounts.take(12))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        m.mountPoint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: wb.primaryText,
                        ),
                      ),
                    ),
                    Text(
                      '${(m.used01 * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: _tone(context, m.used01),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${formatDiskBytes(m.usedBytes)} / ${formatDiskBytes(m.sizeBytes)}'
                  '${m.filesystem != m.mountPoint ? ' · ${m.filesystem}' : ''}',
                  style: TextStyle(fontSize: 11, color: wb.textMuted),
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: m.used01.clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: wb.border,
                    color: _tone(context, m.used01),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

class _NetworkPane extends StatelessWidget {
  const _NetworkPane({
    required this.snap,
    required this.prev,
    required this.rates,
    required this.rxHist,
    required this.txHist,
    required this.filterCtrl,
    required this.filter,
    required this.onFilter,
    required this.listeners,
    required this.totalListeners,
    required this.sort,
    required this.sortAsc,
    required this.onSort,
    required this.hideLoopback,
    required this.onHideLoopback,
    required this.connected,
    required this.onOpenInBrowser,
    required this.onCopyEndpoint,
    required this.onViewProcess,
  });

  final RemoteNetworkSnapshot? snap;
  final RemoteNetworkSnapshot? prev;
  final List<RemoteNetIfaceRate> rates;
  final List<double> rxHist;
  final List<double> txHist;
  final TextEditingController filterCtrl;
  final String filter;
  final ValueChanged<String> onFilter;
  final List<RemoteListenSocket> listeners;
  final int totalListeners;
  final _NetSort sort;
  final bool sortAsc;
  final ValueChanged<_NetSort> onSort;
  final bool hideLoopback;
  final ValueChanged<bool> onHideLoopback;
  final bool connected;
  final ValueChanged<RemoteListenSocket> onOpenInBrowser;
  final ValueChanged<RemoteListenSocket> onCopyEndpoint;
  final ValueChanged<int> onViewProcess;

  List<double> _norm(List<double> hist, [double? sharedMax]) {
    if (hist.isEmpty) return hist;
    var max = sharedMax ?? 0.0;
    if (sharedMax == null) {
      for (final v in hist) {
        if (v > max) max = v;
      }
    }
    if (max <= 0) return List<double>.filled(hist.length, 0);
    return [for (final v in hist) (v / max).clamp(0.0, 1.0)];
  }

  double _peak(List<double> hist) {
    var max = 0.0;
    for (final v in hist) {
      if (v > max) max = v;
    }
    return max;
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final s = snap;
    final visibleRates = [
      for (final r in rates)
        if (!hideLoopback || !r.iface.isLoopback) r,
    ];

    double? rxSum;
    double? txSum;
    for (final r in visibleRates) {
      if (r.rxBytesPerSec != null) {
        rxSum = (rxSum ?? 0) + r.rxBytesPerSec!;
      }
      if (r.txBytesPerSec != null) {
        txSum = (txSum ?? 0) + r.txBytesPerSec!;
      }
    }

    // Shared Y-scale so rx/tx sparklines are comparable.
    var jointMax = 0.0;
    for (final v in rxHist) {
      if (v > jointMax) jointMax = v;
    }
    for (final v in txHist) {
      if (v > jointMax) jointMax = v;
    }
    final rxPeak = _peak(rxHist);
    final txPeak = _peak(txHist);

    // Two Expanded regions share leftover height after the fixed filter/chrome
    // so short TabBarView viewports never RenderFlex-overflow.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 2,
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _PerfCard(
                      label: '下行',
                      value: formatNetRate(rxSum),
                      history: _norm(rxHist, jointMax),
                      subtitle: rxPeak > 0
                          ? '峰值 ${formatNetRate(rxPeak)}'
                          : null,
                    ),
                    _PerfCard(
                      label: '上行',
                      value: formatNetRate(txSum),
                      history: _norm(txHist, jointMax),
                      subtitle: txPeak > 0
                          ? '峰值 ${formatNetRate(txPeak)}'
                          : null,
                    ),
                    _PerfCard(
                      label: '已建立',
                      value: s?.tcpEstablished?.toString() ?? '—',
                    ),
                    _PerfCard(
                      label: '监听',
                      value: s?.tcpListen?.toString() ??
                          (s == null ? '—' : '${s.listeners.length}'),
                    ),
                    _PerfCard(
                      label: 'TIME_WAIT',
                      value: s?.tcpTimeWait?.toString() ?? '—',
                    ),
                  ],
                ),
              ),
              if (visibleRates.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                  child: Row(
                    children: [
                      Text(
                        '网卡',
                        style: TextStyle(fontSize: 11, color: wb.textMuted),
                      ),
                      const Spacer(),
                      FilterChip(
                        label: const Text(
                          '隐藏回环',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: hideLoopback,
                        onSelected: onHideLoopback,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  child: Column(
                    children: [
                      for (final r in visibleRates.take(8))
                        _IfaceRow(rate: r),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Text(
                filter.isEmpty
                    ? '$totalListeners 个监听端口'
                    : '${listeners.length} / $totalListeners',
                style: TextStyle(fontSize: 11, color: wb.textMuted),
              ),
              const Spacer(),
              if (prev == null && s != null)
                Text(
                  '速率需再采一次样',
                  style: TextStyle(fontSize: 11, color: wb.textMuted),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: filterCtrl,
            onChanged: onFilter,
            style: TextStyle(fontSize: 13, color: wb.primaryText),
            decoration: InputDecoration(
              isDense: true,
              hintText: '筛选端口 / 地址 / 协议 / PID',
              hintStyle: TextStyle(color: wb.textMuted, fontSize: 13),
              prefixIcon: Icon(Icons.search, size: 18, color: wb.textMuted),
              filled: true,
              fillColor: wb.panel,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: wb.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: wb.border),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          flex: 3,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final listBody = !connected && s == null
                  ? Center(
                      child: Text(
                        '未连接',
                        style: TextStyle(color: wb.textMuted),
                      ),
                    )
                  : listeners.isEmpty
                      ? Center(
                          child: Text(
                            connected ? '无匹配监听端口' : '未连接',
                            style: TextStyle(color: wb.textMuted),
                          ),
                        )
                      : ListView.builder(
                          itemCount: listeners.length,
                          itemBuilder: (context, i) {
                            final sock = listeners[i];
                            final canBrowse = sock.browserTarget != null;
                            return Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onDoubleTap: canBrowse
                                    ? () => onOpenInBrowser(sock)
                                    : null,
                                onSecondaryTapDown: (d) async {
                                  final selected = await showMenu<String>(
                                    context: context,
                                    position: RelativeRect.fromLTRB(
                                      d.globalPosition.dx,
                                      d.globalPosition.dy,
                                      d.globalPosition.dx,
                                      d.globalPosition.dy,
                                    ),
                                    items: [
                                      const PopupMenuItem(
                                        value: 'copy',
                                        child: Text('复制端点'),
                                      ),
                                      if (sock.pid != null)
                                        const PopupMenuItem(
                                          value: 'process',
                                          child: Text('查看进程'),
                                        ),
                                      if (canBrowse)
                                        const PopupMenuItem(
                                          value: 'browser',
                                          child: Text('在浏览器打开'),
                                        ),
                                    ],
                                  );
                                  if (!context.mounted || selected == null) {
                                    return;
                                  }
                                  switch (selected) {
                                    case 'copy':
                                      onCopyEndpoint(sock);
                                    case 'process':
                                      final pid = sock.pid;
                                      if (pid != null) onViewProcess(pid);
                                    case 'browser':
                                      onOpenInBrowser(sock);
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 1,
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 56,
                                        child: Text(
                                          sock.protocol,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontFamily: 'monospace',
                                            color: wb.secondaryText,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 64,
                                        child: Text(
                                          '${sock.port}',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontFamily: 'monospace',
                                            fontWeight: FontWeight.w600,
                                            color: wb.primaryText,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          sock.address,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontFamily: 'monospace',
                                            color: wb.secondaryText,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 72,
                                        child: Text(
                                          sock.process ??
                                              (sock.pid != null
                                                  ? '${sock.pid}'
                                                  : '—'),
                                          textAlign: TextAlign.right,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontFamily: 'monospace',
                                            color: wb.textMuted,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        );
              final table = Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        _NetHeader(
                          label: '协议',
                          width: 56,
                          active: sort == _NetSort.protocol,
                          asc: sortAsc,
                          onTap: () => onSort(_NetSort.protocol),
                        ),
                        _NetHeader(
                          label: '端口',
                          width: 64,
                          active: sort == _NetSort.port,
                          asc: sortAsc,
                          onTap: () => onSort(_NetSort.port),
                        ),
                        Expanded(
                          child: _NetHeader(
                            label: '地址',
                            active: sort == _NetSort.address,
                            asc: sortAsc,
                            onTap: () => onSort(_NetSort.address),
                          ),
                        ),
                        _NetHeader(
                          label: '进程',
                          width: 72,
                          alignEnd: true,
                          active: sort == _NetSort.process,
                          asc: sortAsc,
                          onTap: () => onSort(_NetSort.process),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: listBody),
                ],
              );
              if (constraints.maxWidth < 700) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: 700,
                      maxHeight: constraints.maxHeight,
                    ),
                    child: SizedBox(
                      width: 700,
                      height: constraints.maxHeight,
                      child: table,
                    ),
                  ),
                );
              }
              return table;
            },
          ),
        ),
      ],
    );
  }
}

class _IfaceRow extends StatelessWidget {
  const _IfaceRow({required this.rate});

  final RemoteNetIfaceRate rate;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final i = rate.iface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              i.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: wb.primaryText,
              ),
            ),
          ),
          Expanded(
            child: Text(
              '↓ ${formatNetRate(rate.rxBytesPerSec)}  ·  ↑ ${formatNetRate(rate.txBytesPerSec)}',
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: wb.secondaryText,
              ),
            ),
          ),
          Text(
            '累计 ${formatNetBytes(i.rxBytes + i.txBytes)}',
            style: TextStyle(fontSize: 11, color: wb.textMuted),
          ),
        ],
      ),
    );
  }
}

class _NetHeader extends StatelessWidget {
  const _NetHeader({
    required this.label,
    required this.active,
    required this.asc,
    required this.onTap,
    this.width,
    this.alignEnd = false,
  });

  final String label;
  final bool active;
  final bool asc;
  final VoidCallback onTap;
  final double? width;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final child = InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          mainAxisAlignment:
              alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? wb.accentBlue : wb.textMuted,
              ),
            ),
            if (active)
              Icon(
                asc ? Icons.arrow_upward : Icons.arrow_downward,
                size: 12,
                color: wb.accentBlue,
              ),
          ],
        ),
      ),
    );
    if (width != null) return SizedBox(width: width, child: child);
    return child;
  }
}

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

class _ServicesPane extends StatelessWidget {
  const _ServicesPane({
    required this.filterCtrl,
    required this.filter,
    required this.onFilter,
    required this.rows,
    required this.totalCount,
    required this.sort,
    required this.sortAsc,
    required this.onSort,
    required this.selected,
    required this.connected,
    required this.busy,
    required this.canControl,
    required this.onSelect,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
  });

  final TextEditingController filterCtrl;
  final String filter;
  final ValueChanged<String> onFilter;
  final List<RemoteService> rows;
  final int totalCount;
  final _SvcSort sort;
  final bool sortAsc;
  final ValueChanged<_SvcSort> onSort;
  final String? selected;
  final bool connected;
  final bool busy;
  final bool canControl;
  final ValueChanged<String> onSelect;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Row(
            children: [
              Text(
                rows.length == totalCount
                    ? '$totalCount 个服务'
                    : '${rows.length} / $totalCount',
                style: TextStyle(fontSize: 11, color: wb.textMuted),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _FilterField(
                  controller: filterCtrl,
                  hint: '筛选服务名 / 显示名 / 状态',
                  onChanged: onFilter,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: DesktopScrollableActions(
                  children: [
                    _SvcActionBtn(
                      label: '启动',
                      onPressed: canControl ? onStart : null,
                    ),
                    const SizedBox(width: 4),
                    _SvcActionBtn(
                      label: '停止',
                      onPressed: canControl ? onStop : null,
                      danger: true,
                    ),
                    const SizedBox(width: 4),
                    _SvcActionBtn(
                      label: busy ? '…' : '重启',
                      onPressed: canControl ? onRestart : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: wb.panel,
            border: Border(
              top: BorderSide(color: wb.border),
              bottom: BorderSide(color: wb.border),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: _SortLabel(
                  label: '名称',
                  active: sort == _SvcSort.name,
                  asc: sortAsc,
                  onTap: () => onSort(_SvcSort.name),
                ),
              ),
              SizedBox(
                width: 96,
                child: _SortLabel(
                  label: '状态',
                  active: sort == _SvcSort.status,
                  asc: sortAsc,
                  onTap: () => onSort(_SvcSort.status),
                ),
              ),
              SizedBox(
                width: 88,
                child: _SortLabel(
                  label: '启动类型',
                  active: sort == _SvcSort.startType,
                  asc: sortAsc,
                  onTap: () => onSort(_SvcSort.startType),
                ),
              ),
              const Expanded(
                flex: 4,
                child: Text(
                  '显示名',
                  style: TextStyle(fontSize: 11, color: Color(0xFF8B949E)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    connected ? '无匹配服务' : '未连接',
                    style: TextStyle(color: wb.textMuted),
                  ),
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final s = rows[i];
                    final sel = s.name == selected;
                    return Material(
                      color: sel
                          ? wb.accentBlue.withValues(alpha: 0.16)
                          : Colors.transparent,
                      child: InkWell(
                        onTap: () => onSelect(s.name),
                        child: Container(
                          height: 30,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: wb.border.withValues(alpha: 0.45),
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: Text(
                                  s.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    color: wb.primaryText,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 96,
                                child: Text(
                                  s.subState == null
                                      ? s.status
                                      : '${s.status}/${s.subState}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    color: s.isRunning
                                        ? wb.online
                                        : wb.secondaryText,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 88,
                                child: Text(
                                  s.startType ?? '—',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    color: wb.secondaryText,
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 4,
                                child: Text(
                                  s.displayName ?? '—',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: wb.secondaryText,
                                  ),
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

class _SvcActionBtn extends StatelessWidget {
  const _SvcActionBtn({
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    final enabled = onPressed != null;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: !enabled
            ? wb.textMuted
            : danger
                ? const Color(0xFFEF4444)
                : wb.accentBlue,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------

class _ProcessDetailPanel extends StatelessWidget {
  const _ProcessDetailPanel({
    required this.process,
    required this.detailFuture,
    required this.canKill,
    required this.killing,
    required this.onClose,
    required this.onEndTask,
  });

  final RemoteProcess process;
  final Future<RemoteProcessDetail?>? detailFuture;
  final bool canKill;
  final bool killing;
  final VoidCallback onClose;
  final VoidCallback onEndTask;

  Future<void> _copy(BuildContext context, String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制$label'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Material(
      color: wb.panel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: wb.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      process.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: wb.primaryText,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: onClose,
                    icon: Icon(Icons.close_rounded, size: 18, color: wb.textMuted),
                    visualDensity: VisualDensity.compact,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Text(
                'PID ${process.pid}',
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: wb.textMuted,
                ),
              ),
            ),
            Divider(height: 1, color: wb.border),
            Expanded(
              child: FutureBuilder<RemoteProcessDetail?>(
                future: detailFuture,
                builder: (context, snap) {
                  if (detailFuture == null ||
                      snap.connectionState != ConnectionState.done) {
                    return const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  final d = snap.data;
                  final cmdline = d?.cmdline ?? process.cmdline;
                  final ppid = d?.ppid ?? process.ppid;
                  final start = d?.startTime ?? process.startTime;
                  final message = d?.message;
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
                    children: [
                      if (message != null && message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            message,
                            style:
                                TextStyle(color: wb.textMuted, fontSize: 12),
                          ),
                        ),
                      _DetailRow(
                        label: '命令行',
                        value: (cmdline == null || cmdline.isEmpty)
                            ? '—'
                            : cmdline,
                        onCopy: cmdline == null || cmdline.isEmpty
                            ? null
                            : () => unawaited(_copy(context, '命令行', cmdline)),
                      ),
                      const SizedBox(height: 12),
                      _DetailRow(
                        label: 'PPID',
                        value: ppid == null ? '—' : '$ppid',
                        onCopy: ppid == null
                            ? null
                            : () => unawaited(_copy(context, 'PPID', '$ppid')),
                      ),
                      const SizedBox(height: 12),
                      _DetailRow(
                        label: '启动时间',
                        value: (start == null || start.isEmpty) ? '—' : start,
                        onCopy: start == null || start.isEmpty
                            ? null
                            : () => unawaited(_copy(context, '启动时间', start)),
                      ),
                      const SizedBox(height: 12),
                      _DetailRow(
                        label: 'PID',
                        value: '${process.pid}',
                        onCopy: () => unawaited(
                          _copy(context, 'PID', '${process.pid}'),
                        ),
                      ),
                      if (process.user != null) ...[
                        const SizedBox(height: 12),
                        _DetailRow(
                          label: '用户',
                          value: process.user!,
                          onCopy: () =>
                              unawaited(_copy(context, '用户', process.user!)),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: FilledButton.tonal(
                onPressed: canKill ? onEndTask : null,
                style: FilledButton.styleFrom(
                  backgroundColor: canKill
                      ? const Color(0xFFEF4444).withValues(alpha: 0.18)
                      : null,
                  foregroundColor:
                      canKill ? const Color(0xFFEF4444) : wb.textMuted,
                  minimumSize: const Size(double.infinity, 36),
                ),
                child: Text(killing ? '结束中…' : '结束任务'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: wb.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (onCopy != null)
              IconButton(
                tooltip: '复制',
                onPressed: onCopy,
                icon: Icon(Icons.copy_rounded, size: 16, color: wb.textMuted),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                padding: EdgeInsets.zero,
              ),
          ],
        ),
        SelectableText(
          value,
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: wb.primaryText,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

class _FilterField extends StatelessWidget {
  const _FilterField({
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.focusNode,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return SizedBox(
      height: 32,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        style: TextStyle(fontSize: 13, color: wb.primaryText),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(color: wb.textMuted, fontSize: 12),
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: wb.textMuted),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          filled: true,
          fillColor: wb.panel,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
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
        ),
      ),
    );
  }
}

class _SortLabel extends StatelessWidget {
  const _SortLabel({
    required this.label,
    required this.active,
    required this.asc,
    required this.onTap,
    this.alignEnd = false,
  });

  final String label;
  final bool active;
  final bool asc;
  final VoidCallback onTap;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final wb = context.wb;
    return InkWell(
      onTap: onTap,
      child: Row(
        mainAxisAlignment:
            alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? wb.accentBlue : wb.textMuted,
            ),
          ),
          if (active) ...[
            const SizedBox(width: 2),
            Icon(
              asc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              size: 12,
              color: wb.accentBlue,
            ),
          ],
        ],
      ),
    );
  }
}
