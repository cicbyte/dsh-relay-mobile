import 'package:flutter/material.dart';

import 'dsh/dsh_client.dart';
import 'dsh/transport.dart';
import 'pages/connect_page.dart';
import 'pages/session_page.dart';

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
    final width = MediaQuery.of(context).size.width * 0.8;
    final background = theme.brightness == Brightness.dark
        ? const Color(0xFF121213)
        : const Color(0xFFF7F7F7);

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
                Icon(icon, size: 22, color: theme.colorScheme.onSurface),
                const SizedBox(width: 12),
                Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
                Icon(Icons.chevron_right, size: 20, color: theme.colorScheme.onSurfaceVariant),
              ]),
            ),
          ),
        ),
      );
    }

    return Drawer(
      backgroundColor: background,
      width: width,
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
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.refresh, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  onPressed: connected ? onRefresh : null,
                ),
              ]),
            ),
            entryRow(Icons.settings_outlined, '连接设置', onOpenSettings),
            entryRow(Icons.add_comment_outlined, '新建会话', onNewSession),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Divider(height: 1),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Text('会话',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
                                  ? theme.colorScheme.primary.withValues(alpha: 0.15)
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
                                        style: theme.textTheme.bodyMedium,
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
                Icon(Icons.cloud_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(modeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
              ]),
            ),
          ],
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
