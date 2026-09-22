import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';

import '../device_info.dart';
import '../dsh/dsh_client.dart';
import '../widgets/markdown_text.dart';
import 'trajectory_page.dart';

/// 会话页：session/follow（快照+事件订阅）渲染对话，session/prompt 发消息。
class SessionPage extends StatefulWidget {
  final DshClient client;
  final SessionSummary summary;
  final VoidCallback onOpenDrawer;

  /// 发消息等会话活动后回调（AppRoot 刷新侧边栏列表）。
  final VoidCallback? onSessionEnded;

  const SessionPage({
    super.key,
    required this.client,
    required this.summary,
    required this.onOpenDrawer,
    this.onSessionEnded,
  });

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
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
  final _scrollCtrl = ScrollController();

  /// subagent 会话的 address 需要 mode（one-shot / continuable），失败时按序兜底。
  int _modeIdx = 0;
  bool _gotFrame = false;

  /// 「深度求索中…」秒级刷新用。
  Timer? _ticker;

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

  List<String> get _modes => widget.summary.parentSessionId == null ? ['one-shot'] : ['one-shot', 'continuable'];

  Map<String, dynamic> get _address => sessionAddress(
        sessionId: widget.summary.sessionId,
        parentSessionId: widget.summary.parentSessionId,
        mode: _modes[_modeIdx.clamp(0, _modes.length - 1)],
      );

  @override
  void initState() {
    super.initState();
    _mux = DshMux(widget.client);
    // 断线自动重连后自动重订阅（避免人工点重试）
    _mux.onReconnected = _openFollow;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _running) setState(() {});
    });
    _start();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    _mux.close();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
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
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openFollow() {
    _gotFrame = false;
    _sub?.cancel();
    _sub = _mux.open('session/follow', {
      'request': {
        'address': _address,
        // 快照尾窗不宜过大：大 JSON 解析会阻塞主 isolate，延迟自动 Pong（服务端 2 次未应答即断线）
        'maxMessages': 50,
      },
    }).listen(_onFrame, onError: (Object e) {
      // subagent 场景：mode 不匹配时换下一个再试（如 one-shot → continuable）
      final msg = '$e';
      final canRetry = !_gotFrame && _modeIdx < _modes.length - 1;
      if (canRetry && (msg.contains('agent-busy') || msg.contains('mode') || msg.contains('address'))) {
        setState(() => _modeIdx++);
        _openFollow();
        return;
      }
      if (mounted) setState(() => _error = msg);
    }, onDone: () {
      if (mounted && _error == null) setState(() => _error = '连接已断开（下拉或点重试恢复）');
    });
  }

  void _onFrame(Map<String, dynamic> frame) {
    _gotFrame = true;
    setState(() {
      switch (frame['type']) {
        case 'snapshot':
          final cursor = (frame['cursor'] as num? ?? 0).toInt();
          _cursor = cursor;
          _hasMore = frame['hasMore'] == true;
          for (final r in (frame['records'] as List? ?? [])) {
            if (r is Map) {
              final rec = WireRecord.fromJson(Map<String, dynamic>.from(r));
              _records[rec.seq] = rec;
            }
          }
          _updateMinSeq();
        case 'event':
          final e = frame['event'];
          if (e is Map) {
            final rec = WireRecord.fromJson(Map<String, dynamic>.from(e));
            _records[rec.seq] = rec;
            _updateMinSeq();
          }
        // assistant-stream 帧：v1 不做打字机效果，忽略
      }
    });
    _scrollToBottom();
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
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
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
          }
        }
        _hasMore = v['hasMore'] == true;
        _updateMinSeq();
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('翻页失败：$e')));
    }
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败：$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('取消失败：$e')));
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
    final entries = (catalog['entries'] as List? ?? []).whereType<Map>().toList();
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
                            ? (running ? Colors.greenAccent : scheme.onSurfaceVariant)
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
                              Navigator.of(context).push(MaterialPageRoute(
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
                              ));
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

  List<WireRecord> get _sorted => (_records.values.toList()..sort((a, b) => a.seq.compareTo(b.seq)));

  String _contentText(dynamic content) {
    if (content is! List) return '';
    final parts = <String>[];
    for (final b in content) {
      if (b is Map && b['type'] == 'text' && b['text'] is String) parts.add(b['text'] as String);
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
          out.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.attach_file, size: 15),
              Flexible(child: Text('${b['name'] ?? 'file'}', overflow: TextOverflow.ellipsis)),
            ]),
          ));
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
      } catch (_) {/* fallthrough */}
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
          Row(children: [
            Icon(mine ? Icons.person_outline : Icons.auto_awesome,
                size: 13,
                color: mine
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Text(label, style: theme.textTheme.labelSmall),
            const Spacer(),
            if (meta.isNotEmpty) ...[
              Text(meta,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.7))),
              const SizedBox(width: 8),
            ],
            if (copyText != null && copyText.trim().isNotEmpty)
              InkWell(
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: copyText));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('已复制'),
                        duration: Duration(seconds: 1)));
                  }
                },
                child: Icon(Icons.copy,
                    size: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
          ]),
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
      if (b is Map && b['type'] == 'tool-result' && b['callId'] != null) return '${b['callId']}';
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
          final e = tools['${r.data['callId'] ?? r.seq}'] ?? newEntry('${r.data['callId'] ?? r.seq}');
          e.setCall('${r.data['name'] ?? 'tool'}', '${r.data['arguments'] ?? ''}');
          e.callMs ??= r.time;
        case 'tool/result':
          final msg = Map<String, dynamic>.from(r.data['message'] as Map? ?? {});
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
    for (final r in records) {
      if (r.ignorable) continue;
      switch (r.type) {
        case 'user/message':
          out.add(_messageBubble(
            label: '你',
            body: _blockWidgets(r.data['content']),
            time: r.time,
            copyText: _contentText(r.data['content']),
          ));
        case 'assistant/message':
          final msg = Map<String, dynamic>.from(r.data['message'] as Map? ?? {});
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
            out.add(_messageBubble(
              label: '助手${r.data['interrupted'] == true ? '（已中断）' : ''}',
              body: body,
              time: r.time,
              usage: u.isEmpty
                  ? null
                  : '↑${_fmtTokens((u['inputTokens'] as num? ?? 0).toInt())}'
                      ' ↓${_fmtTokens((u['outputTokens'] as num? ?? 0).toInt())}',
              copyText: plain.join('\n'),
            ));
          }
        case 'tool/call':
          final e = tools['${r.data['callId'] ?? r.seq}'] ??
              (_ToolEntry()..setCall('${r.data['name'] ?? 'tool'}', '${r.data['arguments'] ?? ''}'));
          if (!e.emitted) {
            e.emitted = true;
            out.add(_ToolCallCard(entry: e));
          }
        case 'tool/result':
          final e = tools[_resultKey(r)] ??
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
    }
    return out;
  }

  Widget _systemTile(WireRecord r) {
    switch (r.type) {
      case 'turn/start':
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
          child: Text('— 第 ${r.data['turn'] ?? '?'} 轮 · ${_fmtClock(r.time)} —',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall),
        );
      case 'system/message':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 16),
          child: Text(_contentText(r.data['content'] ?? r.data['message']),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontStyle: FontStyle.italic)),
        );
      default:
        // step/*、request/header、compaction/*、turn/end 等协议事件不渲染
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = _sorted;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.menu), onPressed: widget.onOpenDrawer),
        title: Text(
          widget.summary.title.isEmpty ? widget.summary.sessionId : widget.summary.title,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            onPressed: _showSubagents,
            tooltip: '子agent',
            icon: const Icon(Icons.account_tree_outlined),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TrajectoryPage(
                records: _sorted,
                title: '轨迹 · ${widget.summary.title.isEmpty ? widget.summary.sessionId : widget.summary.title}',
              ),
            )),
            tooltip: '轨迹',
            icon: const Icon(Icons.timeline),
          ),
          IconButton(onPressed: _cancel, tooltip: '停止当前轮', icon: const Icon(Icons.stop_circle_outlined)),
          IconButton(onPressed: _start, tooltip: '重新订阅', icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  Expanded(child: Text(_error!, style: const TextStyle(fontSize: 12))),
                  TextButton(onPressed: _start, child: const Text('重试')),
                ]),
              ),
            ),
          if (_hasMore)
            TextButton(onPressed: _loadEarlier, child: const Text('加载更早的消息')),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Builder(builder: (_) {
                    final items = _buildItems(records);
                    return ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: items.length,
                      itemBuilder: (_, i) => items[i],
                    );
                  }),
          ),
          if (_running)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
              child: Row(children: [
                const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(strokeWidth: 1.6)),
                const SizedBox(width: 7),
                Text(
                  '深度求索中… ${_elapsedLabel}',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.primary),
                ),
              ]),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    minLines: 1,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: '输入消息…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send),
                ),
              ]),
            ),
          ),
        ],
      ),
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
      return v.entries.take(3).map((e) {
        var val = '${e.value}'.replaceAll('\n', ' ');
        if (val.length > 24) val = '${val.substring(0, 24)}…';
        return '${e.key}=$val';
      }).join(', ');
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(children: [
            if (e.isError)
              Icon(Icons.close, size: 14, color: scheme.error)
            else if (done)
              const Icon(Icons.check, size: 14, color: Colors.greenAccent)
            else
              SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.8, color: scheme.primary)),
            const SizedBox(width: 8),
            Text(e.name,
                style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                e.arguments.isEmpty ? '' : e.argSummary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.8)),
              ),
            ),
            if (e.durationMs != null) ...[
              const SizedBox(width: 8),
              Text(_fmtDuration(e.durationMs!),
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7))),
            ],
            Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                size: 16, color: scheme.onSurfaceVariant),
          ]),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (e.callMs != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    [
                      _fmtClock(e.callMs!, withSeconds: true),
                      if (e.durationMs != null) '耗时 ${_fmtDuration(e.durationMs!)}',
                    ].join(' · '),
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
                  ),
                ),
              if (e.arguments.isNotEmpty) ...[
                Row(children: [
                  Text('参数', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  _copyIcon(e.argsPretty),
                ]),
                const SizedBox(height: 2),
                Text(e.argsPretty,
                    style: _monoStyle.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
              ],
              Row(children: [
                Text('结果', style: theme.textTheme.labelSmall),
                const Spacer(),
                if (done && e.resultText.isNotEmpty) _copyIcon(e.resultText),
              ]),
              const SizedBox(height: 2),
              Text(
                done ? (e.resultText.isEmpty ? '（空）' : e.resultText) : '运行中…',
                style: _monoStyle.copyWith(
                    color: e.isError ? scheme.error : scheme.onSurfaceVariant),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _copyIcon(String text) {
    return InkWell(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('已复制'), duration: Duration(seconds: 1)));
        }
      },
      child: Icon(Icons.copy, size: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.psychology_outlined,
                size: 13, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Text(
              _expanded ? '思考过程' : '思考过程（${widget.text.length} 字）',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                size: 14, color: theme.colorScheme.onSurfaceVariant),
          ]),
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
      ]),
    );
  }
}
