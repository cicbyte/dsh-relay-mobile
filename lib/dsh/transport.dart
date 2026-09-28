import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  Future<void> close();
}

class TransportResponse {
  final int status;
  final String body;
  final List<String> setCookie;
  TransportResponse({required this.status, required this.body, this.setCookie = const []});
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
      final text = await resp.transform(utf8.decoder).join();
      return TransportResponse(
        status: resp.statusCode,
        body: text,
        setCookie: resp.headers[HttpHeaders.setCookieHeader] ?? const [],
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
// 云端转发：连 relay（dsh-relay-v1 hello v2），经主端（手机通道插件）透明隧道访问 dsh web。
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
  final Map<String, StreamController<String>> _sockets = {};
  final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();
  bool _closed = false;
  bool _authFailed = false;
  String? lastAuthError;

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
    final ws = await WebSocket.connect(
      relay.replace(scheme: relay.scheme == 'https' ? 'wss' : 'ws').toString(),
      protocols: const ['dsh-relay-v1'],
    );
    _ws = ws;
    ws.listen(
      (data) {
        if (data is! String) return;
        Map<String, dynamic> frame;
        try {
          frame = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        _dispatch(frame);
      },
      onDone: _handleDisconnect,
      onError: (_) => _handleDisconnect(),
      cancelOnError: true,
    );
    // hello v2：令牌重连 / 配对码首配走设备凭证，**必须省略 code**——
    // 服务端把 code 的哈希当房间主张，绑房间的配对码/设备记录才是权威
    // （发 room-id 当 code 会误触发 room-mismatch）。code 仅旧共享码模式用。
    final hello = <String, dynamic>{
      'type': 'hello',
      'role': 'client',
      if (name.isNotEmpty) 'name': name,
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
  }

  /// 断线后惰性重拨（request/openSocket 先调用）；鉴权失败不重拨。
  Future<void> _ensureConnected() async {
    if (_ws != null) return;
    if (_closed) throw TransportException('relay/closed', '连接已关闭');
    await connect();
  }

  void _dispatch(Map<String, dynamic> frame) {
    switch (frame['type']) {
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

  void _handleDisconnect() {
    if (_closed) return;
    _ws = null;
    for (final c in _pending.values) {
      c.complete({'type': 'error', 'code': 'relay/disconnected', 'message': 'relay 连接断开'});
    }
    _pending.clear();
    for (final sc in _sockets.values) {
      sc.addError(TransportException('relay/disconnected', 'relay 连接断开'));
      sc.close();
    }
    _sockets.clear();
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
    return TransportResponse(status: (frame['status'] as num? ?? 0).toInt(), body: '${frame['body'] ?? ''}', setCookie: setCookie);
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
    _ws?.add(jsonEncode({'type': 'ws-close', 'rid': rid}));
  }

  @override
  Future<void> close() async {
    _closed = true;
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
  void send(String text) => _t._ws?.add(jsonEncode({'type': 'ws-frame', 'rid': _rid, 'text': text}));

  @override
  Future<void> close([int? code, String? reason]) async => _t._closeSocket(_rid);
}
