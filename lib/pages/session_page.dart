import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../device_info.dart';
import '../dsh/dsh_client.dart';
import '../dsh/interactions.dart';
import '../theme.dart';
import '../widgets/interaction_composer.dart';
import '../widgets/download_flow.dart';
import '../widgets/markdown_text.dart';
import '../widgets/turn_rail.dart';
import 'trajectory_page.dart';

/// 会话页：session/follow（快照+事件订阅）渲染对话，session/prompt 发消息。
class SessionPage extends StatefulWidget {
  final DshClient client;
  final SessionSummary summary;
  final VoidCallback onOpenDrawer;

  /// 发消息等会话活动后回调（AppRoot 刷新侧边栏列表）。
  final VoidCallback? onSessionEnded;

  /// 当前配对设备 id（附件下载链接绑定用）。
  final String deviceId;

  const SessionPage({
    super.key,
    required this.client,
    required this.summary,
    required this.onOpenDrawer,
    this.onSessionEnded,
    this.deviceId = '',
  });

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> with WidgetsBindingObserver {
  late final DshMux _mux;
  StreamSubscription<Map<String, dynamic>>? _sub;

  /// 按 seq 升序保存全部记录；follow 事件 append，session/page 向前补页后合并去重。
  final Map<int, WireRecord> _records = {};
  int _cursor = 0;
  int? _minSeq;
  bool _hasMore = false;
  bool _loading = true;
  bool _sending = false;
  String? _error;
  final _inputCtrl = TextEditingController();
  // ---- 轮次导航（对齐桌面 TurnNavigator）----
  final _itemScrollCtrl = ItemScrollController();
  final _itemPositions = ItemPositionsListener.create();
  int _itemCount = 0;
  List<TurnRailItem> _turnItems = const [];
  final _turnStartIndex = <int, int>{};
  List<int?> _indexTurn = const [];
  int? _activeTurn;
  DateTime _lastSpy = DateTime.fromMillisecondsSinceEpoch(0);

  /// subagent 会话的 address 需要 mode（one-shot / continuable），失败时按序兜底。
  int _modeIdx = 0;
  bool _gotFrame = false;

  // 计划模式状态：只认 seq 最大的 plan/mode 事件（翻旧页不会倒灌旧状态）。
  int _planSeq = -1;
  bool _planActive = false;

  // ---- composer 配件状态（对齐桌面输入区，均按 seq 只认最新事件） ----
  /// 待发附件：{name, bytes, isImage, receiptId?, uploading?}。
  final List<Map<String, dynamic>> _draftFiles = [];
  String _permissionPreset = '';
  int _permissionSeq = -1;
  String _modelLabel = '';
  String _modelName = '';
  int _modelSeq = -1;
  String _goalObjective = '';
  int _goalSeq = -1;

  // ---- 队列 dock（session/control 流权威队列，对齐桌面 QueueDock） ----
  StreamSubscription<Map<String, dynamic>>? _controlSub;
  final Map<String, List<Map<String, dynamic>>> _controlQueues = {};
  bool _queueCollapsed = true;
  String _queueBusy = '';

  // ---- 斜杠命令面板（对齐 dsh-client-ui-commands 的 / 触发菜单） ----
  List<Map<String, dynamic>> _commands = const [];
  bool _commandsLoaded = false;

  void _absorbPlan(WireRecord rec) {
    switch (rec.type) {
      case 'plan/mode':
        if (rec.seq <= _planSeq) return;
        _planSeq = rec.seq;
        _planActive = rec.data['active'] == true;
      case 'permission/preset':
        if (rec.seq <= _permissionSeq) return;
        _permissionSeq = rec.seq;
        _permissionPreset = '${rec.data['preset'] ?? ''}';
      case 'model/selection':
        if (rec.seq <= _modelSeq) return;
        _modelSeq = rec.seq;
        _modelLabel =
            '${rec.data['model'] ?? rec.data['modelId'] ?? rec.data['name'] ?? ''}';
        _modelName = '${rec.data['model'] ?? rec.data['modelId'] ?? ''}';
      case 'goal/change':
        if (rec.seq <= _goalSeq) return;
        _goalSeq = rec.seq;
        final goal = Map<String, dynamic>.from(rec.data['goal'] as Map? ?? {});
        // 与桌面 GoalDock（dsh-client-ui-goal client.js:205）同判：
        // clear 墓碑或 phase==='complete' 都不渲染。注意 complete 写的是
        // 带 phase 的全量快照、不是 clear——漏判 phase 曾致已完成目标
        // 在桌面消失后手机仍挂着（「桌面没了手机还显示」）。
        _goalObjective =
            (rec.data['operation'] == 'clear' ||
                '${goal['phase']}' == 'complete')
            ? ''
            : '${goal['objective'] ?? ''}';
    }
  }

  /// 「深度求索中…」秒级刷新用。
  Timer? _ticker;

  /// 上一帧的运行态（检测 运行→空闲 边沿，后台时弹完成通知）。
  bool _wasRunning = false;

  /// 宽屏（横屏/平板）内容限宽居中——消息列表与输入卡同宽，
  /// 窄屏不加边距，行为与直铺一致。
  Widget _centerWidth(Widget child) => LayoutBuilder(
    builder: (context, c) {
      final extra = c.maxWidth - 640.0;
      if (extra <= 0) return child;
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: extra / 2),
        child: child,
      );
    },
  );

  /// 运行态：最后一条 turn/start 在最后一条 turn/end 之后（无轮次记录时回退 summary）。
  bool get _running {
    var lastStart = -1;
    var lastEnd = -1;
    for (final r in _records.values) {
      if (r.type == 'turn/start') lastStart = r.seq;
      if (r.type == 'turn/end') lastEnd = r.seq;
    }
    if (lastStart < 0 && lastEnd < 0) return widget.summary.running;
    return lastStart > lastEnd;
  }

  int? get _turnStartMs {
    var best = -1;
    int? ms;
    for (final r in _records.values) {
      if (r.type == 'turn/start' && r.seq > best) {
        best = r.seq;
        ms = r.time;
      }
    }
    return ms;
  }

  String get _elapsedLabel {
    final ms = _turnStartMs;
    if (ms == null) return '';
    return _fmtDuration(DateTime.now().millisecondsSinceEpoch - ms);
  }

  List<String> get _modes => widget.summary.parentSessionId == null
      ? ['one-shot']
      : ['one-shot', 'continuable'];

  Map<String, dynamic> get _address => sessionAddress(
    sessionId: widget.summary.sessionId,
    parentSessionId: widget.summary.parentSessionId,
    mode: _modes[_modeIdx.clamp(0, _modes.length - 1)],
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 回前台自动恢复（后台杀连接是常态）
    _mux = DshMux(widget.client, label: 'follow');
    InteractionCenter.I.ensureStarted(widget.client);
    _inputCtrl.addListener(_onInputChanged);
    _itemPositions.itemPositions.addListener(_onPositions);
    // 断线自动重连后自动重订阅（避免人工点重试）
    _mux.onReconnected = _openFollow;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_running) return;
      setState(() {});
      // 后台时把最新动作刷进进度通知（内容有变化才发，秒表由系统自己走）
      _syncBgProgressTick();
    });
    _start();
  }

  /// 回前台自愈：连接活着就重订阅拿最新快照（按 seq 合并不跳滚动）；
  /// 断了就立即 kick 重连（不等退避定时器），成功后 onReconnected 自动补订阅。
  ///
  /// 切后台 + agent 运行中：把常驻通知刷成「深度求索中… · 任务名」（系统秒表
  /// 实时走字，灵动岛式观感）；回前台复位为普通连接保持文案。前台不需要——
  /// 用户正看着页面，通知反而打扰。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _syncBgProgressNotif();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (mounted && !_running) _restoreKeepNotif();
      if (!mounted) return;
      if (_mux.isConnected) {
        _openFollow();
      } else {
        if (_error == null) setState(() => _error = '连接中断，自动重连中…');
        _mux.kick();
      }
    }
  }

  /// 「+」展开面板（参考 WorkBuddy 收纳式输入框）：设置类（权限/计划/模型）
  /// 与附件类（附件/共享区/提及）分组列出，选中即回。
  Future<void> _showComposerMore() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('权限'),
              trailing: Text(
                _permissionPreset.isEmpty
                    ? '默认'
                    : _permissionLabel(_permissionPreset),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickPermission();
              },
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text('计划模式'),
              trailing: Text(_planActive ? '开' : '关'),
              onTap: () {
                Navigator.of(ctx).pop();
                _togglePlan();
              },
            ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('模型'),
              trailing: Text(_modelLabel.isEmpty ? '默认' : _modelLabel),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickModel();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('附件'),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickFiles();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_shared_outlined),
              title: const Text('共享文件区'),
              onTap: () {
                Navigator.of(ctx).pop();
                _startDownload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.alternate_email),
              title: const Text('提及文件或对话'),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickReference();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 切后台时把保活通知刷成运行中进度；空闲则不动（保持「已连接」文案）。
  /// 标题不放耗时——通知右侧的系统秒表就是实时时间，两份时间会互相打架。
  void _syncBgProgressNotif() {
    if (!_running) return;
    _lastNotifActivity = '';
    _syncBgProgressTick();
  }

  /// 每秒 tick：后台时把「最新动作」刷进进度通知第二行，内容有变化才发
  void _syncBgProgressTick() {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    final label = _latestActivityLabel();
    if (label == _lastNotifActivity) return;
    _lastNotifActivity = label;
    keepAliveUpdate(
      '深度求索中…',
      label,
      sessionId: widget.summary.sessionId,
      chronometerStartMs: _turnStartMs ?? 0,
    );
  }

  String _lastNotifActivity = '';

  /// 最新动作短标签（后台进度通知第二行）：就近找最近一条
  /// tool/call（工具名+参数摘要）或 assistant 文本/思考（回复中/思考中）；
  /// 都没有时回退会话标题。
  String _latestActivityLabel() {
    final seqs = _records.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final seq in seqs.take(40)) {
      final r = _records[seq]!;
      switch (r.type) {
        case 'tool/call':
          final name = '${r.data['name'] ?? 'tool'}';
          var detail = '${r.data['arguments'] ?? ''}'.replaceAll(
            RegExp(r'\s+'),
            ' ',
          );
          if (detail.length > 36) detail = '${detail.substring(0, 36)}…';
          return detail.isEmpty ? '调用 $name' : '$name $detail';
        case 'assistant/message':
          final msg = Map<String, dynamic>.from(
            r.data['message'] as Map? ?? {},
          );
          final blocks = (msg['content'] as List? ?? const []).toList();
          for (final b in blocks.reversed) {
            if (b is Map && b['type'] == 'thinking') return '思考中…';
            if (b is Map && b['type'] == 'text') {
              final t = '${b['text'] ?? ''}'.trim().replaceAll(
                RegExp(r'\s+'),
                ' ',
              );
              if (t.isNotEmpty) {
                return t.length > 40 ? '回复中… ${t.substring(0, 40)}' : '回复中… $t';
              }
            }
          }
      }
    }
    return _displayTitle(_records.values.toList());
  }

  /// 常驻通知复位为「已连接」（回前台空闲 / 回合结束）
  void _restoreKeepNotif() {
    keepAliveUpdate('DSH 已连接', '');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _sub?.cancel();
    _controlSub?.cancel();
    _inputCtrl.removeListener(_onInputChanged);
    _itemPositions.itemPositions.removeListener(_onPositions);
    _mux.close();
    _inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!_mux.isConnected) await _mux.connect();
      _openFollow();
    } catch (e) {
      setState(() => _error = '$e');
      // 初始连接失败也进持续重连循环（成功后 onReconnected 自动补订阅），
      // 不能只报错干等——那会退回「手动下拉重试」的旧体验。
      _mux.kick();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openFollow() {
    _gotFrame = false;
    _openControl();
    _sub?.cancel();
    _sub = _mux
        .open('session/follow', {
          'request': {
            'address': _address,
            // 快照尾窗不宜过大：大 JSON 解析会阻塞主 isolate，延迟自动 Pong（服务端 2 次未应答即断线）
            'maxMessages': 50,
          },
        })
        .listen(
          _onFrame,
          onError: (Object e) {
            // subagent 场景：mode 不匹配时换下一个再试（如 one-shot → continuable）
            final msg = '$e';
            final canRetry = !_gotFrame && _modeIdx < _modes.length - 1;
            if (canRetry &&
                (msg.contains('agent-busy') ||
                    msg.contains('mode') ||
                    msg.contains('address'))) {
              setState(() => _modeIdx++);
              _openFollow();
              return;
            }
            if (mounted) {
              // 断连由 DshMux 持续自动重连兜底：提示恢复中，而非要求手动操作
              setState(
                () => _error = msg.contains('mux/disconnected')
                    ? '连接已断开，自动重连中…'
                    : msg,
              );
            }
          },
          onDone: () {
            // 自动重连进行中（DshMux 持续重试）：提示而非要求手动操作
            if (mounted && _error == null)
              setState(() => _error = '连接已断开，自动重连中…');
          },
        );
  }

  void _onFrame(Map<String, dynamic> frame) {
    _gotFrame = true;
    setState(() {
      if (_error != null) _error = null; // 流恢复即清错误横幅
      switch (frame['type']) {
        case 'snapshot':
          final cursor = (frame['cursor'] as num? ?? 0).toInt();
          _cursor = cursor;
          _hasMore = frame['hasMore'] == true;
          for (final r in (frame['records'] as List? ?? [])) {
            if (r is Map) {
              final rec = WireRecord.fromJson(Map<String, dynamic>.from(r));
              _records[rec.seq] = rec;
              _absorbPlan(rec);
            }
          }
          _updateMinSeq();
        case 'event':
          final e = frame['event'];
          if (e is Map) {
            final rec = WireRecord.fromJson(Map<String, dynamic>.from(e));
            _records[rec.seq] = rec;
            _updateMinSeq();
            _absorbPlan(rec);
            // session/title：顶栏已实时反映（_displayTitle），这里借
            // onSessionEnded 钩子刷新侧栏/列表的标题。
            if (rec.type == 'session/title') {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) widget.onSessionEnded?.call();
              });
            }
          }
        // assistant-stream 帧：v1 不做打字机效果，忽略
      }
    });
    _scrollToBottom();
    _maybeNotifyTurnEnd(frame);
  }

  /// 后台回答完成通知：运行→空闲的边沿且 App 不在前台时弹系统通知
  /// （前台 UI 本身可见，不打扰）。快照重放不触发（只认 event 帧）。
  void _maybeNotifyTurnEnd(Map<String, dynamic> frame) {
    final running = _running;
    final finished = _wasRunning && !running;
    _wasRunning = running;
    if (!finished) {
      // 运行中且在后台：秒表文案交给系统 chronometer 走字，无需反复更新
      return;
    }
    _restoreKeepNotif(); // 回合结束：常驻通知从「深度求索中…」复位
    if (frame['type'] != 'event') return;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed)
      return;
    final title = _displayTitle(_records.values.toList());
    notifyEvent('DSH 回答完成', title, sessionId: widget.summary.sessionId);
  }

  void _updateMinSeq() {
    if (_records.isEmpty) {
      _minSeq = null;
      return;
    }
    _minSeq = _records.keys.reduce((a, b) => a < b ? a : b);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_itemScrollCtrl.isAttached || _itemCount == 0) return;
      _itemScrollCtrl.scrollTo(
        index: _itemCount - 1,
        alignment: 1,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// 跳到某轮起点（轮次轨点按）。
  void _jumpToTurn(int turn) {
    final idx = _turnStartIndex[turn];
    if (idx == null || !_itemScrollCtrl.isAttached) return;
    _itemScrollCtrl.scrollTo(
      index: idx,
      alignment: 0.08,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  /// 滚动跟随：可视区最靠上的行归属轮 = 当前轮（驱动轮次轨高亮）。
  void _onPositions() {
    final now = DateTime.now();
    if (now.difference(_lastSpy).inMilliseconds < 150) return;
    _lastSpy = now;
    int? top;
    for (final p in _itemPositions.itemPositions.value) {
      if (p.itemLeadingEdge <= 0.15 && (top == null || p.index > top)) {
        top = p.index;
      }
    }
    if (top == null || top >= _indexTurn.length) return;
    final t = _indexTurn[top];
    if (t != null && t != 0 && t != _activeTurn) {
      setState(() => _activeTurn = t);
    }
  }

  /// 向前翻一页历史：throughSeq=快照 cursor，beforeSeq=当前最老 seq。
  Future<void> _loadEarlier() async {
    final before = _minSeq;
    if (before == null) return;
    try {
      final v = await widget.client.rpc('session/page', {
        'request': {
          'address': _address,
          'throughSeq': _cursor,
          'beforeSeq': before,
          'maxMessages': 50,
        },
      });
      setState(() {
        for (final r in (v['records'] as List? ?? [])) {
          if (r is Map) {
            final rec = WireRecord.fromJson(Map<String, dynamic>.from(r));
            _records.putIfAbsent(rec.seq, () => rec);
            _absorbPlan(rec);
          }
        }
        _hasMore = v['hasMore'] == true;
        _updateMinSeq();
      });
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('翻页失败：$e')));
    }
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    // 纯附件（空文本）也允许发送——对齐桌面 sink 语义。
    if ((text.isEmpty && _draftFiles.isEmpty) || _sending) return;
    // `/` 开头走命令通道（对齐 web 输入层）：commands/execute 而非
    // session/prompt。未知命令（如粘贴的 /path/... 路径）回落普通消息。
    if (text.startsWith('/')) {
      await _runCommand(text);
      return;
    }
    // 带附件发送走 content 块数组通道（对齐桌面 serializeAttachments）。
    if (_draftFiles.isNotEmpty) {
      await _sendWithFiles(text);
      return;
    }
    setState(() => _sending = true);
    try {
      final tz = await deviceTimeZoneId();
      final parent = widget.summary.parentSessionId;
      if (parent != null) {
        await widget.client.subagentPrompt(
          parentSessionId: parent,
          childSessionId: widget.summary.sessionId,
          text: text,
          clientTimeZone: tz,
        );
      } else {
        await widget.client.sessionPrompt(
          widget.summary.sessionId,
          text,
          clientTimeZone: tz,
        );
      }
      _inputCtrl.clear();
      widget.onSessionEnded?.call();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败：$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 斜杠命令：`commands/execute {agentId, line, submittedAttachments}`。
  /// 成功 toast 结果文案（command/run|done tile 随事件流落转录）；
  /// 未知命令回落普通消息；其他失败还原输入框内容。
  Future<void> _runCommand(String line) async {
    setState(() => _sending = true);
    try {
      final v = await widget.client.rpc('commands/execute', {
        'agentId': widget.summary.sessionId,
        'line': line,
        'submittedAttachments': <dynamic>[],
      });
      final result = Map<String, dynamic>.from(v['result'] as Map? ?? {});
      final kind = '${result['kind'] ?? ''}';
      final text = '${result['text'] ?? ''}';
      if (kind == 'error') {
        final unknown = RegExp(
          r'not found|unknown|未知|没有找到|未注册',
          caseSensitive: false,
        ).hasMatch(text);
        if (unknown) {
          // 不是命令（例如粘贴的 /path/...）：按普通消息发送。
          setState(() => _sending = false);
          await _sendPlain(line);
          return;
        }
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('命令失败：$text')));
        }
        return; // 保留输入框内容供修改
      }
      _inputCtrl.clear();
      widget.onSessionEnded?.call();
      if (mounted && text.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(text)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('命令失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 计划模式开关：/plan on|off 走命令通道（与 web 的计划开关同路）。
  /// 状态以 plan/mode 事件落账为准（命令结果提示"下一轮生效"语义）。
  Future<void> _togglePlan() async {
    final line = _planActive ? '/plan off' : '/plan on';
    try {
      final v = await widget.client.rpc('commands/execute', {
        'agentId': widget.summary.sessionId,
        'line': line,
        'submittedAttachments': <dynamic>[],
      });
      final result = Map<String, dynamic>.from(v['result'] as Map? ?? {});
      final text = '${result['text'] ?? ''}';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(text.isEmpty ? '$line 已执行' : text)),
        );
      }
      widget.onSessionEnded?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('命令失败：$e')));
      }
    }
  }

  // ================= composer 配件（对齐桌面输入区） =================

  /// 占位文案随状态切换（药丸内宽度有限，单行 hintMaxLines:1；
  /// / 与 @ 的可发现性由输入行为与 @ 图标承担）。
  String _placeholderText() {
    if (_planActive) return '描述你的任务以生成计划';
    return '输入消息…';
  }

  String _imageMime(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  /// 执行斜杠命令并 toast 结果（不接管输入框；计划/权限开关用）。
  Future<String> _execCommand(String line) async {
    final v = await widget.client.rpc('commands/execute', {
      'agentId': widget.summary.sessionId,
      'line': line,
      'submittedAttachments': <dynamic>[],
    });
    final result = Map<String, dynamic>.from(v['result'] as Map? ?? {});
    return '${result['text'] ?? ''}';
  }

  /// 附件条：待发文件 chips（图片/文件图标 + 删除）。
  Widget _attachmentStrip() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final f in _draftFiles)
            InputChip(
              avatar: Icon(
                f['uploading'] == true
                    ? Icons.cloud_upload_outlined
                    : f['isImage'] == true
                    ? Icons.image_outlined
                    : Icons.insert_drive_file_outlined,
                size: 18,
              ),
              label: Text(
                '${f['name']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              deleteIcon: const Icon(Icons.close, size: 16),
              onDeleted: () => setState(() => _draftFiles.remove(f)),
            ),
        ],
      ),
    );
  }

  /// 目标条（桌面 GoalBar 的移动对应）。
  Widget _goalDock() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(Icons.flag_outlined, size: 14, color: Acc.pink(context)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _goalObjective,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }

  /// 队列权威源：session/control 流（零参，流载体）——baseline 全量 +
  /// `queue` 增量帧（items: {id, placement, rpcId?, message:{id, content}}）。
  void _openControl() {
    _controlSub?.cancel();
    _controlSub = _mux
        .open('session/control', {})
        .listen(
          (frame) {
            if (!mounted) return;
            final type = '${frame['type']}';
            setState(() {
              if (type == 'baseline') {
                final queues = Map<String, dynamic>.from(
                  (frame['value'] as Map? ?? const {})['queues'] as Map? ?? {},
                );
                _controlQueues.clear();
                for (final e in queues.entries) {
                  _controlQueues[e.key] = (e.value as List? ?? [])
                      .whereType<Map>()
                      .map((m) => Map<String, dynamic>.from(m))
                      .toList();
                }
              } else if (type == 'queue') {
                _controlQueues['${frame['sessionId']}'] =
                    (frame['items'] as List? ?? [])
                        .whereType<Map>()
                        .map((m) => Map<String, dynamic>.from(m))
                        .toList();
              }
            });
          },
          onError: (Object _) {
            /* 断线随 mux 重连重开 */
          },
        );
  }

  /// 当前会话的队列行。与桌面 QueueDock 严格同源同滤：只显示
  /// placement==='queued'（steering 改道中 / context 已进上下文的项桌面
  /// 同样隐藏——那两类残留曾导致「桌面没了手机还显示」）。
  List<Map<String, dynamic>> get _queueRows =>
      (_controlQueues[widget.summary.sessionId] ?? const [])
          .where((r) => '${r['placement'] ?? 'queued'}' == 'queued')
          .toList();

  /// 队列 dock（对齐桌面 QueueDock）：空队列不渲染；单条直显；多条折叠头。
  Widget _queueDock() {
    final rows = _queueRows;
    final scheme = Theme.of(context).colorScheme;
    final showList = rows.length == 1 || !_queueCollapsed;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _queueCollapsed = !_queueCollapsed),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.queue_outlined, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    '队列 · ${rows.length}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _queueBusy.isEmpty ? _steerAll : null,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28),
                    ),
                    child: const Text('全部立即', style: TextStyle(fontSize: 12)),
                  ),
                  Icon(
                    showList ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (showList)
            for (var i = 0; i < rows.length; i++) _queueRow(i, rows[i], scheme),
        ],
      ),
    );
  }

  /// 单条队列行：序号 + 预览 + [立即][撤][改]。
  Widget _queueRow(int index, Map<String, dynamic> row, ColorScheme scheme) {
    final msg = Map<String, dynamic>.from(row['message'] as Map? ?? {});
    final content = (msg['content'] as List? ?? []).whereType<Map>().toList();
    final text = content
        .where((b) => '${b['type']}' == 'text')
        .map((b) => '${b['text'] ?? ''}')
        .join('\n')
        .trim();
    final files = content
        .where((b) => '${b['type']}' == 'file' || '${b['type']}' == 'image')
        .map((b) => '${(b['attachment'] as Map? ?? const {})['name'] ?? "附件"}')
        .toList();
    final placement = (row['placement'] ?? 'queued').toString();
    final placeLabel = switch (placement) {
      'steering' => '改道',
      'context' => '上下文',
      _ => '',
    };
    final itemId = (row['id'] ?? msg['id'] ?? '').toString();
    final busy = _queueBusy == itemId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Row(
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Text(
              '${index + 1}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (placeLabel.isNotEmpty)
                  Text(
                    placeLabel,
                    style: TextStyle(
                      fontSize: 10,
                      color: Acc.amber(context),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                Text(
                  text.isEmpty ? '（附件消息）' : text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                if (files.isNotEmpty)
                  Text(
                    '📎 ${files.join('、')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: '立即执行',
            iconSize: 18,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: busy
                ? null
                : () => _queueAction(row, {'kind': 'steer'}, fail: '立即执行失败'),
            icon: const Icon(Icons.bolt_outlined),
          ),
          IconButton(
            tooltip: '撤回',
            iconSize: 18,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: busy
                ? null
                : () => _queueAction(row, {'kind': 'remove'}, fail: '撤回失败'),
            icon: const Icon(Icons.close_outlined),
          ),
          IconButton(
            tooltip: '改写',
            iconSize: 18,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: busy ? null : () => _queueEdit(row),
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
    );
  }

  /// 队列动作：session/updateQueue {request:{sessionId,itemId,action}}。
  /// 控制流的 queue 帧会推回权威状态，本地不做乐观更新。
  Future<void> _queueAction(
    Map<String, dynamic> row,
    Map<String, dynamic> action, {
    String fail = '队列操作失败',
  }) async {
    final msg = row['message'] as Map?;
    final itemId = '${row['id'] ?? msg?['id'] ?? ''}';
    if (itemId.isEmpty) return;
    setState(() => _queueBusy = itemId);
    try {
      await widget.client.updateQueue(widget.summary.sessionId, itemId, action);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$fail：$e')));
      }
    } finally {
      if (mounted && _queueBusy == itemId) setState(() => _queueBusy = '');
    }
  }

  /// 改写队列消息（桌面行内编辑的弹窗版；弹窗自持 controller，走
  /// State.dispose 合法回收——pop 返回后立即 dispose 会在退场动画中触发
  /// framework 断言）。
  Future<void> _queueEdit(Map<String, dynamic> row) async {
    final msg = Map<String, dynamic>.from(row['message'] as Map? ?? {});
    final content = (msg['content'] as List? ?? []).whereType<Map>().toList();
    final text = content
        .where((b) => '${b['type']}' == 'text')
        .map((b) => '${b['text'] ?? ''}')
        .join('\n');
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => _QueueEditDialog(initial: text),
    );
    if (newText == null || newText.trim().isEmpty) return;
    await _queueAction(row, {
      'kind': 'edit',
      'content': [
        {'type': 'text', 'text': newText.trim()},
      ],
    }, fail: '改写失败');
  }

  /// 全部立即执行：FIFO 逐条 steer（对齐桌面 QueueDock Steer all）。
  Future<void> _steerAll() async {
    final rows = _queueRows
        .where((r) => '${r['placement'] ?? 'queued'}' == 'queued')
        .toList();
    for (final row in rows) {
      await _queueAction(row, {'kind': 'steer'}, fail: '立即执行失败');
    }
  }

  // ---------------- 斜杠命令面板（/ 触发菜单） ----------------

  /// 输入变化：/ 命令名 token 未敲完时显示面板并按需拉目录。
  void _onInputChanged() {
    if (_paletteQuery != null && !_commandsLoaded) _loadCommands();
    setState(() {});
  }

  /// 面板激活时的命令名 token（/ 之后、第一个空白之前）；非 / 开头或
  /// token 已敲完（已出现空格）返回 null → 面板隐藏。
  String? get _paletteQuery {
    final text = _inputCtrl.text;
    if (!text.startsWith('/')) return null;
    final rest = text.substring(1);
    final m = RegExp(r'\s').firstMatch(rest);
    return m == null ? rest : null;
  }

  Future<void> _loadCommands() async {
    try {
      final v = await widget.client.commandList(widget.summary.sessionId);
      if (!mounted) return;
      setState(() {
        _commands = v
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        _commandsLoaded = true;
      });
    } catch (_) {
      // 面板静默不可用（commands/list 不可达时发送路径原有兜底不变）。
    }
  }

  /// 桌面同款匹配：不区分大小写的子序列模糊匹配，前缀排名最高。
  List<Map<String, dynamic>> _paletteMatches(String q) {
    final lq = q.toLowerCase();
    final out = _commands.where((c) {
      final name = '${c['name'] ?? ''}'.toLowerCase();
      var i = 0;
      for (final ch in lq.split('')) {
        i = name.indexOf(ch, i);
        if (i < 0) return false;
        i++;
      }
      return true;
    }).toList();
    out.sort((a, b) {
      final an = '${a['name'] ?? ''}'.toLowerCase();
      final bn = '${b['name'] ?? ''}'.toLowerCase();
      final ap = an.startsWith(lq) ? 0 : 1;
      final bp = bn.startsWith(lq) ? 0 : 1;
      if (ap != bp) return ap - bp;
      return an.length.compareTo(bn.length);
    });
    return out;
  }

  Widget _commandPalette() {
    final q = _paletteQuery;
    if (q == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final matches = _paletteMatches(q);
    if (matches.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      constraints: const BoxConstraints(maxHeight: 230),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
        color: scheme.surfaceContainerHighest,
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          for (final c in matches.take(8))
            ListTile(
              dense: true,
              leading: Icon(Icons.terminal, size: 18, color: scheme.primary),
              title: Text(
                '/${c['name'] ?? ''}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                '${c['description'] ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => _pickCommand(c),
            ),
        ],
      ),
    );
  }

  /// 选中命令：带 input 描述符的补尾随空格进入参数输入，裸命令原样待发。
  void _pickCommand(Map<String, dynamic> c) {
    final name = '${c['name'] ?? ''}';
    final hasInput = c['input'] is Map;
    _inputCtrl.text = hasInput ? '/$name ' : '/$name';
    _inputCtrl.selection = TextSelection.collapsed(
      offset: _inputCtrl.text.length,
    );
    setState(() {});
  }

  /// @ 提及（对齐桌面 input overlay：文件在前、会话在后；选中插入纯文本
  /// mention——@path / @"带 空格"/ @dir/ / @[label](dsh-session:…)）。
  Future<void> _pickReference() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ReferenceSheet(
        client: widget.client,
        sessionId: widget.summary.sessionId,
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final ctrl = _inputCtrl;
    final sel = ctrl.selection;
    final text = ctrl.text;
    final insertAt = (sel.isValid ? sel.baseOffset : text.length).clamp(
      0,
      text.length,
    );
    final head = text.substring(0, insertAt);
    final tail = text.substring(insertAt);
    final spacer = head.isEmpty || head.endsWith(' ') || head.endsWith('\n')
        ? ''
        : ' ';
    ctrl.text = '$head$spacer$picked $tail';
    ctrl.selection = TextSelection.collapsed(
      offset: head.length + spacer.length + picked.length + 1,
    );
    setState(() {});
  }

  /// 权限预设显示名（图标 tooltip 与菜单共用）。
  String _permissionLabel(String preset) => switch (preset) {
    'read-only' => '仅可查看',
    'workspace-write' => '工作区内修改',
    'danger-full-access' => '完全权限',
    '' => '权限',
    _ => preset,
  };

  /// 输入卡内的图标+文字小药丸（参考 DeepSeek「深度思考/智能搜索」样式：
  /// 默认描边灰、激活主题色底；长标签（模型名）截断）。
  Widget _composerPill({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = active ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: active ? scheme.primaryContainer : null,
          border: Border.all(
            color: active ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: fg),
            ),
          ],
        ),
      ),
    );
  }

  /// 输入卡右端的紧凑圆钮（自绘 InkWell：IconButton 的 constraints 会被
  /// M3 样式撑回 40dp，实测挤爆底排——这里尺寸铁定）。
  Widget _composerIcon({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
    Color? tint,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 30,
          height: 38,
          child: Icon(icon, size: 19, color: tint),
        ),
      ),
    );
  }

  Future<void> _startDownload() async {
    if (widget.deviceId.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未配对设备，无法生成绑定下载链接')));
      return;
    }
    // 工作区池跟随会话 cwd；无 cwd 的会话（如部分子代理）只有全局池
    await DownloadFlow.start(
      context,
      widget.client,
      widget.deviceId,
      workspaceRoot: widget.summary.cwd,
    );
  }

  /// 选附件：图片留 base64 直传；其他文件即刻上传拿 receiptId。
  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    for (final f in result.files) {
      final bytes = f.bytes;
      if (bytes == null) continue;
      final name = f.name;
      final lower = name.toLowerCase();
      final isImage =
          lower.endsWith('.png') ||
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.gif');
      if (isImage) {
        setState(
          () =>
              _draftFiles.add({'name': name, 'bytes': bytes, 'isImage': true}),
        );
      } else {
        setState(
          () => _draftFiles.add({
            'name': name,
            'bytes': bytes,
            'isImage': false,
            'uploading': true,
          }),
        );
        try {
          final v = await widget.client.uploadFile(
            widget.summary.sessionId,
            name,
            bytes,
          );
          if (!mounted) return;
          setState(() {
            for (final e in _draftFiles) {
              if (identical(e['bytes'], bytes)) {
                e['receiptId'] = v['receiptId'];
                e['uploading'] = false;
              }
            }
          });
        } catch (e) {
          if (!mounted) return;
          setState(
            () => _draftFiles.removeWhere((e) => identical(e['bytes'], bytes)),
          );
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('上传失败：$name')));
        }
      }
    }
  }

  /// 权限预设选择（完全权限沿用桌面确认文案）。
  Future<void> _pickPermission() async {
    const options = [
      ('read-only', '仅可查看', Icons.visibility_outlined),
      ('workspace-write', '工作区内修改', Icons.edit_outlined),
      ('danger-full-access', '完全权限', Icons.gpp_maybe_outlined),
    ];
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                '权限预设',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final (id, label, icon) in options)
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                trailing: _permissionPreset == id
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () => Navigator.of(ctx).pop(id),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == 'danger-full-access') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认启用完全权限？'),
          content: const Text(
            '启用完全权限后，智能体将减少确认步骤，并且可以直接执行更多操作，包括敏感操作、文件修改或外部命令。仅建议在你信任当前任务时使用。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('启用完全权限'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      final text = await _execCommand('/permission $picked');
      if (mounted && text.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(text)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('命令失败：$e')));
      }
    }
  }

  /// 模型选择（session/modelCatalog → session/selectModel）。
  Future<void> _pickModel() async {
    try {
      final v = await widget.client.modelCatalog();
      final groups = (v['groups'] as List? ?? []).whereType<Map>().toList();
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text(
                  '选择模型',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              for (final g in groups) ...[
                ListTile(
                  dense: true,
                  title: Text(
                    '${g['name'] ?? g['id'] ?? ''}',
                    style: TextStyle(
                      color: Theme.of(ctx).colorScheme.primary,
                      fontSize: 13,
                    ),
                  ),
                ),
                for (final m in (g['models'] as List? ?? []).whereType<Map>())
                  ListTile(
                    leading: Icon(
                      _modelName == '${m['id']}'
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                    ),
                    title: Text('${m['name'] ?? m['id'] ?? ''}'),
                    subtitle: m['description'] == null
                        ? null
                        : Text(
                            '${m['description']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _setModel('${g['id'] ?? ''}', '${m['id'] ?? ''}');
                    },
                  ),
              ],
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('模型目录加载失败：$e')));
      }
    }
  }

  Future<void> _setModel(String provider, String model) async {
    try {
      await widget.client.selectModel(
        widget.summary.sessionId,
        provider,
        model,
      );
      if (!mounted) return;
      setState(() {
        _modelName = model;
        _modelLabel = model;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已切换模型 · $model')));
      widget.onSessionEnded?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('切换模型失败：$e')));
      }
    }
  }

  /// 带附件发送：content = [text?] + [image|file] 块数组。
  Future<void> _sendWithFiles(String text) async {
    if (widget.summary.parentSessionId != null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('子agent 暂不支持附件发送')));
      }
      return;
    }
    if (_draftFiles.any((f) => f['uploading'] == true)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('附件上传中，请稍候发送')));
      }
      return;
    }
    setState(() => _sending = true);
    try {
      final tz = await deviceTimeZoneId();
      final content = <Map<String, dynamic>>[
        if (text.isNotEmpty) {'type': 'text', 'text': text},
        for (final f in _draftFiles)
          if (f['isImage'] == true)
            {
              'type': 'image',
              'mediaType': _imageMime('${f['name']}'),
              'data': base64Encode(f['bytes'] as List<int>),
              'name': f['name'],
            }
          else
            {'type': 'file', 'receiptId': f['receiptId'], 'name': f['name']},
      ];
      await widget.client.sessionPromptBlocks(
        widget.summary.sessionId,
        content,
        clientTimeZone: tz,
      );
      if (!mounted) return;
      setState(() => _draftFiles.clear());
      _inputCtrl.clear();
      widget.onSessionEnded?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 普通消息发送（命令回落路径复用）。
  Future<void> _sendPlain(String text) async {
    final tz = await deviceTimeZoneId();
    final parent = widget.summary.parentSessionId;
    if (parent != null) {
      await widget.client.subagentPrompt(
        parentSessionId: parent,
        childSessionId: widget.summary.sessionId,
        text: text,
        clientTimeZone: tz,
      );
    } else {
      await widget.client.sessionPrompt(
        widget.summary.sessionId,
        text,
        clientTimeZone: tz,
      );
    }
    _inputCtrl.clear();
    widget.onSessionEnded?.call();
  }

  Future<void> _cancel() async {
    try {
      final parent = widget.summary.parentSessionId;
      if (parent != null) {
        await widget.client.subagentInterrupt(
          parentSessionId: parent,
          childSessionId: widget.summary.sessionId,
        );
      } else {
        await widget.client.sessionCancel(widget.summary.sessionId);
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('取消失败：$e')));
    }
  }

  /// 子agent 目录（subagents/list）→ 底部面板 → 点击进入子会话。
  Future<void> _showSubagents() async {
    final parent = widget.summary.sessionId;
    Map<String, dynamic> catalog;
    try {
      catalog = await widget.client.subagentList(parent);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('子agent 列表加载失败：$e')));
      }
      return;
    }
    final entries = (catalog['entries'] as List? ?? [])
        .whereType<Map>()
        .toList();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        final scheme = Theme.of(sheetCtx).colorScheme;
        return SafeArea(
          child: entries.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('该会话没有子agent'),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final e = Map<String, dynamic>.from(entries[i]);
                    final isChild = e['kind'] == 'child';
                    final id = '${e['id'] ?? ''}';
                    final label = '${e['label'] ?? ''}';
                    final mode = '${e['mode'] ?? ''}';
                    final running = e['activity'] == 'running';
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        isChild
                            ? Icons.account_tree_outlined
                            : Icons.warning_amber_outlined,
                        size: 18,
                        color: isChild
                            ? (running
                                  ? Acc.green(context)
                                  : scheme.onSurfaceVariant)
                            : scheme.error,
                      ),
                      title: Text(
                        isChild ? (label.isEmpty ? id : label) : 'diagnostic',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        isChild
                            ? '$mode · ${running ? '运行中' : '空闲'}'
                                  '${e['hasChildren'] == true ? ' · 含子级' : ''}'
                            : '${e['reason'] ?? ''} · $id',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(sheetCtx).textTheme.labelSmall,
                      ),
                      onTap: isChild
                          ? () {
                              Navigator.of(sheetCtx).pop();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => SessionPage(
                                    client: widget.client,
                                    summary: SessionSummary(
                                      sessionId: id,
                                      title: label.isEmpty ? id : label,
                                      running: running,
                                      blank: false,
                                      parentSessionId: parent,
                                    ),
                                    onOpenDrawer: () {},
                                    onSessionEnded: widget.onSessionEnded,
                                  ),
                                ),
                              );
                            }
                          : null,
                    );
                  },
                ),
        );
      },
    );
  }

  // ---------- 渲染 ----------

  List<WireRecord> get _sorted =>
      (_records.values.toList()..sort((a, b) => a.seq.compareTo(b.seq)));

  String _contentText(dynamic content) {
    if (content is! List) return '';
    final parts = <String>[];
    for (final b in content) {
      if (b is Map && b['type'] == 'text' && b['text'] is String)
        parts.add(b['text'] as String);
    }
    return parts.join('\n');
  }

  /// content blocks → widgets：text=Markdown，image=图片，file=占位。
  List<Widget> _blockWidgets(dynamic content) {
    final out = <Widget>[];
    if (content is! List) return out;
    for (final b in content) {
      if (b is! Map) continue;
      switch (b['type']) {
        case 'text':
          final t = b['text'];
          if (t is String && t.trim().isNotEmpty) out.add(MarkdownText(t));
        case 'image':
          out.add(_imageBlock(b));
        case 'file':
          out.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.attach_file, size: 15),
                  Flexible(
                    child: Text(
                      '${b['name'] ?? 'file'}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        default:
          break;
      }
    }
    return out;
  }

  Widget _imageBlock(Map b) {
    final data = b['data'];
    if (data is String && data.isNotEmpty) {
      try {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            base64Decode(data),
            width: 240,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Text('[图片无法解码]'),
          ),
        );
      } catch (_) {
        /* fallthrough */
      }
    }
    return const Text('[图片]');
  }

  /// 平铺消息：小图标 + 标签 + 时间/用量/复制 + 正文，无气泡背景。
  Widget _messageBubble({
    required String label,
    required List<Widget> body,
    int? time,
    String? usage,
    String? copyText,
  }) {
    final theme = Theme.of(context);
    final mine = label == '你';
    final meta = [
      if (time != null) _fmtClock(time),
      if (usage != null) usage,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                mine ? Icons.person_outline : Icons.auto_awesome,
                size: 13,
                color: mine
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Text(label, style: theme.textTheme.labelSmall),
              const Spacer(),
              if (meta.isNotEmpty) ...[
                Text(
                  meta,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.7,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (copyText != null && copyText.trim().isNotEmpty)
                InkWell(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: copyText));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                  child: Icon(
                    Icons.copy,
                    size: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          if (body.isEmpty)
            const Text('(空)')
          else
            for (var i = 0; i < body.length; i++) ...[
              if (i > 0) const SizedBox(height: 5),
              body[i],
            ],
        ],
      ),
    );
  }

  /// tool/result 的配对键：优先 message.source.callId（实测稳定存在），
  /// 次之 tool-result 块 callId、事件 callId，兜底 seq。
  String _resultKey(WireRecord r) {
    final msg = Map<String, dynamic>.from(r.data['message'] as Map? ?? {});
    final src = Map<String, dynamic>.from(msg['source'] as Map? ?? {});
    if (src['callId'] != null) return '${src['callId']}';
    for (final b in msg['content'] as List? ?? []) {
      if (b is Map && b['type'] == 'tool-result' && b['callId'] != null)
        return '${b['callId']}';
    }
    return '${r.data['callId'] ?? r.seq}';
  }

  /// records → widgets 两遍聚合：
  ///  ① tool/call（事件或 assistant 的 tool-call 块）与 tool/result 按 callId 配对成一张卡；
  ///  ② ignorable 协议噪声过滤、reasoning 折叠、系统事件胶囊化。
  List<Widget> _buildItems(List<WireRecord> records) {
    final tools = <String, _ToolEntry>{};
    final order = <_ToolEntry>[]; // 调用顺序（FIFO 兜底配对用）

    _ToolEntry newEntry(String key) {
      final e = _ToolEntry();
      tools[key] = e;
      order.add(e);
      return e;
    }

    // Pass 1: 收集工具调用与结果。
    // 实况（dump 验证）：tool/call 事件带 callId，tool/result 与 assistant 的 tool-call
    // 块都不带；assistant 块与紧随其后的 tool/call 事件是同一调用的双重表示——
    // 只认 tool/call 事件建条目，result 靠 FIFO 挂到最近未完成的调用。
    for (final r in records) {
      switch (r.type) {
        case 'tool/call':
          final e =
              tools['${r.data['callId'] ?? r.seq}'] ??
              newEntry('${r.data['callId'] ?? r.seq}');
          e.setCall(
            '${r.data['name'] ?? 'tool'}',
            '${r.data['arguments'] ?? ''}',
          );
          e.callMs ??= r.time;
        case 'tool/result':
          final msg = Map<String, dynamic>.from(
            r.data['message'] as Map? ?? {},
          );
          var body = '';
          var isError = r.data['error'] != null;
          for (final b in msg['content'] as List? ?? []) {
            if (b is Map && b['type'] == 'tool-result') {
              if (b['isError'] == true) isError = true;
              body = _contentText(b['content']);
            }
          }
          // 配对：先按 callId 精确，缺配时 FIFO 挂到最近一个还没有结果的调用
          var e = tools[_resultKey(r)];
          if (e == null || e.hasResult) {
            for (var i = order.length - 1; i >= 0; i--) {
              if (!order[i].hasResult) {
                e = order[i];
                break;
              }
            }
          }
          e ??= newEntry(_resultKey(r))..setCall('工具结果', '');
          tools[_resultKey(r)] = e; // 别名：保证 pass2 按 result 键能找到配对条目
          e
            ..resultText = body
            ..isError = isError
            ..hasResult = true
            ..resultMs ??= r.time;
        default:
          break;
      }
    }

    // Pass 2: 生成 widgets（工具卡以条目级 emitted 去重，配对结果不再出独立卡）
    final out = <Widget>[];

    // ---- 轮次导航推导（对齐桌面 TurnNavigationItem）----
    // 人工提问起轮（无轮次事件的老会话同样成立）；data['turn']/turn/start 只作编号与分界装饰。
    var curTurn = 0;
    var autoTurn = 0;
    final prompts = <int, String>{};
    final responses = <int, String>{};
    final turnStartIdx = <int, int>{};
    final idxTurn = <int>[];
    for (final r in records) {
      if (r.ignorable) continue;
      final markLen = out.length;
      // 归轮：事件显式 data['turn'] 透传（轨迹页同款：缺失沿用上一个）；
      // 无显式轮号时人工提问起轮（老会话兜底）。
      final explicitTurn = int.tryParse('${r.data['turn'] ?? ''}');
      var isHuman = false;
      if (r.type == 'user/message') {
        final src = Map<String, dynamic>.from(r.data['source'] as Map? ?? {});
        isHuman = src['kind'] == null || src['kind'] == 'user';
      }
      if (explicitTurn != null) {
        curTurn = explicitTurn;
      } else if (isHuman) {
        autoTurn += 1;
        // 轮号对齐：turn/start 已预置的空轮（有分界未有提示词）由紧随的提问继承
        final reuse =
            curTurn != 0 &&
            (prompts[curTurn] ?? '').isEmpty &&
            turnStartIdx.containsKey(curTurn);
        curTurn = reuse ? curTurn : autoTurn;
      }
      switch (r.type) {
        case 'user/message':
          // source.kind 区分人工提问与合成注入（文件变动通知、skill、cron 等）：
          // 注入不冒充「你」，以灰行呈现。
          final src = Map<String, dynamic>.from(r.data['source'] as Map? ?? {});
          if (src['kind'] != null && src['kind'] != 'user') {
            out.add(_injectionTile(r, src));
          } else {
            out.add(
              _messageBubble(
                label: '你',
                body: _blockWidgets(r.data['content']),
                time: r.time,
                copyText: _contentText(r.data['content']),
              ),
            );
          }
        case 'assistant/message':
          final msg = Map<String, dynamic>.from(
            r.data['message'] as Map? ?? {},
          );
          final body = <Widget>[];
          final plain = <String>[];
          for (final b in msg['content'] as List? ?? []) {
            if (b is! Map) continue;
            switch (b['type']) {
              case 'text':
                final t = b['text'];
                if (t is String && t.trim().isNotEmpty) {
                  body.add(MarkdownText(t));
                  plain.add(t);
                }
              case 'reasoning':
                final t = '${b['text'] ?? ''}';
                if (t.trim().isNotEmpty) body.add(_ReasoningFold(text: t));
              case 'image':
                body.add(_imageBlock(b));
              case 'tool-call':
                break; // 与 tool/call 事件双重表示，卡片由事件渲染（避免重复/孤儿卡）
              default:
                break;
            }
          }
          if (body.isNotEmpty) {
            final u = Map<String, dynamic>.from(r.data['usage'] as Map? ?? {});
            out.add(
              _messageBubble(
                label: '助手${r.data['interrupted'] == true ? '（已中断）' : ''}',
                body: body,
                time: r.time,
                usage: u.isEmpty
                    ? null
                    : '↑${_fmtTokens((u['inputTokens'] as num? ?? 0).toInt())}'
                          ' ↓${_fmtTokens((u['outputTokens'] as num? ?? 0).toInt())}',
                copyText: plain.join('\n'),
              ),
            );
          }
        case 'tool/call':
          final e =
              tools['${r.data['callId'] ?? r.seq}'] ??
              (_ToolEntry()..setCall(
                '${r.data['name'] ?? 'tool'}',
                '${r.data['arguments'] ?? ''}',
              ));
          if (!e.emitted) {
            e.emitted = true;
            out.add(_ToolCallCard(entry: e));
          }
        case 'tool/result':
          final e =
              tools[_resultKey(r)] ??
              (_ToolEntry()
                ..setCall('工具结果', '')
                ..resultText = ''
                ..hasResult = true);
          if (!e.emitted) {
            e.emitted = true;
            out.add(_ToolCallCard(entry: e));
          }
        default:
          out.add(_systemTile(r));
      }
      // 行→轮归属 + 轮锚点/预览摘录
      for (var k = markLen; k < out.length; k++) {
        idxTurn.add(curTurn);
      }
      if (curTurn != 0) {
        // 该轮首个可见行即锚点；turn/start 分界行若在则首选
        if (out.length > markLen && !turnStartIdx.containsKey(curTurn)) {
          turnStartIdx[curTurn] = markLen;
        }
        if (r.type == 'turn/start' && out.length > markLen) {
          turnStartIdx[curTurn] = markLen;
        }
        if (isHuman) {
          final t = _contentText(r.data['content']).trim();
          if (t.isNotEmpty && (prompts[curTurn] ?? '').isEmpty) {
            prompts[curTurn] = t.split('\n').first;
          }
        } else if (r.type == 'assistant/message') {
          final msg = Map<String, dynamic>.from(
            r.data['message'] as Map? ?? {},
          );
          for (final b in msg['content'] as List? ?? const []) {
            if (b is Map && b['type'] == 'text') {
              final t = '${b['text'] ?? ''}'.trim();
              if (t.isNotEmpty && (responses[curTurn] ?? '').isEmpty) {
                responses[curTurn] = t.split('\n').first;
                break;
              }
            }
          }
        }
      }
    }
    // 轮次导航项（升序；锚点行索引 = items 索引）
    final turns = turnStartIdx.keys.toList()..sort();
    _turnItems = [
      for (final t in turns)
        TurnRailItem(
          turn: t,
          prompt: prompts[t] ?? '',
          response: responses[t] ?? '',
        ),
    ];
    _turnStartIndex
      ..clear()
      ..addAll(turnStartIdx);
    _indexTurn = List<int?>.from(idxTurn);
    _itemCount = out.length;
    return out;
  }

  /// 展示标题：最近一条 session/title 事件优先（自动改题实时反映），其次 summary。
  String _displayTitle(List<WireRecord> records) {
    var title = widget.summary.title;
    for (final r in records) {
      if (r.type != 'session/title') continue;
      final t = '${r.data['title'] ?? ''}'.trim();
      if (t.isNotEmpty) title = t;
    }
    return title.isEmpty ? widget.summary.sessionId : title;
  }

  /// 单行事件胶囊：图标 + 主文 + 可选副文，用于生命周期/状态类事件。
  Widget _chipTile({
    required IconData icon,
    required Color color,
    required String text,
    String? sub,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
                if (sub != null && sub.trim().isNotEmpty)
                  Text(
                    sub.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// todo/write：任务清单整表快照（计划/执行进度一目了然）。
  Widget _todoTile(WireRecord r) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final todos = (r.data['todos'] as List? ?? []).whereType<Map>().toList();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 14),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.checklist, size: 13, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  '任务清单',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final t in todos)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      switch ('${t['status'] ?? ''}') {
                        'completed' => Icons.check_circle_outline,
                        'in_progress' => Icons.timelapse,
                        _ => Icons.circle_outlined,
                      },
                      size: 13,
                      color: switch ('${t['status'] ?? ''}') {
                        'completed' => Acc.green(context),
                        'in_progress' => Acc.amber(context),
                        _ => scheme.onSurfaceVariant,
                      },
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${t['content'] ?? ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          decoration: '${t['status'] ?? ''}' == 'completed'
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 合成注入（source.kind != user）：文件变动通知、skill、cron、goal 续轮等。
  Widget _injectionTile(WireRecord r, Map<String, dynamic> source) {
    final kind = '${source['kind'] ?? 'plugin'}';
    final summary = '${source['summary'] ?? ''}'.trim();
    final text = summary.isNotEmpty
        ? summary
        : _contentText(r.data['content']).trim().split('\n').first;
    return _chipTile(
      icon: Icons.input,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      text: '注入 · $kind',
      sub: text,
    );
  }

  Widget _systemTile(WireRecord r) {
    final scheme = Theme.of(context).colorScheme;
    switch (r.type) {
      case 'turn/start':
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
          child: Text(
            '— 第 ${r.data['turn'] ?? '?'} 轮 · ${_fmtClock(r.time)} —',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        );
      case 'system/message':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 16),
          child: Text(
            _contentText(r.data['content'] ?? r.data['message']),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      // ---- 计划 / 任务 ----
      case 'todo/write':
        return _todoTile(r);
      case 'plan/mode':
        final active = r.data['active'] == true;
        return _chipTile(
          icon: Icons.map_outlined,
          color: Acc.lightBlue(context),
          text: active ? '计划模式 · 开启' : '计划模式 · 关闭',
        );
      // ---- 询问 / 授权 ----
      case 'approval/asked':
        final tool = '${r.data['toolName'] ?? '工具'}';
        final reason = '${r.data['reason'] ?? ''}';
        return _chipTile(
          icon: Icons.lock_outline,
          color: Acc.orange(context),
          text: '授权询问 · $tool',
          sub: reason.isEmpty ? '等待授权' : reason,
        );
      case 'approval/decided':
        final outcome = '${r.data['outcome'] ?? ''}';
        final label = switch (outcome) {
          'allowed-once' => '允许一次',
          'rejected' => '拒绝',
          'cancelled' => '取消',
          'unavailable' => '不可用',
          _ => outcome,
        };
        final ok = outcome == 'allowed-once';
        return _chipTile(
          icon: ok ? Icons.lock_open_outlined : Icons.block_outlined,
          color: ok ? Acc.green(context) : scheme.error,
          text: '授权结果 · $label',
        );
      // ---- 子agent ----
      case 'subagent/descriptor':
        final mode = '${r.data['mode'] ?? ''}';
        return _chipTile(
          icon: Icons.account_tree_outlined,
          color: Acc.teal(context),
          text: '子agent · ${mode == 'one-shot' ? '一次性' : '可续聊'}',
          sub: '${r.data['provider'] ?? ''}',
        );
      // ---- 后台任务（workflow 运行记录） ----
      case 'tool-workflow/run-start':
        return _chipTile(
          icon: Icons.run_circle_outlined,
          color: Acc.cyan(context),
          text: '后台任务 · ${r.data['name'] ?? ''}',
          sub: '${r.data['runId'] ?? ''}',
        );
      case 'tool-workflow/agent-start':
        return _chipTile(
          icon: Icons.person_add_alt_outlined,
          color: Acc.cyan(context),
          text: '后台成员 #${r.data['seq'] ?? '?'} · ${r.data['label'] ?? ''}',
          sub: '${r.data['phase'] ?? ''}',
        );
      case 'tool-workflow/agent-end':
        return _chipTile(
          icon: Icons.done_all,
          color: Acc.cyan(context),
          text: '后台成员完成 #${r.data['seq'] ?? '?'} · ${r.data['outcome'] ?? ''}',
        );
      case 'tool-workflow/run-end':
        return _chipTile(
          icon: Icons.stop_circle_outlined,
          color: Acc.cyan(context),
          text: '后台任务结束 · ${r.data['stopReason'] ?? ''}',
        );
      // ---- 命令 ----
      case 'command/run':
        final args = '${r.data['args'] ?? ''}';
        return _chipTile(
          icon: Icons.terminal,
          color: Acc.amber(context),
          text: '命令 · /${r.data['name'] ?? ''}${args.isEmpty ? '' : ' $args'}',
        );
      case 'command/done':
        if (r.data['kind'] != 'error') return const SizedBox.shrink();
        return _chipTile(
          icon: Icons.error_outline,
          color: scheme.error,
          text: '命令失败 · ${r.data['text'] ?? ''}',
        );
      // ---- 上下文压缩 ----
      case 'compaction/start':
        return _chipTile(
          icon: Icons.compress,
          color: Acc.purple(context),
          text: '上下文压缩 · 开始',
        );
      case 'compaction/summary':
        final n = (r.data['shadowedTokenCount'] as num? ?? 0).toInt();
        return _chipTile(
          icon: Icons.compress,
          color: Acc.purple(context),
          text: '上下文压缩 · 完成',
          sub: n > 0 ? '压缩 ${_fmtTokens(n)} tokens' : null,
        );
      case 'compaction/end':
        if (r.data['error'] == null) return const SizedBox.shrink();
        return _chipTile(
          icon: Icons.error_outline,
          color: scheme.error,
          text: '上下文压缩 · 失败',
        );
      // ---- 目标 ----
      case 'goal/change':
        final goal = Map<String, dynamic>.from(r.data['goal'] as Map? ?? {});
        final objective = '${goal['objective'] ?? goal['goalId'] ?? ''}';
        final op = '${r.data['operation'] ?? ''}';
        return _chipTile(
          icon: Icons.flag_outlined,
          color: Acc.pink(context),
          text:
              '目标 · ${op == 'clear'
                  ? '已清除'
                  : objective.isEmpty
                  ? op
                  : objective}',
        );
      // ---- 交付物 ----
      case 'deliverables/presented':
        final files = (r.data['files'] as List? ?? [])
            .whereType<Map>()
            .toList();
        final paths = files
            .map((f) => '${f['path'] ?? ''}')
            .where((s) => s.isNotEmpty)
            .join('、');
        return _chipTile(
          icon: Icons.inventory_2_outlined,
          color: Acc.green(context),
          text: '交付物 · ${files.length} 个文件',
          sub: paths,
        );
      // ---- 状态小事件 ----
      case 'model/selection':
        return _chipTile(
          icon: Icons.tune,
          color: scheme.onSurfaceVariant,
          text: '模型 · ${r.data['model'] ?? r.data['modelId'] ?? ''}',
        );
      case 'agent-preset/selected':
        return _chipTile(
          icon: Icons.smart_toy_outlined,
          color: scheme.onSurfaceVariant,
          text: '预设 · ${r.data['agentPreset'] ?? ''}',
        );
      case 'sandbox/mode':
        return _chipTile(
          icon: Icons.security_outlined,
          color: scheme.onSurfaceVariant,
          text: '沙箱 · ${r.data['mode'] ?? ''}',
        );
      // ---- 权限 / 审批策略（与 sandbox/mode 同族状态条，web 端同组渲染） ----
      case 'permission/preset':
        return _chipTile(
          icon: Icons.admin_panel_settings_outlined,
          color: scheme.onSurfaceVariant,
          text: '权限预设 · ${r.data['preset'] ?? ''}',
        );
      case 'approval/policy':
        return _chipTile(
          icon: Icons.verified_user_outlined,
          color: scheme.onSurfaceVariant,
          text: '审批策略 · ${r.data['policy'] ?? ''}',
          sub: '${r.data['source'] ?? ''}' == 'delegation' ? '来源：委派' : null,
        );
      // ---- 模型重试（透明化卡顿/失败恢复） ----
      case 'llm/retry':
        final retryNo = '${r.data['retry'] ?? '?'}';
        final maxNo = '${r.data['maxRetries'] ?? ''}';
        final delayMs = (r.data['delayMs'] as num? ?? 0).toInt();
        final failure = r.data['failure'];
        final failText = failure is Map
            ? '${failure['message'] ?? failure['name'] ?? failure['code'] ?? ''}'
            : '$failure';
        return _chipTile(
          icon: Icons.replay_outlined,
          color: Acc.amber(context),
          text:
              '模型重试 · 第 $retryNo${maxNo.isEmpty ? '' : '/$maxNo'} 次（${delayMs}ms 后）',
          sub: failText.isEmpty || failText == 'null' ? null : failText,
        );
      case 'llm/retry-started':
        return _chipTile(
          icon: Icons.replay_outlined,
          color: Acc.amber(context),
          text: '模型重试开始 · 第 ${r.data['retry'] ?? '?'} 次',
        );
      // ---- 消息反馈（👍/👎 + 备注） ----
      case 'feedback/message-put':
        final note = '${r.data['note'] ?? ''}'.trim();
        return _chipTile(
          icon: '${r.data['rating']}' == 'negative'
              ? Icons.thumb_down_alt_outlined
              : Icons.thumb_up_alt_outlined,
          color: Acc.teal(context),
          text: '消息反馈 · ${'${r.data['rating']}' == 'negative' ? '差评' : '好评'}',
          sub: note.isEmpty ? null : note,
        );
      case 'feedback/message-delete':
        return _chipTile(
          icon: Icons.delete_outline,
          color: scheme.onSurfaceVariant,
          text: '消息反馈 · 已撤下',
        );
      case 'feedback/record':
        return _chipTile(
          icon: Icons.rate_review_outlined,
          color: Acc.teal(context),
          text: '反馈记录 · ${r.data['kind'] ?? r.data['rating'] ?? ''}',
          sub: '${r.data['note'] ?? ''}'.trim().isEmpty
              ? null
              : '${r.data['note']}'.trim(),
        );
      // ---- 队列消息改写 / 撤回（inbox splice） ----
      // 语义：insert=入队、remove=出队（送达）、同事件两者并存=改写、
      // outcome:'canceled'=撤回。纯入队/出队是管道流量（会以 user/message
      // 呈现或随轮次消化），不渲染；只显示真正的撤回与改写。
      case 'agent/inbox/spliced':
        final inserted = (r.data['inserted'] as List? ?? [])
            .whereType<Map>()
            .toList();
        final removed = (r.data['removedCount'] as num? ?? 0).toInt();
        final canceled = '${r.data['outcome'] ?? ''}' == 'canceled';
        final edited = removed > 0 && inserted.isNotEmpty;
        if (!canceled && !edited) return const SizedBox.shrink();
        final preview = inserted
            .map((m) => _contentText(m['content'] ?? m))
            .where((s) => s.trim().isNotEmpty)
            .join('\n');
        return _chipTile(
          icon: Icons.edit_note_outlined,
          color: Acc.pink(context),
          text: canceled
              ? '消息撤回'
              : '消息改写 · 撤下 $removed 条 / 补入 ${inserted.length} 条',
          sub: preview.isEmpty ? null : preview,
        );
      // ---- 定时任务变更 ----
      case 'schedule/change':
        final op = '${r.data['operation'] ?? ''}';
        final opLabel = switch (op) {
          'delete' => '已删除',
          'create' => '已创建',
          'update' => '已更新',
          _ => op,
        };
        return _chipTile(
          icon: Icons.schedule_outlined,
          color: Acc.lightBlue(context),
          text: '定时任务 · $opLabel',
          sub: '${r.data['id'] ?? ''}',
        );
      // ---- B 档：低频事件折叠成一行小 tile，不刷屏也不失可见性 ----
      case 'assistant/attempt':
        return _chipTile(
          icon: Icons.history_edu_outlined,
          color: scheme.onSurfaceVariant,
          text: '一次未完成的输出（随后重试）',
        );
      case 'hook/invoked':
        return _chipTile(
          icon: Icons.bolt_outlined,
          color: scheme.onSurfaceVariant,
          text: '钩子 · ${r.data['name'] ?? r.data['hook'] ?? ''}',
        );
      case 'hook/result':
        if (r.data['error'] == null && '${r.data['ok']}' != 'false') {
          return const SizedBox.shrink();
        }
        return _chipTile(
          icon: Icons.error_outline,
          color: scheme.error,
          text: '钩子失败 · ${r.data['name'] ?? r.data['hook'] ?? ''}',
          sub: '${r.data['error'] ?? r.data['message'] ?? ''}',
        );
      case 'subagent/catalog':
        return _chipTile(
          icon: Icons.account_tree_outlined,
          color: scheme.onSurfaceVariant,
          text: '子agent 目录更新',
        );
      case 'subagent/model-selection-policy':
        return _chipTile(
          icon: Icons.account_tree_outlined,
          color: scheme.onSurfaceVariant,
          text: '子agent 模型策略更新',
        );
      case 'team/member':
        return _chipTile(
          icon: Icons.groups_outlined,
          color: Acc.cyan(context),
          text:
              '团队成员 · ${r.data['member'] is Map ? '${(r.data['member'] as Map)['name'] ?? (r.data['member'] as Map)['role'] ?? ''}' : ''}',
        );
      case 'team/task':
        return _chipTile(
          icon: Icons.groups_outlined,
          color: Acc.cyan(context),
          text:
              '团队任务 · ${r.data['task'] is Map ? '${(r.data['task'] as Map)['title'] ?? (r.data['task'] as Map)['summary'] ?? (r.data['task'] as Map)['status'] ?? ''}' : ''}',
        );
      case 'team/message/queued':
        return _chipTile(
          icon: Icons.groups_outlined,
          color: scheme.onSurfaceVariant,
          text: '团队消息 · 排队',
        );
      case 'team/message/delivered':
        return _chipTile(
          icon: Icons.groups_outlined,
          color: scheme.onSurfaceVariant,
          text: '团队消息 · 已送达',
        );
      case 'compaction/prune':
        final range = Map<String, dynamic>.from(
          r.data['shadowedRange'] as Map? ?? {},
        );
        final tok = (r.data['shadowedTokenCount'] as num? ?? 0).toInt();
        return _chipTile(
          icon: Icons.compress,
          color: Acc.purple(context),
          text: '上下文压缩 · 裁剪 #${range['start'] ?? '?'}–#${range['end'] ?? '?'}',
          sub: tok > 0 ? '${_fmtTokens(tok)} tokens' : null,
        );
      default:
        // 剩余纯协议内部噪声不渲染（web 同样不显示）：step/*、turn/end、
        // request/*、session/end-seed、session/title-llm-request、
        // session-log-deepseek/*、tool/ptc-dispatch*、web/*。
        // session/title 单独走标题同步（见 _liveTitle），不落气泡。
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = _sorted;
    // 子agent 页是 push 出来的路由：leading 给返回箭头（回上一级，通常即主agent）；
    // 外壳直接承载的主会话页保留汉堡菜单开抽屉。
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final isSubagent = widget.summary.parentSessionId != null;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Builder(builder: skinFlexibleSpace),
        leading: IconButton(
          icon: Icon(canPop ? Icons.arrow_back : Icons.menu),
          tooltip: canPop ? '返回上级' : '菜单',
          onPressed: () {
            final nav = Navigator.of(context);
            if (nav.canPop()) {
              nav.pop();
            } else {
              widget.onOpenDrawer();
            }
          },
        ),
        // 定尺寸外壳：裸 Text 在此 AppBar 的 middle 槽不绘制（真机实证），
        // 用 SizedBox 撑出确定盒后正常上画；同时保证标题不被 actions 挤没。
        title: SizedBox(
          width: 240,
          height: 40,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${isSubagent ? '子agent · ' : ''}${_displayTitle(records)}',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        actions: [
          // 主agent 快捷键（仅子agent 页出现）
          if (isSubagent && canPop)
            TextButton(
              onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
              child: const Text('主agent'),
            ),
          // 停止当前轮：仅运行中显示（空闲时是死按钮，纯占位）。
          // 红色调提示"打断中"，是运行期最重要的上下文动作。
          if (_running)
            IconButton(
              onPressed: _cancel,
              tooltip: '停止当前轮',
              icon: Icon(
                Icons.stop_circle_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          // 低频操作收进溢出菜单：计划模式开关在输入卡 + 面板里
          // （激活时输入框上方有「计划 · 开」chip，状态不丢）。
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'subagents':
                  _showSubagents();
                case 'trajectory':
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TrajectoryPage(
                        records: _sorted,
                        title:
                            '轨迹 · ${widget.summary.title.isEmpty ? widget.summary.sessionId : widget.summary.title}',
                      ),
                    ),
                  );
                case 'resubscribe':
                  _start();
                case 'plan':
                  _togglePlan();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'subagents',
                child: ListTile(
                  leading: const Icon(Icons.account_tree_outlined),
                  title: const Text('子agent'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              PopupMenuItem(
                value: 'trajectory',
                child: ListTile(
                  leading: const Icon(Icons.timeline),
                  title: const Text('轨迹'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              PopupMenuItem(
                value: 'plan',
                child: ListTile(
                  leading: const Icon(Icons.map_outlined),
                  title: Text(_planActive ? '退出计划模式' : '计划模式'),
                  trailing: _planActive
                      ? Icon(Icons.check, color: Acc.lightBlue(context))
                      : null,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'resubscribe',
                child: ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text('重新订阅'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(onPressed: _start, child: const Text('重试')),
                  ],
                ),
              ),
            ),
          if (_hasMore)
            TextButton(onPressed: _loadEarlier, child: const Text('加载更早的消息')),
          Expanded(
            child: SafeArea(
              top: false,
              bottom: false,
              child: _centerWidth(
                _loading
                    ? const Center(child: CircularProgressIndicator())
                    : Builder(
                        builder: (_) {
                          final items = _buildItems(records);
                          return Stack(
                            children: [
                              ScrollablePositionedList.builder(
                                itemScrollController: _itemScrollCtrl,
                                itemPositionsListener: _itemPositions,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                itemCount: items.length,
                                itemBuilder: (_, i) => items[i],
                              ),
                              // 轮次导航轨（≥2 轮才显示，对齐桌面）
                              if (_turnItems.length >= 2)
                                Positioned.fill(
                                  child: TurnRail(
                                    items: _turnItems,
                                    activeTurn: _activeTurn,
                                    runningTurn:
                                        _running && _turnItems.isNotEmpty
                                        ? _turnItems.last.turn
                                        : null,
                                    onJump: _jumpToTurn,
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
              ),
            ),
          ),
          if (_running)
            SafeArea(
              top: false,
              bottom: false,
              child: _centerWidth(
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        '深度求索中… ${_elapsedLabel}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ValueListenableBuilder(
            valueListenable: InteractionCenter.I.pending,
            builder: (context, _, __) {
              final pending = InteractionCenter.I.forAgent(
                widget.summary.sessionId,
              );
              debugPrint(
                '[page] vlb pending=${pending?.eventId ?? "null"} '
                'agent=${widget.summary.sessionId}',
              );
              if (pending != null) {
                // 与输入框同配方：普通子级 + 内容自适应。作答卡内部自己限高
                // （键盘感知），保证提交按钮行永远可见。
                return SafeArea(
                  top: false,
                  child: _centerWidth(
                    InteractionComposer(
                      interaction: pending,
                      onAnswer: (eventId, value) =>
                          InteractionCenter.I.answer(eventId, value),
                      onPass: (eventId) => InteractionCenter.I.pass(eventId),
                      onDismiss: (eventId) =>
                          InteractionCenter.I.dismiss(eventId),
                    ),
                  ),
                );
              }
              final scheme = Theme.of(context).colorScheme;
              final tk = Theme.of(context).extension<SkinTokens>()!;
              return SafeArea(
                top: false,
                child: _centerWidth(
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 附件条（选中待发，对齐桌面 conversation.input.attachments）
                        if (_draftFiles.isNotEmpty) _attachmentStrip(),
                        // 目标条（对齐桌面 GoalBar dock）
                        if (_goalObjective.isNotEmpty) _goalDock(),
                        // 队列 dock（对齐桌面 QueueDock：排队消息展示/撤/改/立即）
                        if (_queueRows.isNotEmpty) _queueDock(),
                        // 斜杠命令面板（/ 命令名 token 未敲完时浮出候选）
                        if (_paletteQuery != null) _commandPalette(),
                        // 输入卡（参考 DeepSeek 输入卡：大圆角卡、上文本区，
                        // 下控制排——左图标+文字药丸，右圆钮[附件][提及][发送]）。
                        // 装饰走皮肤令牌（换皮不换布局）
                        Container(
                          decoration: BoxDecoration(
                            color: tk.composerFill,
                            borderRadius: BorderRadius.circular(
                              tk.composerRadius,
                            ),
                            border: tk.composerBorder == null
                                ? null
                                : Border.all(color: tk.composerBorder!),
                            boxShadow: [
                              if (tk.glowColor != null)
                                BoxShadow(
                                  color: tk.glowColor!,
                                  blurRadius: 22,
                                  offset: const Offset(0, 6),
                                ),
                            ],
                          ),
                          padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // 生效中的设置 chip：仅在有激活项时出现（计划开 /
                              // 权限非默认 / 模型非默认），平时零占位不干扰。
                              if (_planActive ||
                                  _permissionPreset.isNotEmpty ||
                                  _modelLabel.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    right: 4,
                                    bottom: 6,
                                  ),
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      if (_planActive)
                                        _composerPill(
                                          icon: Icons.map_outlined,
                                          label: '计划 · 开',
                                          active: true,
                                          onTap: _togglePlan,
                                        ),
                                      if (_permissionPreset.isNotEmpty)
                                        _composerPill(
                                          icon: Icons
                                              .admin_panel_settings_outlined,
                                          label:
                                              '权限 · ${_permissionLabel(_permissionPreset)}',
                                          active: true,
                                          onTap: _pickPermission,
                                        ),
                                      if (_modelLabel.isNotEmpty)
                                        _composerPill(
                                          icon: Icons.tune,
                                          label: '模型 · $_modelLabel',
                                          active: true,
                                          onTap: _pickModel,
                                        ),
                                    ],
                                  ),
                                ),
                              // 单行胶囊（参考 WorkBuddy）：+ 展开全部扩展，
                              // 中间输入，右端发送/停止。
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  _composerIcon(
                                    icon: Icons.add_circle_outline,
                                    tooltip: '更多',
                                    onPressed: _showComposerMore,
                                  ),
                                  Expanded(
                                    child: TextField(
                                      controller: _inputCtrl,
                                      minLines: 1,
                                      maxLines: 5,
                                      decoration: InputDecoration(
                                        border: InputBorder.none,
                                        isDense: true,
                                        hintText: _placeholderText(),
                                        hintMaxLines: 1,
                                        hintStyle: TextStyle(
                                          fontSize: 15,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              vertical: 8,
                                            ),
                                      ),
                                      style: const TextStyle(fontSize: 15),
                                      onSubmitted: (_) => _send(),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Tooltip(
                                    message: _running ? '停止当前轮' : '发送',
                                    child: Material(
                                      color: scheme.primary,
                                      shape: const CircleBorder(),
                                      child: InkWell(
                                        customBorder: const CircleBorder(),
                                        onTap: _sending
                                            ? null
                                            : (_running ? _cancel : _send),
                                        child: SizedBox(
                                          width: 30,
                                          height: 30,
                                          child: _sending
                                              ? const Padding(
                                                  padding: EdgeInsets.all(8),
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.white,
                                                      ),
                                                )
                                              : Icon(
                                                  _running
                                                      ? Icons.stop
                                                      : Icons.arrow_upward,
                                                  size: 17,
                                                  color: scheme.onPrimary,
                                                ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// @ 提及弹层：文件（fileReferences/list）在前、会话
/// （sessionReferenceResolver/candidates）在后；一域失败另一域照常。
/// 选中 pop 插入串：文件=@path/@"p s"/@dir/，会话=候选自带 mention。
class _ReferenceSheet extends StatefulWidget {
  const _ReferenceSheet({required this.client, required this.sessionId});
  final DshClient client;
  final String sessionId;
  @override
  State<_ReferenceSheet> createState() => _ReferenceSheetState();
}

class _ReferenceSheetState extends State<_ReferenceSheet> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<dynamic> _files = const [];
  List<dynamic> _sessions = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _q.addListener(_onQueryChanged);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.removeListener(_onQueryChanged);
    _q.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final q = _q.text.trim();
    // 并行双域；单域失败回落空数组（对齐桌面失败行为）。
    final results = await Future.wait<dynamic>([
      widget.client
          .fileReferenceCandidates(widget.sessionId, q)
          .catchError((Object _) => const <dynamic>[]),
      widget.client
          .sessionReferenceCandidates(widget.sessionId, q)
          .catchError((Object _) => const <dynamic>[]),
    ]);
    if (!mounted) return;
    setState(() {
      _files = results[0] as List<dynamic>;
      _sessions = results[1] as List<dynamic>;
      _loading = false;
    });
  }

  /// 文件行 → 插入串（桌面 @path 语法：空格路径加引号、目录带尾斜杠）。
  String _fileMention(Map<String, dynamic> item) {
    final path = '${item['path'] ?? ''}';
    if ('${item['kind']}' == 'directory') {
      return path.endsWith('/') ? '@$path' : '@$path/';
    }
    return path.contains(RegExp(r'\s')) ? '@"$path"' : '@$path';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _q,
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.alternate_email, size: 18),
                  hintText: '搜索文件或对话…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView(
                children: [
                  if (_files.isNotEmpty)
                    _groupHeader(scheme, Icons.folder_outlined, '文件'),
                  for (final raw in _files)
                    if (raw is Map)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          '${raw['kind']}' == 'directory'
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                        title: Text(
                          '${raw['path'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        onTap: () => Navigator.pop(
                          context,
                          _fileMention(Map<String, dynamic>.from(raw)),
                        ),
                      ),
                  if (_sessions.isNotEmpty)
                    _groupHeader(scheme, Icons.forum_outlined, '会话'),
                  for (final raw in _sessions)
                    if (raw is Map)
                      ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.chat_bubble_outline,
                          size: 20,
                        ),
                        title: Text(
                          '${raw['label'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: raw['cwd'] == null
                            ? null
                            : Text(
                                '${raw['cwd']}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10),
                              ),
                        onTap: () =>
                            Navigator.pop(context, '${raw['mention'] ?? ''}'),
                      ),
                  if (!_loading && _files.isEmpty && _sessions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '无匹配候选',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupHeader(ColorScheme scheme, IconData icon, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 队列改写弹窗：自持 controller，pop 返回编辑文本（null=取消）。
class _QueueEditDialog extends StatefulWidget {
  const _QueueEditDialog({required this.initial});
  final String initial;
  @override
  State<_QueueEditDialog> createState() => _QueueEditDialogState();
}

class _QueueEditDialogState extends State<_QueueEditDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('改写队列消息'),
      content: TextField(controller: _ctrl, maxLines: 5, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// raw JSON 参数 → 缩进美化（非 JSON 原样返回）。
String _prettyJson(String raw) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } catch (_) {
    return raw;
  }
}

/// 参数单行摘要：key=val, key=val…
String _argSummary(String raw) {
  try {
    final v = jsonDecode(raw);
    if (v is Map) {
      return v.entries
          .take(3)
          .map((e) {
            var val = '${e.value}'.replaceAll('\n', ' ');
            if (val.length > 24) val = '${val.substring(0, 24)}…';
            return '${e.key}=$val';
          })
          .join(', ');
    }
    return '$v'.replaceAll('\n', ' ');
  } catch (_) {
    return raw.replaceAll('\n', ' ');
  }
}

const TextStyle _monoStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Consolas', 'Courier New'],
  fontSize: 12,
);

/// epoch ms → 本地时钟「14:23」（withSeconds → 14:23:05）。
String _fmtClock(int ms, {bool withSeconds = false}) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String p(int v) => v.toString().padLeft(2, '0');
  return withSeconds
      ? '${p(t.hour)}:${p(t.minute)}:${p(t.second)}'
      : '${p(t.hour)}:${p(t.minute)}';
}

/// 毫秒 → 「850ms」「1.2s」「3m05s」。
String _fmtDuration(int ms) {
  if (ms < 1000) return '${ms}ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final m = ms ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  return '${m}m${s.toString().padLeft(2, '0')}s';
}

/// token 数 → 「856」「4.6k」。
String _fmtTokens(int n) {
  if (n < 1000) return '$n';
  return '${(n / 1000).toStringAsFixed(1)}k';
}

/// 工具调用聚合条目（tool/call + tool/result 按 callId 配对）。
class _ToolEntry {
  String name = 'tool';
  String arguments = '';
  String argsPretty = '';
  String argSummary = '';
  String resultText = '';
  bool isError = false;
  bool hasResult = false;
  bool emitted = false;
  int? callMs; // tool/call 时间（epoch ms）
  int? resultMs; // tool/result 时间

  int? get durationMs =>
      (callMs != null && resultMs != null) ? resultMs! - callMs! : null;

  void setCall(String name, String args) {
    if (this.name == 'tool' && name.isNotEmpty) this.name = name;
    if (arguments.isEmpty && args.isNotEmpty) {
      arguments = args;
      argsPretty = _prettyJson(args);
      argSummary = _argSummary(args);
    }
  }
}

/// 工具调用卡片：状态图标 + 名称 + 参数摘要；点击展开（美化参数 / 结果 / 错误）。
class _ToolCallCard extends StatefulWidget {
  final _ToolEntry entry;
  const _ToolCallCard({required this.entry});

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = e.hasResult;
    // 询问工具：参数是结构化 questions，直接渲染问题卡而非原始 JSON。
    if (e.name == 'ask_user_question') {
      final questions = _parseMapList(e.arguments, 'questions');
      if (questions.isNotEmpty) return _questionCard(context, e, questions);
    }
    // 计划工具：参数是完整计划 Markdown，按计划卡渲染（对齐 web presentCall：
    // 标题=计划首个 # 标题，正文=计划全文）。
    if (e.name == 'exit_plan_mode') {
      final plan = _parseArgString(e.arguments, 'plan');
      if (plan.trim().isNotEmpty) return _planCard(context, e, plan.trim());
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              children: [
                if (e.isError)
                  Icon(Icons.close, size: 14, color: scheme.error)
                else if (done)
                  Icon(Icons.check, size: 14, color: Acc.green(context))
                else
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: scheme.primary,
                    ),
                  ),
                const SizedBox(width: 8),
                Text(
                  e.name,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    e.arguments.isEmpty ? '' : e.argSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
                ),
                if (e.durationMs != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    _fmtDuration(e.durationMs!),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (e.callMs != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        [
                          _fmtClock(e.callMs!, withSeconds: true),
                          if (e.durationMs != null)
                            '耗时 ${_fmtDuration(e.durationMs!)}',
                        ].join(' · '),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  if (e.arguments.isNotEmpty) ...[
                    Row(
                      children: [
                        Text('参数', style: theme.textTheme.labelSmall),
                        const Spacer(),
                        _copyIcon(e.argsPretty),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.argsPretty,
                      style: _monoStyle.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    children: [
                      Text('结果', style: theme.textTheme.labelSmall),
                      const Spacer(),
                      if (done && e.resultText.isNotEmpty)
                        _copyIcon(e.resultText),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    done
                        ? (e.resultText.isEmpty ? '（空）' : e.resultText)
                        : '运行中…',
                    style: _monoStyle.copyWith(
                      color: e.isError ? scheme.error : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 从工具参数/结果 JSON 里安全取出对象列表（解析失败返回空 → 走通用卡兜底）。
  List<Map<String, dynamic>> _parseMapList(String json, String key) {
    try {
      final j = jsonDecode(json);
      final list = (j is Map ? j[key] as List? : null) ?? const [];
      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 从工具参数 JSON 里安全取出字符串字段（解析失败返回空 → 走通用卡兜底）。
  String _parseArgString(String json, String key) {
    try {
      final j = jsonDecode(json);
      final v = j is Map ? j[key] : null;
      return v is String ? v : '';
    } catch (_) {
      return '';
    }
  }

  /// exit_plan_mode 计划卡：标题=计划首个 # 标题，正文=计划 Markdown。
  Widget _planCard(BuildContext context, _ToolEntry e, String plan) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = _firstHeading(plan) ?? '计划';
    final done = e.hasResult;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color:
                (e.isError
                        ? scheme.error
                        : done
                        ? Acc.green(context)
                        : Acc.lightBlue(context))
                    .withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.map_outlined,
                  size: 14,
                  color: Acc.lightBlue(context),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (!done)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: scheme.primary,
                    ),
                  )
                else
                  Icon(
                    e.isError ? Icons.close : Icons.check,
                    size: 14,
                    color: e.isError ? scheme.error : Acc.green(context),
                  ),
                if (e.durationMs != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    _fmtDuration(e.durationMs!),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            MarkdownText(plan),
            if (done) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      e.isError ? Icons.close : Icons.check_circle,
                      size: 12,
                      color: e.isError ? scheme.error : Acc.green(context),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      e.isError
                          ? e.resultText
                          : (e.resultText.contains('approved')
                                ? '计划已批准 · 退出计划模式，开始执行'
                                : e.resultText),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: e.isError ? scheme.error : Acc.green(context),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 8),
              Text(
                '等待评审…',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 计划的首个 Markdown 标题（对齐 web 的 firstHeading）。
  String? _firstHeading(String plan) {
    for (final line in plan.split('\n')) {
      final m = RegExp(r'^#{1,6}\s+(.+?)\s*$').firstMatch(line);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// ask_user_question 问题卡：问题/选项/多选标注 + 回答展示。
  Widget _questionCard(
    BuildContext context,
    _ToolEntry e,
    List<Map<String, dynamic>> questions,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final answers = _parseMapList(e.resultText, 'answers');

    Map<String, dynamic>? answerOf(String id) {
      for (final a in answers) {
        if ('${a['id']}' == id) return a;
      }
      return null;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: (e.hasResult ? Acc.green(context) : Acc.orange(context))
                .withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.question_answer_outlined,
                  size: 14,
                  color: e.hasResult ? Acc.green(context) : Acc.orange(context),
                ),
                const SizedBox(width: 6),
                Text(
                  '询问 · ${questions.length} 个问题',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (!e.hasResult)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: scheme.primary,
                    ),
                  )
                else
                  Icon(Icons.check, size: 14, color: Acc.green(context)),
                if (e.durationMs != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    _fmtDuration(e.durationMs!),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < questions.length; i++) ...[
              if (i > 0) const Divider(height: 16),
              _questionBlock(
                context,
                i,
                questions[i],
                answerOf('${questions[i]['id'] ?? ''}'),
                e.hasResult,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _questionBlock(
    BuildContext context,
    int index,
    Map<String, dynamic> q,
    Map<String, dynamic>? answer,
    bool hasResult,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final header = '${q['header'] ?? ''}'.trim();
    final question = '${q['question'] ?? ''}'.trim();
    final detail = '${q['detail'] ?? ''}'.trim();
    final multi = q['multi_select'] == true;
    final options = (q['options'] as List? ?? []).whereType<Map>().toList();
    final selected = ((answer?['selected'] as List?) ?? const [])
        .whereType<String>()
        .toSet();
    final custom = '${answer?['custom'] ?? ''}'.trim();
    final answered = answer != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header.isNotEmpty)
          Text(
            questionLabel(q, header),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        if (question.isNotEmpty) ...[
          if (header.isNotEmpty) const SizedBox(height: 2),
          Text(question, style: theme.textTheme.bodyMedium),
        ],
        // 携带正文的询问（如计划评审的 detail=完整计划）：正文按 Markdown
        // 全量渲染，不再丢细节。
        if (detail.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: MarkdownText(detail),
          ),
        ],
        if (options.isNotEmpty) ...[
          const SizedBox(height: 6),
          // 选项一列一行（标签 + 描述常显），回答按行展示，细节不丢失。
          for (final o in options)
            Builder(
              builder: (context) {
                final label = '${o['label'] ?? ''}';
                final desc = '${o['description'] ?? ''}'.trim();
                final isSel = selected.contains(label);
                return Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isSel
                        ? Acc.green(context).withValues(alpha: 0.13)
                        : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSel
                          ? Acc.green(context).withValues(alpha: 0.5)
                          : scheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(
                          multi
                              ? (isSel
                                    ? Icons.check_box
                                    : Icons.check_box_outline_blank)
                              : (isSel
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked),
                          size: 13,
                          color: isSel
                              ? Acc.green(context)
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              questionLabel(q, label),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontWeight: isSel ? FontWeight.w600 : null,
                              ),
                            ),
                            if (desc.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: Text(
                                  desc,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          if (multi)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '（可多选）',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
        if (!hasResult) ...[
          const SizedBox(height: 6),
          Text(
            '等待回答…',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ] else if (!answered) ...[
          const SizedBox(height: 6),
          Text(
            '（未作答）',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ] else if (selected.isEmpty && custom.isEmpty) ...[
          const SizedBox(height: 6),
          Text(
            '（已跳过）',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ] else ...[
          // 回答一行一个：每条选项答案一行（含描述），自由填单独一行。
          const SizedBox(height: 8),
          for (final o in options)
            if (selected.contains('${o['label']}')) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.check_circle,
                      size: 13,
                      color: Acc.green(context),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      questionLabel(q, '${o['label']}'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Acc.green(context),
                      ),
                    ),
                  ),
                ],
              ),
              if ('${o['description'] ?? ''}'.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 19, top: 1, bottom: 3),
                  child: Text(
                    '${o['description']}'.trim(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          if (custom.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.short_text,
                    size: 13,
                    color: Acc.green(context),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    custom,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Acc.green(context),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ],
    );
  }

  Widget _copyIcon(String text) {
    return InkWell(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已复制'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      },
      child: Icon(
        Icons.copy,
        size: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// reasoning 思考块：折叠，展开显示灰字全文。
class _ReasoningFold extends StatefulWidget {
  final String text;
  const _ReasoningFold({required this.text});

  @override
  State<_ReasoningFold> createState() => _ReasoningFoldState();
}

class _ReasoningFoldState extends State<_ReasoningFold> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.psychology_outlined,
                  size: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Text(
                  _expanded ? '思考过程' : '思考过程（${widget.text.length} 字）',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 3),
              child: Text(
                widget.text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
