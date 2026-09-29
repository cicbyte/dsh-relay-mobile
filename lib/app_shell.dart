import 'package:flutter/material.dart';

import 'dsh/conn_store.dart';
import 'dsh/dsh_client.dart';
import 'dsh/profiles.dart';
import 'dsh/transport.dart';
import 'pages/connect_page.dart';
import 'pages/session_page.dart';
import 'theme.dart';

/// 应用根：持有连接状态（transport/client）与会话列表，供抽屉与主内容共享。
class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  final GlobalKey<ScaffoldState> rootScaffoldKey = GlobalKey<ScaffoldState>();
  final ValueNotifier<int> tabIndex = ValueNotifier<int>(0);

  DshTransport? _transport;
  DshClient? _client;
  String _modeLabel = '未连接';
  List<SessionSummary> _sessions = [];
  SessionSummary? _selected;
  bool _sessionsLoading = false;
  bool _sessionRestored = false;

  @override
  void initState() {
    super.initState();
    _autoConnect();
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
    final p = picked ??
        (profiles.isNotEmpty ? profiles.first : EnvProfile(id: 'default', name: '默认环境', mode: 0));
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
      await client.sessionList(); // 连通性自检
      if (!mounted) {
        transport.close();
        return;
      }
      await _onConnected(transport: transport, client: client, modeLabel: modeLabel);
      debugPrint('[autoConnect] ok $modeLabel');
    } catch (e) {
      debugPrint('[autoConnect] fail: $e');
    }
  }

  @override
  void dispose() {
    tabIndex.dispose();
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
    await refreshSessions();
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
        debugPrint('[restore] items=${items.length} '
            'ids=${items.map((e) => e.sessionId).take(3).toList()} '
            'last=$last selected=${_selected?.sessionId} mounted=$mounted');
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('刷新会话失败：$e')));
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

  Future<void> createSession() async {
    final client = _client;
    if (client == null) {
      tabIndex.value = 1;
      rootScaffoldKey.currentState?.closeDrawer();
      return;
    }
    try {
      final id = await client.sessionCreate();
      final s = SessionSummary(sessionId: id, title: '', running: true, blank: true);
      selectSession(s);
      await refreshSessions();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建会话失败：$e')));
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
        onSelect: selectSession,
        onRefresh: refreshSessions,
        onNewSession: createSession,
        onOpenSettings: () {
          tabIndex.value = 1;
          rootScaffoldKey.currentState?.closeDrawer();
        },
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: tabIndex,
        builder: (context, index, _) {
          return IndexedStack(
            index: index,
            children: [
              client == null || _selected == null
                  ? _EmptySessionView(
                      connected: client != null,
                      onOpenDrawer: () => rootScaffoldKey.currentState?.openDrawer(),
                      onOpenSettings: () => tabIndex.value = 1,
                    )
                  : SessionPage(
                      key: ValueKey(_selected!.sessionId),
                      client: client,
                      summary: _selected!,
                      onOpenDrawer: () => rootScaffoldKey.currentState?.openDrawer(),
                      onSessionEnded: refreshSessions,
                    ),
              ConnectPage(
                onConnected: _onConnected,
                onOpenDrawer: () => rootScaffoldKey.currentState?.openDrawer(),
              ),
            ],
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
  final void Function(SessionSummary) onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onNewSession;
  final VoidCallback onOpenSettings;

  const DshDrawer({
    super.key,
    required this.sessions,
    required this.sessionsLoading,
    required this.modeLabel,
    required this.connected,
    required this.selected,
    required this.onSelect,
    required this.onRefresh,
    required this.onNewSession,
    required this.onOpenSettings,
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
              child: Row(children: [
                Icon(icon, size: 22, color: onPanel),
                const SizedBox(width: 12),
                Expanded(child: Text(label, style: theme.textTheme.bodyLarge?.copyWith(color: onPanel))),
                Icon(Icons.chevron_right, size: 20, color: onPanelDim),
              ]),
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
              child: Row(children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: connected ? Colors.greenAccent : theme.colorScheme.error,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    connected ? 'DSH · 已连接' : '未连接',
                    style: theme.textTheme.titleSmall?.copyWith(color: onPanel),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.refresh, size: 18, color: onPanelDim),
                  onPressed: connected ? onRefresh : null,
                ),
              ]),
            ),
            entryRow(Icons.settings_outlined, '连接设置', onOpenSettings),
            entryRow(Icons.add_comment_outlined, '新建会话', onNewSession),
            // 皮肤切换（A 深空玻璃 / C 鲸蓝，换皮不换布局）
            ValueListenableBuilder<DshSkin>(
              valueListenable: skinNotifier,
              builder: (context, skin, _) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                child: Row(children: [
                  const SizedBox(width: 10),
                  Icon(Icons.palette_outlined, size: 22, color: onPanel),
                  const SizedBox(width: 12),
                  Expanded(child: Text('皮肤', style: theme.textTheme.bodyLarge?.copyWith(color: onPanel))),
                  for (final s in DshSkin.values)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        label: Text('${s.short} ${s.label.split('·').last.trim()}',
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight:
                                    skin == s ? FontWeight.w700 : FontWeight.w500,
                                color: skin == s
                                    ? (gradientPanel
                                        ? theme.colorScheme.primary
                                        : Colors.white)
                                    : onPanel)),
                        selected: skin == s,
                        showCheckmark: false,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                        // 高对比胶囊：选中=实底反色，未选=半实底+描边（渐变/暗面板各配）
                        selectedColor: gradientPanel
                            ? Colors.white
                            : theme.colorScheme.primary,
                        backgroundColor: gradientPanel
                            ? Colors.white.withValues(alpha: 0.22)
                            : onPanel.withValues(alpha: 0.12),
                        side: BorderSide(
                            color: onPanelDim.withValues(alpha: 0.55)),
                        visualDensity: VisualDensity.standard,
                        onSelected: (_) {
                          skinNotifier.value = s;
                          SkinStore.save(s);
                        },
                      ),
                    ),
                ]),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Divider(height: 1),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Text('会话',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: onPanelDim)),
            ),
            Expanded(
              child: sessionsLoading && sessions.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    )
                  : sessions.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(connected ? '暂无会话' : '连接后显示会话列表',
                                style: theme.textTheme.bodySmall),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          itemCount: sessions.length,
                          itemBuilder: (context, i) {
                            final s = sessions[i];
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
                                onTap: () => onSelect(s),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                  child: Row(children: [
                                    Icon(
                                      s.running ? Icons.play_circle : Icons.chat_bubble_outline,
                                      size: 18,
                                      color: s.running ? Colors.greenAccent : theme.colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        s.title.isEmpty ? '(未命名会话)' : s.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyMedium?.copyWith(color: onPanel),
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            );
                          },
                        ),
            ),
            // 底部：连接方式身份行
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Row(children: [
                Icon(Icons.cloud_outlined, size: 16, color: onPanelDim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(modeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: onPanelDim)),
                ),
              ]),
            ),
          ],
        ),
      ),
      ),
    );
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
        leading: IconButton(icon: const Icon(Icons.menu), onPressed: onOpenDrawer),
        title: const Text('DSH Mobile'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined, size: 56, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(connected ? '从侧边栏选择一个会话' : '先在「连接设置」中连接 DSH',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('点左上角菜单打开侧边栏',
                  style: Theme.of(context).textTheme.bodySmall),
              if (!connected) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: onOpenSettings, child: const Text('去连接')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
