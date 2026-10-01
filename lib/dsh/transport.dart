import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 传输层抽象：上层（DshClient / DshMux）只认 request + openSocket，
/// 直连局域网（DirectTransport）与云端转发（RelayTransport）可互换。
abstract class DshTransport {
  Future<TransportResponse> request(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  });

  /// 打开一条到 [path]（如 /api/remote.mux）的 WS 隧道，返回文本帧双工通道。
  Future<TransportSocket> openSocket(String path, {Map<String, String> headers = const {}});

  /// 流式下载的可达 HTTP base：直连=宿主地址（方案 C）；隧道=relay 地址（方案 B 代理）。
  /// DownloadClient 用它做原生 HTTP 流式下载。
  Uri get downloadBase;

  Future<void> close();
}

class TransportResponse {
  final int status;
  final String body;
  final List<String> setCookie;
  // 二进制响应体（下载附件等）；文本响应时为 null。隧道帧 body 走 base64 解码填充。
  final List<int>? bytes;
  TransportResponse({required this.status, required this.body, this.setCookie = const [], this.bytes});
}

abstract class TransportSocket {
  Stream<String> get messages;
  void send(String text);
  Future<void> close([int? code, String? reason]);
}

class TransportException implements Exception {
  final String code;
  final String message;
  TransportException(this.code, this.message);
  @override
  String toString() => 'TransportException($code): $message';
}

// ---------------------------------------------------------------------------
// 直连：HttpClient / WebSocket 直接访问 dsh web（局域网 / adb reverse 场景）
// ---------------------------------------------------------------------------
class DirectTransport extends DshTransport {
  final Uri base;
  DirectTransport(this.base);

  @override
  Uri get downloadBase => base;

  Uri _path(String p) => base.replace(path: p, query: null);

  @override
  Future<TransportResponse> request(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.openUrl(method, _path(path));
      headers.forEach(req.headers.set);
      // 用 UTF-8 字节写入：req.write(String) 默认 latin1 编码，请求体含
      // 中文时抛 "Invalid argument (string): Contains invalid characters."
      // （_UnicodeSubsetEncoder）。JSON 本就是 UTF-8，按字节直写最稳。
      if (body != null) req.add(utf8.encode(body));
      final resp = await req.close();
      // 先收原始字节：文本/二进制统一处理，二进制（octet-stream）填 bytes
      final raw = await resp.fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk));
      final data = raw.takeBytes();
      final ct = resp.headers.contentType?.mimeType ?? '';
      final isBinary = ct == 'application/octet-stream' || ct.startsWith('image/') || ct.startsWith('audio/') || ct.startsWith('video/') || ct == 'application/pdf' || ct == 'application/zip';
      return TransportResponse(
        status: resp.statusCode,
        body: isBinary ? '' : utf8.decode(data, allowMalformed: true),
        setCookie: resp.headers[HttpHeaders.setCookieHeader] ?? const [],
        bytes: isBinary ? data : null,
      );
    } catch (e) {
      throw TransportException('direct/http-failed', '$e');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<TransportSocket> openSocket(String path, {Map<String, String> headers = const {}}) async {
    try {
      final ws = await WebSocket.connect(
        base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: path, query: null).toString(),
        headers: headers,
      );
      return _DirectSocket(ws);
    } catch (e) {
      throw TransportException('direct/ws-failed', '$e');
    }
  }

  @override
  Future<void> close() async {}
}

class _DirectSocket implements TransportSocket {
  final WebSocket _ws;
  _DirectSocket(this._ws);

  @override
  Stream<String> get messages => _ws.where((e) => e is String).cast<String>();

  @override
  void send(String text) => _ws.add(text);

  @override
  Future<void> close([int? code, String? reason]) => _ws.close(code, reason);
}

// ---------------------------------------------------------------------------
// 云端转发：连 relay（dsh-relay-v1 hello v2），经 dsh（手机通道插件）透明隧道访问 dsh web。
//
// 鉴权（hello v2）：
//   - 已配对重连：deviceId + token（设备令牌持久化在安全存储）；
//   - 首次配对：pairingCode（一次性，welcome.device 回发设备令牌需立即落盘）；
//   - code 仅作房间寻址（绑房间的配对码/令牌可省略）。
// ---------------------------------------------------------------------------
/// reject 码 → 人话文案（UI 直接展示 + 引导动作）
String relayRejectMessage(String code) {
  switch (code) {
    case 'auth-required':
      return '中继要求设备凭证：请扫码配对或输入配对码';
    case 'bad-token':
      return '设备令牌失效：请重新配对';
    case 'revoked':
      return '该设备已在管理台被吊销：请重新配对';
    case 'unknown-device':
      return '设备不存在：请重新配对';
    case 'pairing-invalid':
      return '配对码无效：请核对或重新生成';
    case 'pairing-expired':
      return '配对码已过期（10 分钟内有效）：请重新生成';
    case 'pairing-used':
      return '配对码已被使用：请重新生成';
    case 'pairing-burned':
      return '配对码错误次数过多已熔断：请重新生成';
    case 'room-mismatch':
      return '配对码与所选环境不符：请使用该环境生成的配对码';
    case 'role-mismatch':
      return '配对码角色不符（Host/手机需分别生成）';
    case 'rate-limited':
      return '尝试过于频繁：请稍后再试';
    case 'bad-code':
      return '房间码无效（至少 6 位）';
    case 'code':
      return '共享码校验失败（旧模式）';
    default:
      return '中继拒绝连接（$code）';
  }
}

/// 鉴权/凭据类拒绝：必须停掉自动重连（人工介入：重新配对/换码）
bool isAuthReject(String code) => const {
      'auth-required',
      'bad-token',
      'revoked',
      'unknown-device',
      'pairing-invalid',
      'pairing-expired',
      'pairing-used',
      'pairing-burned',
      'room-mismatch',
      'role-mismatch',
      'bad-code',
      'bad-hello',
      'bad-role',
      'code',
    }.contains(code);

class RelayTransport extends DshTransport {
  final Uri relay;

  @override
  Uri get downloadBase => relay;

  /// 房间码（寻址；带令牌/绑房间配对码时可为空）
  final String code;

  /// 已配对设备身份（与 token 成对；空=走 pairingCode 首配）
  final String deviceId;
  final String token;

  /// 首次配对一次性码（核销即失效）
  final String pairingCode;

  /// 设备名（管理台展示）
  final String name;

  /// 首次配对成功：welcome.device 回发一次性令牌，必须立即持久化
  final void Function(String id, String token)? onPaired;

  /// 鉴权类拒绝（自动重连已停止，UI 需引导重新配对）
  final void Function(String code, String message)? onAuthRejected;

  WebSocket? _ws;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  // 流式下载（大文件分块）：rid -> 字节 StreamController，http-res chunk 帧逐块喂
  final Map<String, StreamController<List<int>>> _streams = {};
  // 流式下载元数据回调：rid -> onMeta（contentLength，进度 total）
  final Map<String, void Function(int)?> _streamMeta = {};
  final Map<String, StreamController<String>> _sockets = {};
  final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();
  bool _closed = false;
  bool _authFailed = false;
  String? lastAuthError;

  /// 限流冷却：rate-limited 后在到期前 connect() 本地快速失败——
  /// 严禁把重连风暴喂进服务端限流窗口（活锁：越喂越限、越限越喂）
  DateTime? _retryNotBefore;

  // ---- v3 续传/批量 ----
  /// 已处理的最大下行 seq（重连 hello.resumeFrom 断点）
  int _lastSeq = 0;

  /// relay 是否收 batch 信封（welcome.batch 能力位）
  bool _relayBatch = false;

  /// 断线期隧道上行排队（重连后 flush；溢出拆流重建）
  final List<String> _outQueue = [];

  /// 闪断自动重连（隧道跨断线存活的前提）：单飞 + 指数退避
  Timer? _reconnectTimer;
  int _backoffMs = 1000;

  /// 配对成功后本实例持有的设备身份（供上层落盘后下次重连复用）
  String? pairedDeviceId;
  String? pairedToken;

  RelayTransport(
    this.relay, {
    this.code = '',
    this.deviceId = '',
    this.token = '',
    this.pairingCode = '',
    this.name = '',
    this.onPaired,
    this.onAuthRejected,
  });

  bool get isConnected => _ws != null;

  /// 鉴权拒绝后为 true：不再自动重拨（治 1/s 重连风暴）
  bool get authFailed => _authFailed;

  Future<void> connect() async {
    if (_ws != null) return;
    if (_authFailed) {
      throw TransportException('relay/${lastAuthError ?? 'auth'}', relayRejectMessage(lastAuthError ?? 'auth'));
    }
    final notBefore = _retryNotBefore;
    if (notBefore != null && DateTime.now().isBefore(notBefore)) {
      final secs = notBefore.difference(DateTime.now()).inSeconds.clamp(1, 3600);
      throw TransportException('relay/rate-limited', '尝试过于频繁：请 $secs 秒后重试');
    }
    final ws = await WebSocket.connect(
      relay.replace(scheme: relay.scheme == 'https' ? 'wss' : 'ws').toString(),
      protocols: const ['dsh-relay-v1'],
    );
    _ws = ws;
    ws.listen(
      (data) {
        // 旧 socket 迟到的帧不得进入当前传输（同设备顶替的 bye 竞态，见 _handleDisconnect）
        if (!identical(_ws, ws)) return;
        if (data is! String) return;
        Map<String, dynamic> frame;
        try {
          frame = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        _dispatch(frame);
      },
      onDone: () => _handleDisconnect(ws),
      onError: (_) => _handleDisconnect(ws),
      cancelOnError: true,
    );
    // hello v2：令牌重连 / 配对码首配走设备凭证，**必须省略 code**——
    // 服务端把 code 的哈希当房间主张，绑房间的配对码/设备记录才是权威
    // （发 room-id 当 code 会误触发 room-mismatch）。code 仅旧共享码模式用。
    final hello = <String, dynamic>{
      'type': 'hello',
      'role': 'client',
      if (name.isNotEmpty) 'name': name,
      'batch': true,
      'resumeFrom': _lastSeq,
    };
    final useToken = deviceId.isNotEmpty && token.isNotEmpty;
    if (useToken) {
      hello['deviceId'] = deviceId;
      hello['token'] = token;
    } else if (pairingCode.isNotEmpty) {
      hello['pairingCode'] = pairingCode;
    } else if (code.isNotEmpty) {
      hello['code'] = code;
    }
    ws.add(jsonEncode(hello));
    // 等 welcome / reject
    final verdict = await _events.stream
        .firstWhere((e) => e['type'] == 'welcome' || e['type'] == 'reject')
        .timeout(const Duration(seconds: 10), onTimeout: () => {'type': 'reject', 'code': 'auth-timeout'});
    if (verdict['type'] != 'welcome') {
      final c = '${verdict['code'] ?? 'rejected'}';
      final msg = relayRejectMessage(c);
      if (c == 'rate-limited') {
        // 尊重服务端 retryAfterSecs（缺省 30s）：冷却期内本地快速失败，不喂限流窗口。
        // 只拆连接不判死刑：冷却是暂态，实例保持可重用
        final hint = (verdict['retryAfterSecs'] as num?)?.toInt() ?? 0;
        _retryNotBefore = DateTime.now().add(Duration(seconds: hint > 0 ? hint : 30));
        final ws = _ws;
        _ws = null;
        try {
          await ws?.close();
        } catch (_) {}
        throw TransportException('relay/rate-limited', '尝试过于频繁：请稍后再试');
      }
      if (isAuthReject(c)) {
        _authFailed = true;
        lastAuthError = c;
        onAuthRejected?.call(c, msg);
      }
      await close();
      throw TransportException('relay/$c', msg);
    }
    // 首配回执：一次性设备令牌 → 立即持久化（onPaired 回调负责落盘）
    final dev = verdict['device'];
    if (dev is Map && dev['token'] is String && '${dev['token']}'.isNotEmpty) {
      pairedDeviceId = '${dev['id'] ?? ''}';
      pairedToken = '${dev['token']}';
      onPaired?.call(pairedDeviceId!, pairedToken!);
    }
    // v3：能力位 + 退避复位 + 断线期队列补发
    _relayBatch = verdict['batch'] == true;
    _backoffMs = 1000;
    _flushQueue();
  }

  /// 断线后惰性重拨（request/openSocket 先调用）；鉴权失败不重拨。
  Future<void> _ensureConnected() async {
    if (_ws != null) return;
    if (_closed) throw TransportException('relay/closed', '连接已关闭');
    await connect();
  }

  void _dispatch(Map<String, dynamic> frame) {
    // v3：推进续传断点（隧道帧带 seq；batch 内层递归同样计数）
    final seq = frame['seq'];
    if (seq is num && seq.toInt() > _lastSeq) _lastSeq = seq.toInt();
    switch (frame['type']) {
      case 'batch':
        // v3 批量信封：展开内层逐帧处理
        for (final s in (frame['frames'] as List? ?? const [])) {
          if (s is! String) continue;
          try {
            _dispatch(jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {}
        }
        return;
      case 'resume':
        // v3 续传判定：ok=false 断点不可满足（环溢出/重启）→ 旧隧道作废重建
        if (frame['ok'] != true) {
          for (final sc in _sockets.values) {
            if (!sc.isClosed) sc.addError(TransportException('relay/resume-reset', '中继续传断点失效，请重建连接'));
            sc.close();
          }
          _sockets.clear();
          _outQueue.clear();
        }
        return;
      case 'welcome':
      case 'reject':
      case 'peer':
      case 'ping':
        if (frame['type'] == 'ping') _ws?.add(jsonEncode({'type': 'pong', 't': frame['t']}));
        _events.add(frame);
        return;
      case 'http-res':
      case 'error':
        final rid = '${frame['rid']}';
        // 流式分块（下载大文件）：chunk 帧喂 StreamController，last 帧收尾（含 status）
        final sc = _streams[rid];
        if (sc != null && frame['type'] == 'http-res' && frame['chunk'] != null) {
          // 首块带 contentLength → 进度 total
          final cl = frame['contentLength'];
          if (cl is num) {
            final meta = _streamMeta.remove(rid);
            if (cl.toInt() > 0) meta?.call(cl.toInt());
          }
          try {
            sc.add(base64.decode('${frame['chunk']}'));
          } catch (_) {}
          // 背压 ack：确认收到块 → 桥滑动窗口推进
          _ws?.add(jsonEncode({'type': 'dl-ack', 'rid': rid}));
          if (frame['last'] == true) {
            _streams.remove(rid);
            sc.close();
          }
          return;
        }
        if (sc != null && frame['type'] == 'http-res' && frame['last'] == true) {
          _streams.remove(rid);
          sc.close();
          return;
        }
        final c = _pending.remove(rid);
        c?.complete(frame);
        return;
      case 'ws-frame':
        final sc = _sockets['${frame['rid']}'];
        final text = frame['text'];
        // 桥以 __open__ 哨兵帧确认隧道建立
        if (sc != null && text is String && text != '__open__') sc.add(text);
        return;
      case 'ws-close':
        final rid = '${frame['rid']}';
        final sc = _sockets.remove(rid);
        sc?.close();
        return;
    }
  }

  void _handleDisconnect([Object? source]) {
    if (_closed) return;
    // 旧 socket 迟到的 onDone/onError 不得拆掉当前传输：否则 _ws 被清空、在途 RPC
    // 全判「relay 连接断开」，且另起重连造成同设备顶替风暴（relay audit 实锤每秒 open/close）
    if (source != null && !identical(_ws, source)) return;
    _ws = null;
    // 请求/响应对语义不允许跨连接续传：立即失败。
    // 隧道流（mux）**保活**——闪断由自动重连 + 服务端回放无缝续流，上层无感
    for (final c in _pending.values) {
      c.complete({'type': 'error', 'code': 'relay/disconnected', 'message': 'relay 连接断开'});
    }
    _pending.clear();
    _scheduleReconnect();
  }

  /// 闪断自动重连（单飞）：指数退避；限流冷却按服务端提示顺延
  void _scheduleReconnect() {
    if (_closed || _authFailed || _reconnectTimer != null) return;
    _reconnectTimer = Timer(Duration(milliseconds: _backoffMs), () async {
      _reconnectTimer = null;
      if (_closed || _authFailed) return;
      try {
        await connect();
      } on TransportException catch (e) {
        if (e.code == 'relay/rate-limited') {
          final nb = _retryNotBefore;
          final waitMs = nb == null ? _backoffMs : nb.difference(DateTime.now()).inMilliseconds + 200;
          _backoffMs = waitMs.clamp(1000, 60000);
        } else {
          _backoffMs = (_backoffMs * 2).clamp(1000, 30000);
        }
        _scheduleReconnect();
      } catch (_) {
        _backoffMs = (_backoffMs * 2).clamp(1000, 30000);
        _scheduleReconnect();
      }
    });
  }

  /// 隧道帧上行：在线直发；断线排队（重连后补发，溢出拆流重建）
  void _sendTunnelFrame(Map<String, dynamic> frame) {
    final msg = jsonEncode(frame);
    final ws = _ws;
    if (ws != null) {
      ws.add(msg);
      return;
    }
    if (_closed) return;
    if (_outQueue.length < 512) {
      _outQueue.add(msg);
      return;
    }
    final rid = '${frame['rid']}';
    final sc = _sockets.remove(rid);
    sc?.addError(TransportException('relay/overflow', '断线缓冲溢出'));
    sc?.close();
  }

  void _flushQueue() {
    final ws = _ws;
    if (ws == null || _outQueue.isEmpty) return;
    // 断线积压补发天然是小帧风暴：支持 batch 时合并成一个 WS 消息
    if (_relayBatch && _outQueue.length > 1) {
      ws.add(jsonEncode({'type': 'batch', 'frames': List<String>.from(_outQueue)}));
    } else {
      for (final msg in _outQueue) {
        ws.add(msg);
      }
    }
    _outQueue.clear();
  }

  @override
  Future<TransportResponse> request(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    await _ensureConnected();
    final ws = _ws;
    if (ws == null) throw TransportException('relay/not-connected', '中继未连接');
    final rid = '${DateTime.now().microsecondsSinceEpoch}-${_pending.length}';
    final c = Completer<Map<String, dynamic>>();
    _pending[rid] = c;
    ws.add(jsonEncode({
      'type': 'http-req',
      'rid': rid,
      'method': method,
      'path': path,
      if (body != null) 'body': body,
      'headers': headers,
    }));
    final frame = await c.future.timeout(const Duration(seconds: 30));
    if (frame['type'] == 'error') {
      throw TransportException('${frame['code'] ?? 'relay/error'}', '${frame['message'] ?? ''}');
    }
    final setCookie = (frame['setCookie'] as List? ?? []).whereType<String>().toList();
    final isBinary = frame['binary'] == true;
    return TransportResponse(
      status: (frame['status'] as num? ?? 0).toInt(),
      body: isBinary ? '' : '${frame['body'] ?? ''}',
      setCookie: setCookie,
      bytes: isBinary ? base64.decode('${frame['body'] ?? ''}') : null,
    );
  }

  /// 流式下载（大文件经隧道分块）：发 stream:true 的 http-req，返回字节流。
  /// 桥逐块回 http-res chunk 帧，这里喂 StreamController。下载大 APK 不进内存。
  /// [onMeta] 收到首块 contentLength 时回调（进度 total）。
  Stream<List<int>> streamRequest(
    String method,
    String path, {
    Map<String, String> headers = const {},
    void Function(int contentLength)? onMeta,
  }) async* {
    await _ensureConnected();
    final ws = _ws;
    if (ws == null) throw TransportException('relay/not-connected', '中继未连接');
    final rid = '${DateTime.now().microsecondsSinceEpoch}-${_streams.length}';
    final controller = StreamController<List<int>>();
    _streams[rid] = controller;
    _streamMeta[rid] = onMeta;
    ws.add(jsonEncode({
      'type': 'http-req',
      'rid': rid,
      'method': method,
      'path': path,
      'headers': headers,
      'stream': true,
    }));
    yield* controller.stream;
  }

  @override
  Future<TransportSocket> openSocket(String path, {Map<String, String> headers = const {}}) async {
    await _ensureConnected();
    final ws = _ws;
    if (ws == null) throw TransportException('relay/not-connected', '中继未连接');
    final rid = '${DateTime.now().microsecondsSinceEpoch}-s${_sockets.length}';
    final sc = StreamController<String>();
    _sockets[rid] = sc;
    ws.add(jsonEncode({
      'type': 'ws-open',
      'rid': rid,
      'path': path,
      'headers': headers,
    }));
    return _RelaySocket(this, rid, sc);
  }

  void _closeSocket(String rid) {
    final sc = _sockets.remove(rid);
    sc?.close();
    _sendTunnelFrame({'type': 'ws-close', 'rid': rid});
  }

  @override
  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _outQueue.clear();
    _ws?.close();
    _ws = null;
    for (final sc in _sockets.values) {
      if (!sc.isClosed) sc.close();
    }
    _sockets.clear();
  }
}

class _RelaySocket implements TransportSocket {
  final RelayTransport _t;
  final String _rid;
  final StreamController<String> _sc;
  _RelaySocket(this._t, this._rid, this._sc);

  @override
  Stream<String> get messages => _sc.stream;

  @override
  void send(String text) => _t._sendTunnelFrame({'type': 'ws-frame', 'rid': _rid, 'text': text});

  @override
  Future<void> close([int? code, String? reason]) async => _t._closeSocket(_rid);
}
