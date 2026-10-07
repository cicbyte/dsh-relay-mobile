import 'package:flutter/material.dart';

import 'device_info.dart';
import 'dsh/conn_store.dart';
import 'dsh/dsh_client.dart';
import 'dsh/interactions.dart';
import 'dsh/profiles.dart';
import 'dsh/transport.dart';
import 'pages/host_status_page.dart';
import 'pages/session_page.dart';
import 'pages/settings_page.dart';
import 'theme.dart';
import 'widgets/workspace_picker.dart';

/// 应用根：持有连接状态（transport/client）与会话列表，供抽屉与主内容共享。
class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> rootScaffoldKey = GlobalKey<ScaffoldState>();
  final ValueNotifier<int> tabIndex = ValueNotifier<int>(0);

  DshTransport? _transport;
  DshClient? _client;
  String _modeLabel = '未连接';

  /// 当前配对设备 id（附件下载链接绑定用）；直连模式为空。
  String get _activeDeviceId {
    final t = _transport;
    return t is RelayTransport ? t.deviceId : '';
  }

  List<SessionSummary> _sessions = [];
  SessionSummary? _selected;
  bool _sessionsLoading = false;
  bool _sessionRestored = false;

  // ---- 工作区分组（workspace/follow：桌面侧栏同源）----

  /// 有序工作区（workspaceId/title/path/sessionIds）。
  List<Map<String, dynamic>> _workspaces = [];

  /// 宿主全局置顶/归档集（会话 id）。
  Set<String> _pinnedIds = {};
  Set<String> _archivedIds = {};

  /// 抽屉组折叠状态（默认全展开）。
  final Set<String> _collapsedGroups = {};
  DshMux? _wsMux;

  /// 已见交互 id（去重防重复通知；交互消失即移出）。
  final Set<String> _seenInteractions = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 回前台自动恢复（后台杀连接是常态）
    keepAliveNotifier.addListener(_syncKeepAlive);
    InteractionCenter.I.pending.addListener(_onPendingChanged);
    // 通知点开直达：原生把 dsh.sessionId 转发过来，选中对应会话并回到会话 tab
    setDshNativeEventHandler(_onNativeEvent);
    _autoConnect();
  }

  /// 原生事件：openSession（点通知深链）
  Future<void> _onNativeEvent(String method, Map<dynamic, dynamic> args) async {
    if (method != 'openSession') return;
    final sid = '${args['sessionId'] ?? ''}';
    if (sid.isEmpty) return;
    // 会话列表还没到（冷启动竞况）：刷一次，到了自然选中
    if (_sessions.isEmpty && _client != null && !_sessionsLoading) {
      await refreshSessions();
    }
    final hit = _sessions.where((s) => s.sessionId == sid).toList();
    if (!mounted) return;
    if (hit.isNotEmpty) {
      setState(() => _selected = hit.first);
    }
    tabIndex.value = 0;
  }

  /// 保活前台服务跟随连接与开关：连上且开关开 → 起；否则停。
  /// 切换开关即时生效（设置页改 keepAliveNotifier 即触发）。
  void _syncKeepAlive() {
    if (_client != null && keepAliveNotifier.value) {
      keepAliveStart();
    } else {
      keepAliveStop();
    }
  }

  /// 后台新到交互（提问/授权）→ 系统通知点开直达；前台不弹（UI 已呈现卡）。
  void _onPendingChanged() {
    final list = InteractionCenter.I.pending.value;
    final bg =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    for (final p in list) {
      final isNew = _seenInteractions.add(p.eventId);
      if (isNew && bg) {
        final kind = p.isQuestion ? '提问' : (p.isApproval ? '授权' : '交互');
        var hint = '';
        if (p.isQuestion && p.questions.isNotEmpty) {
          final q = p.questions.first;
          hint = '${q['header'] ?? q['title'] ?? ''}';
        } else if (p.isApproval) {
          hint = '${p.request['summary'] ?? p.request['action'] ?? ''}';
        }
        notifyEvent(
          'DSH 需要$kind',
          hint.isEmpty ? '点开查看详情' : hint.trim(),
          sessionId: p.agentId,
        );
      }
    }
    // 已消失（取消/已答）的移出记录：同 id 再来仍算新事件
    _seenInteractions.retainAll(list.map((e) => e.eventId).toSet());
  }

  /// 回前台自愈：刷新会话列表（后台期间的状态变化一次补齐）+ 唤醒全局事件流
  /// （$events 重连会补投 pending，无需对账）。传输层重连由 RelayTransport
  /// 自愈循环 + 各 mux 的持续重试负责，这里只做数据面刷新。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    InteractionCenter.I.kick();
    if (_client != null && !_sessionsLoading) refreshSessions();
  }

  /// 启动自动重连：用上次的活动环境直接连（Profile 持久化，免每次手配）。
  /// 自动重连失败不打扰用户（桌面未启动/adb reverse 未建立等），
  /// 停在空态，连接设置页手动连接照常可用。
  /// 鉴权类拒绝（令牌失效/被吊销等）由 RelayTransport 内部停止重拨，
  /// 这里只试一次，绝不产生 1/s 重连风暴。
  Future<void> _autoConnect() async {
    // 有环境用活动环境；首次启动用默认直连配置直接试连（失败静默，零配置即用）。
    final profiles = await ProfileStore.load();
    final activeId = await ProfileStore.activeId();
    EnvProfile? picked;
    for (final e in profiles) {
      if (e.id == activeId) {
        picked = e;
        break;
      }
    }
    final p =
        picked ??
        (profiles.isNotEmpty
            ? profiles.first
            : EnvProfile(id: 'default', name: '默认环境', mode: 0));
    if (!mounted) return;
    try {
      final DshTransport transport;
      final String modeLabel;
      if (!p.isRelay) {
        final raw = p.url.replaceFirst(RegExp(r'/+$'), '');
        transport = DirectTransport(Uri.parse(raw));
        modeLabel = '直连 · $raw';
      } else {
        final savedToken = await ProfileStore.tokenOf(p.id) ?? '';
        final relay = RelayTransport(
          Uri.parse(p.relay),
          code: p.roomCode,
          deviceId: p.deviceId,
          token: savedToken,
          pairingCode: p.pairingCode,
          name: p.name,
          onPaired: (id, tok) async {
            p.deviceId = id;
            p.pairingCode = '';
            await ProfileStore.saveToken(p.id, tok);
            await ProfileStore.save(profiles);
          },
        );
        await relay.connect();
        transport = relay;
        modeLabel = '云端转发 · ${p.name}';
      }
      final client = DshClient(transport);
      // 自动重连也要鉴权（直连/云端转发都要）：launch-token 路由按「宿主本机
      // 环回」放行——直连经 adb reverse 是环回；云端转发时该请求经桥在宿主
      // 本机发起，同样环回。此前只给直连做了，relay 冷启动必 401
      // （auth/required），每次打开 app 都得手动重连——作答卡/会话全挂。
      try {
        final launch = await client.fetchLaunchToken();
        if (launch.isNotEmpty) await client.authorize(launch);
      } catch (_) {
        /* 取不到就走原 401 报错路径 */
      }
      await client.sessionList(); // 连通性自检
      if (!mounted) {
        transport.close();
        return;
      }
      await _onConnected(
        transport: transport,
        client: client,
        modeLabel: modeLabel,
      );
      debugPrint('[autoConnect] ok $modeLabel');
    } catch (e) {
      debugPrint('[autoConnect] fail: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    keepAliveNotifier.removeListener(_syncKeepAlive);
    InteractionCenter.I.pending.removeListener(_onPendingChanged);
    keepAliveStop();
    tabIndex.dispose();
    _wsMux?.close();
    _transport?.close();
    super.dispose();
  }

  Future<void> _onConnected({
    required DshTransport transport,
    required DshClient client,
    required String modeLabel,
  }) async {
    setState(() {
      _transport?.close();
      _transport = transport;
      _client = client;
      _modeLabel = modeLabel;
      _selected = null;
    });
    tabIndex.value = 0;
    _syncKeepAlive(); // 连接即按开关起保活前台服务
    await refreshSessions();
    _startWorkspaceFollow();
  }

  Future<void> refreshSessions() async {
    final client = _client;
    if (client == null) return;
    setState(() => _sessionsLoading = true);
    try {
      final v = await client.sessionList();
      final items = (v['items'] as List? ?? [])
          .whereType<Map>()
          .map((e) => SessionSummary.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      items.sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
      if (!mounted) return;
      setState(() => _sessions = items);
      // 首次拿到会话列表后：自动打开上次的会话（只尝试一次）。
      if (!_sessionRestored) {
        _sessionRestored = true;
        final last = await ConnStore.lastSessionId();
        debugPrint(
          '[restore] items=${items.length} '
          'ids=${items.map((e) => e.sessionId).take(3).toList()} '
          'last=$last selected=${_selected?.sessionId} mounted=$mounted',
        );
        if (last != null && mounted && _selected == null) {
          for (final it in items) {
            if (it.sessionId == last) {
              debugPrint('[restore] match -> open ${it.title}');
              selectSession(it);
              break;
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('刷新会话失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _sessionsLoading = false);
    }
  }

  void selectSession(SessionSummary s) {
    setState(() => _selected = s);
    tabIndex.value = 0;
    rootScaffoldKey.currentState?.closeDrawer();
    // 记住上次会话：下次启动自动打开。
    ConnStore.saveLastSessionId(s.sessionId);
  }

  // ---- 工作区分组：workspace/follow（baseline + 增量推帧，桌面侧栏同源）----

  void _startWorkspaceFollow() {
    final client = _client;
    if (client == null) return;
    _wsMux?.close();
    final mux = DshMux(client, label: 'workspace');
    _wsMux = mux;
    mux.onReconnected = _openWorkspaceFollow;
    () async {
      try {
        await mux.connect();
      } catch (e) {
        debugPrint('[workspace] mux connect fail: $e');
        // 首连失败不会武装自动重连（重连循环只在断线后由 _handleDisconnect 启动）：
        // 必须 kick 进持续重连，否则首连失败后 workspace 流永久躺平
        // （对齐 interactions/session_page 的处理；成功后 onReconnected 补开流）
        mux.kick();
        return;
      }
      _openWorkspaceFollow();
    }();
  }

  Future<void> _openWorkspaceFollow() async {
    final mux = _wsMux;
    if (mux == null) return;
    mux.open('workspace/follow', {}).listen(
      (frame) {
        final type = '${frame['type']}';
        setState(() {
          if (type == 'baseline') {
            final v = frame['value'] as Map? ?? {};
            _workspaces = (v['items'] as List? ?? [])
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            _archivedIds = _idSet(v['archivedSessionIds']);
            _pinnedIds = _idSet(v['pinnedSessionIds']);
          } else if (type == 'upsert') {
            final w = frame['workspace'];
            if (w is Map) {
              final m = Map<String, dynamic>.from(w);
              _workspaces.removeWhere(
                (e) => '${e['workspaceId']}' == '${m['workspaceId']}',
              );
              _workspaces.add(m);
            }
          } else if (type == 'order') {
            final ids = (frame['workspaceIds'] as List? ?? [])
                .map((e) => '$e')
                .toList();
            int rank(Map e) {
              final i = ids.indexOf('${e['workspaceId']}');
              return i == -1 ? 1 << 30 : i;
            }

            _workspaces.sort((a, b) => rank(a).compareTo(rank(b)));
          } else if (type == 'archived') {
            _archivedIds = _idSet(frame['archivedSessionIds']);
          } else if (type == 'pinned') {
            _pinnedIds = _idSet(frame['pinnedSessionIds']);
          } else if (type == 'remove') {
            _workspaces.removeWhere(
              (e) => '${e['workspaceId']}' == '${frame['workspaceId']}',
            );
          }
        });
      },
      onError: (e) {
        debugPrint('[workspace] follow stream error: $e');
      },
      cancelOnError: false,
    );
  }

  Set<String> _idSet(dynamic v) =>
      (v as List? ?? []).map((e) => '$e').toSet();

  /// 工作区标题：title 优先，回退路径 basename（桌面 workspaceLabel 同义）。
  String _wsLabel(Map w) {
    final t = '${w['title']}';
    if (t.isNotEmpty && t != 'null') return t;
    final p = '${w['path']}'.replaceAll('\\', '/');
    final base = p.split('/').where((x) => x.isNotEmpty).toList();
    return base.isEmpty ? '工作区' : base.last;
  }

  List<_SessionSection> _sessionSections() {
    List<SessionSummary> order(Iterable<SessionSummary> input) =>
        input.toList()
          ..sort((a, b) {
            final pa = _pinnedIds.contains(a.sessionId);
            final pb = _pinnedIds.contains(b.sessionId);
            if (pa != pb) return pa ? -1 : 1;
            return (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0);
          });

    final remaining = {
      for (final s in _sessions) s.sessionId: s,
    };
    final sections = <_SessionSection>[];
    for (final w in _workspaces) {
      final members = <SessionSummary>[];
      for (final id
          in ((w['sessionIds'] as List? ?? []).map((e) => '$e'))) {
        final s = remaining.remove(id);
        if (s != null) members.add(s);
      }
      sections.add(
        _SessionSection('${w['workspaceId']}', _wsLabel(w), order(members)),
      );
    }
    if (remaining.isNotEmpty) {
      sections.add(
        _SessionSection('__ungrouped__', '未分组', order(remaining.values)),
      );
    }
    return sections;
  }

  /// 长按会话行：置顶/归档（wire 写后 follow 推帧回刷 UI）。
  Future<void> _rowAction(SessionSummary s, String action) async {
    final client = _client;
    if (client == null) return;
    final pinned = _pinnedIds.contains(s.sessionId);
    final archived = _archivedIds.contains(s.sessionId);
    final method = switch (action) {
      'pin' => pinned ? 'workspace/unpinSession' : 'workspace/pinSession',
      'archive' =>
        archived ? 'workspace/unarchiveSession' : 'workspace/archiveSession',
      _ => null,
    };
    if (method == null) return;
    try {
      await client.rpc(method, {'request': {'sessionId': s.sessionId}});
    } catch (e) {
      debugPrint('[workspace] $method fail: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('操作失败：$e')));
    }
  }

  Future<void> createSession() async {
    final client = _client;
    if (client == null) {
      tabIndex.value = 1;
      rootScaffoldKey.currentState?.closeDrawer();
      return;
    }
    try {
      rootScaffoldKey.currentState?.closeDrawer();
      // 先选工作区（null=取消；''=用默认；否则=选定路径）
      final cwd = await WorkspacePicker.show(context, client);
      if (cwd == null) return; // 取消
      final id = await client.sessionCreate(cwd: cwd.isEmpty ? null : cwd);
      final s = SessionSummary(
        sessionId: id,
        title: '',
        running: true,
        blank: true,
      );
      selectSession(s);
      await refreshSessions();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('创建会话失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    return Scaffold(
      key: rootScaffoldKey,
      drawer: DshDrawer(
        sessions: _sessions,
        sessionsLoading: _sessionsLoading,
        modeLabel: _modeLabel,
        connected: client != null,
        selected: _selected,
        sections: _sessionSections(),
        pinnedIds: _pinnedIds,
        archivedIds: _archivedIds,
        collapsedGroups: _collapsedGroups,
        onSelect: selectSession,
        onToggleGroup: (key) => setState(() {
          if (!_collapsedGroups.remove(key)) _collapsedGroups.add(key);
        }),
        onRowMenu: (s) async {
          final archived = _archivedIds.contains(s.sessionId);
          final pinned = _pinnedIds.contains(s.sessionId);
          final action = await showModalBottomSheet<String>(
            context: context,
            builder: (sheetCtx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: Icon(
                      pinned ? Icons.push_pin_outlined : Icons.push_pin,
                    ),
                    title: Text(pinned ? '取消置顶' : '置顶'),
                    onTap: () => Navigator.pop(sheetCtx, 'pin'),
                  ),
                  ListTile(
                    leading: Icon(
                      archived ? Icons.unarchive : Icons.archive_outlined,
                    ),
                    title: Text(archived ? '取消归档' : '归档'),
                    onTap: () => Navigator.pop(sheetCtx, 'archive'),
                  ),
                ],
              ),
            ),
          );
          if (action != null) await _rowAction(s, action);
        },
        onArchivedTap: (s) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('该会话已归档（桌面端归档集）'),
              action: SnackBarAction(
                label: '恢复',
                onPressed: () => _rowAction(s, 'archive'),
              ),
            ),
          );
        },
        onRefresh: refreshSessions,
        onNewSession: createSession,
        onOpenSettings: () {
          tabIndex.value = 1;
          rootScaffoldKey.currentState?.closeDrawer();
        },
        onOpenHostStatus: () {
          rootScaffoldKey.currentState?.closeDrawer();
          final c = _client;
          if (c == null) return;
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => HostStatusPage(
              client: c,
              deviceId: _activeDeviceId.isEmpty ? 'direct' : _activeDeviceId,
            ),
          ));
        },
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: tabIndex,
        builder: (context, index, _) {
          return PopScope(
            // 返回/左滑手势：设置页（tab 1）拦截返回并切回上次 session（tab 0），
            // 会话页（tab 0）放行 pop=退出。PopScope 在 ValueListenableBuilder 内侧，
            // 随 tabIndex 变化重建，canPop 才能实时反映当前 tab。
            canPop: index == 0,
            onPopInvokedWithResult: (bool didPop, Object? result) {
              if (didPop) return; // 会话页正常退出，无需处理
              tabIndex.value = 0; // 设置页被拦截 → 回到上次 session
            },
            child: IndexedStack(
              index: index,
              children: [
                client == null || _selected == null
                    ? _EmptySessionView(
                        connected: client != null,
                        onOpenDrawer: () =>
                            rootScaffoldKey.currentState?.openDrawer(),
                        onOpenSettings: () => tabIndex.value = 1,
                      )
                    : SessionPage(
                        key: ValueKey(_selected!.sessionId),
                        client: client,
                        summary: _selected!,
                        deviceId: _activeDeviceId,
                        onOpenDrawer: () =>
                            rootScaffoldKey.currentState?.openDrawer(),
                        onSessionEnded: refreshSessions,
                      ),
                SettingsPage(
                  onConnected: _onConnected,
                  onOpenDrawer: () =>
                      rootScaffoldKey.currentState?.openDrawer(),
                  modeLabel: _modeLabel,
                  connected: client != null,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 抽屉导航外壳（参考 ZCode mobile / Cherry Studio AppDrawerNavigator 范式）：
/// 80% 宽、顶部连接状态行 + 入口行 + 「会话」列表直达 + 底部连接方式身份行。
class DshDrawer extends StatelessWidget {
  final List<SessionSummary> sessions;
  final bool sessionsLoading;
  final String modeLabel;
  final bool connected;
  final SessionSummary? selected;

  /// 工作区分组视图（桌面侧栏同源）：工作区组 + 未分组，组内置顶优先。
  final List<_SessionSection> sections;
  final Set<String> pinnedIds;
  final Set<String> archivedIds;
  final Set<String> collapsedGroups;
  final void Function(SessionSummary) onSelect;
  final void Function(String) onToggleGroup;
  final Future<void> Function(SessionSummary) onRowMenu;
  final void Function(SessionSummary) onArchivedTap;
  final VoidCallback onRefresh;
  final VoidCallback onNewSession;
  final VoidCallback onOpenHostStatus;
  final VoidCallback onOpenSettings;

  const DshDrawer({
    super.key,
    required this.sessions,
    required this.sessionsLoading,
    required this.modeLabel,
    required this.connected,
    required this.selected,
    required this.sections,
    required this.pinnedIds,
    required this.archivedIds,
    required this.collapsedGroups,
    required this.onSelect,
    required this.onToggleGroup,
    required this.onRowMenu,
    required this.onArchivedTap,
    required this.onRefresh,
    required this.onNewSession,
    required this.onOpenSettings,
    required this.onOpenHostStatus,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tk = theme.extension<SkinTokens>()!;
    final width = MediaQuery.of(context).size.width * 0.8;
    // 面板底色/渐变走皮肤令牌；渐变面板上的前景统一转白（布局不动，纯换皮）
    final background = theme.colorScheme.surface;
    final gradientPanel = tk.drawerGradient != null;
    final onPanel = gradientPanel ? Colors.white : theme.colorScheme.onSurface;
    final onPanelDim = gradientPanel
        ? Colors.white.withValues(alpha: 0.78)
        : theme.colorScheme.onSurfaceVariant;

    Widget entryRow(IconData icon, String label, VoidCallback onTap) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
              child: Row(
                children: [
                  Icon(icon, size: 22, color: onPanel),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: onPanel,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 20, color: onPanelDim),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Drawer(
      backgroundColor: gradientPanel ? Colors.transparent : background,
      width: width,
      child: Container(
        decoration: BoxDecoration(
          gradient: tk.drawerGradient,
          color: gradientPanel ? null : background,
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部：连接状态 + 刷新
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
                child: Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: connected
                            ? Acc.green(context)
                            : theme.colorScheme.error,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        connected ? 'DSH · 已连接' : '未连接',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: onPanel,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.refresh, size: 18, color: onPanelDim),
                      onPressed: connected ? onRefresh : null,
                    ),
                  ],
                ),
              ),
              entryRow(Icons.settings_outlined, '设置', onOpenSettings),
              entryRow(Icons.add_comment_outlined, '新建会话', onNewSession),
              entryRow(Icons.monitor_outlined, '宿主状态', onOpenHostStatus),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Divider(height: 1),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: Text(
                  '会话',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: onPanelDim,
                  ),
                ),
              ),
              Expanded(
                child: sessionsLoading && sessions.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    : sessions.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            connected ? '暂无会话' : '连接后显示会话列表',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      )
                    : _DrawerList(
                        sections: sections,
                        pinnedIds: pinnedIds,
                        archivedIds: archivedIds,
                        collapsedGroups: collapsedGroups,
                        selected: selected,
                        gradientPanel: gradientPanel,
                        onPanel: onPanel,
                        onPanelDim: onPanelDim,
                        onSelect: onSelect,
                        onToggleGroup: onToggleGroup,
                        onRowMenu: onRowMenu,
                        onArchivedTap: onArchivedTap,
                      ),
              ),
              // 底部：连接方式身份行
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
                child: Row(
                  children: [
                    Icon(Icons.cloud_outlined, size: 16, color: onPanelDim),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        modeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: onPanelDim,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 抽屉会话分组段（工作区组 / 未组段）。
class _SessionSection {
  final String key;
  final String label;
  final List<SessionSummary> sessions;
  const _SessionSection(this.key, this.label, this.sessions);
}

/// 分组会话列表：组头（折叠/展开 + 计数）+ 会话行（置顶图钉 / 归档置灰，
/// 长按弹置顶/归档菜单）。仅一个未分组段时退化为无组头平铺（与旧观感一致）。
class _DrawerList extends StatelessWidget {
  final List<_SessionSection> sections;
  final Set<String> pinnedIds;
  final Set<String> archivedIds;
  final Set<String> collapsedGroups;
  final SessionSummary? selected;
  final bool gradientPanel;
  final Color onPanel;
  final Color onPanelDim;
  final void Function(SessionSummary) onSelect;
  final void Function(String) onToggleGroup;
  final Future<void> Function(SessionSummary) onRowMenu;
  final void Function(SessionSummary) onArchivedTap;

  const _DrawerList({
    required this.sections,
    required this.pinnedIds,
    required this.archivedIds,
    required this.collapsedGroups,
    required this.selected,
    required this.gradientPanel,
    required this.onPanel,
    required this.onPanelDim,
    required this.onSelect,
    required this.onToggleGroup,
    required this.onRowMenu,
    required this.onArchivedTap,
  });

  Widget header(_SessionSection sec, ThemeData theme) {
    final collapsed = collapsedGroups.contains(sec.key);
    return InkWell(
      onTap: () => onToggleGroup(sec.key),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
        child: Row(
          children: [
            Icon(
              collapsed ? Icons.expand_more : Icons.expand_less,
              size: 16,
              color: onPanelDim,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                sec.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: onPanelDim,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '${sec.sessions.length}',
              style: theme.textTheme.labelSmall?.copyWith(color: onPanelDim),
            ),
          ],
        ),
      ),
    );
  }

  Widget row(BuildContext context, _SessionSection sec, SessionSummary s) {
    final theme = Theme.of(context);
    final archived = archivedIds.contains(s.sessionId);
    final pinned = pinnedIds.contains(s.sessionId);
    final isSelected = selected?.sessionId == s.sessionId;
    return Material(
      color: isSelected
          ? (gradientPanel
                ? Colors.white.withValues(alpha: 0.18)
                : theme.colorScheme.primary.withValues(alpha: 0.15))
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onLongPress: () => onRowMenu(s),
        onTap: () => archived ? onArchivedTap(s) : onSelect(s),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Icon(
                s.running
                    ? Icons.play_circle
                    : archived
                    ? Icons.inventory_2_outlined
                    : Icons.chat_bubble_outline,
                size: 18,
                color: s.running
                    ? Acc.green(context)
                    : onPanelDim.withValues(alpha: archived ? 0.5 : 1),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  s.title.isEmpty ? '(未命名会话)' : s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: onPanel.withValues(alpha: archived ? 0.45 : 1),
                  ),
                ),
              ),
              if (pinned)
                Icon(Icons.push_pin, size: 13, color: onPanelDim),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[];
    for (final sec in sections) {
      final solo = sections.length == 1 && sec.key == '__ungrouped__';
      if (!solo) {
        children.add(header(sec, theme));
        if (collapsedGroups.contains(sec.key)) continue;
      }
      for (final s in sec.sessions) {
        children.add(row(context, sec, s));
      }
    }
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 8), children: children);
  }
}

/// 主区空态：未选会话时提示从侧边栏选择或新建。
class _EmptySessionView extends StatelessWidget {
  final bool connected;
  final VoidCallback onOpenDrawer;
  final VoidCallback onOpenSettings;

  const _EmptySessionView({
    required this.connected,
    required this.onOpenDrawer,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Builder(builder: skinFlexibleSpace),
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: onOpenDrawer,
        ),
        title: const Text('DSH Mobile'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.forum_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                connected ? '从侧边栏选择一个会话' : '先在「设置 → 连接」中连接 DSH',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text('点左上角菜单打开侧边栏', style: Theme.of(context).textTheme.bodySmall),
              if (!connected) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: onOpenSettings,
                  child: const Text('去设置'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
