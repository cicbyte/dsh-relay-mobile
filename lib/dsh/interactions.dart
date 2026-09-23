import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dsh_client.dart';
import 'transport.dart';

/// 一条待处理的人机交互（询问 / 授权），来自 `$events` Remote 事件流的
/// `waterfall` 帧（host Cordis waterfall 的远端呈现）。
class PendingInteraction {
  final String eventId;
  final String agentId; // 归属 Agent（即会话 id）
  final String event; // 'user-questions/request' | 'approval/request'
  final Map<String, dynamic> request;

  PendingInteraction({
    required this.eventId,
    required this.agentId,
    required this.event,
    required this.request,
  });

  bool get isQuestion => event == 'user-questions/request';
  bool get isApproval => event == 'approval/request';

  /// 询问的问题列表（请求侧字段为驼峰 multiSelect）。
  List<Map<String, dynamic>> get questions => (request['questions'] as List? ?? [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}

/// `$events` Remote 事件中心（全局单例）。
///
/// 协议（dsh-api-gateway stream-protocol）：
///  - 下行流端点 `$events`（args 必须为空对象）：首帧
///    `{type:'ready', clientId, host}`，随后
///    `{type:'waterfall', event, eventId, agentId, request}` /
///    `{type:'cancel', eventId}` / `{type:'emit', event, args}`（广播，忽略）。
///    连接时会补投所有 pending 事件，故断线重连无需对账。
///  - 上行一元 RPC `$events/result`，args =
///    `{clientId, eventId, outcome}`，outcome 三态：
///    `{kind:'result', value}` 应答 / `{kind:'next'}` 放弃并转交下一个
///    waterfall 监听者（例如留在网页端作答）/ `{kind:'rejected', error}` 拒绝。
class InteractionCenter {
  static final InteractionCenter I = InteractionCenter._();
  InteractionCenter._();

  DshClient? _client;
  DshMux? _mux;
  String? _clientId;
  StreamSubscription? _sub;
  DshTransport? _startedFor;

  final Map<String, PendingInteraction> _byId = {};
  final ValueNotifier<List<PendingInteraction>> pending = ValueNotifier([]);

  /// 幂等启动：同一 [DshTransport] 只建一次 `$events` 流。
  void ensureStarted(DshClient client) {
    if (_startedFor == client.transport && _mux != null) return;
    _sub?.cancel();
    _startedFor = client.transport;
    _client = client;
    _byId.clear();
    _notify();
    final mux = DshMux(client);
    _mux = mux;
    mux.onReconnected = _openStream;
    mux.connect().then((_) => _openStream()).catchError((_) {
      // 连接失败由 DshMux 的 3s 单飞重连兜底；onReconnected 时补开流。
    });
  }

  void _openStream() {
    final mux = _mux;
    if (mux == null || !mux.isConnected) return;
    _sub?.cancel();
    _sub = mux.open(r'$events', const {}).listen(
      _onItem,
      onError: (_) {/* 流断开；重连后 onReconnected 补开，pending 由服务端补投 */},
      cancelOnError: false,
    );
  }

  void _onItem(Map<String, dynamic> v) {
    switch (v['type']) {
      case 'ready':
        _clientId = '${v['clientId']}';
      case 'waterfall':
        final id = '${v['eventId']}';
        if (id.isEmpty || id == 'null') return;
        _byId[id] = PendingInteraction(
          eventId: id,
          agentId: '${v['agentId']}',
          event: '${v['event']}',
          request: Map<String, dynamic>.from(v['request'] as Map? ?? {}),
        );
        _notify();
      case 'cancel':
        if (_byId.remove('${v['eventId']}') != null) _notify();
    }
  }

  void _notify() => pending.value = List.unmodifiable(_byId.values);

  /// 当前会话（[agentId]）的待处理交互，没有则 null。
  PendingInteraction? forAgent(String agentId) {
    for (final p in _byId.values) {
      if (p.agentId == agentId) return p;
    }
    return null;
  }

  /// 应答：`outcome.result.value`。询问传 `{answers:[{id,selected,custom?}]}`，
  /// 授权传结果字符串（'allowed-once' / 'rejected'）。
  Future<void> answer(String eventId, Object? value) async {
    await _submit(eventId, {'kind': 'result', 'value': value});
  }

  /// 放弃应答，转交下一个 waterfall 监听者（如网页端）。
  Future<void> pass(String eventId) async {
    await _submit(eventId, {'kind': 'next'});
  }

  Future<void> _submit(String eventId, Map<String, dynamic> outcome) async {
    final client = _client;
    final cid = _clientId;
    if (client == null || cid == null) {
      throw DshRpcException('events/not-connected', '事件通道未就绪');
    }
    // 先本地消掉卡片，再上行（失败再挂回，避免重复应答同一 eventId）。
    final removed = _byId.remove(eventId);
    _notify();
    try {
      await client.rpc(r'$events/result', {
        'clientId': cid,
        'eventId': eventId,
        'outcome': outcome,
      });
    } catch (_) {
      if (removed != null && !_byId.containsKey(eventId)) {
        _byId[eventId] = removed;
        _notify();
      }
      rethrow;
    }
  }
}
