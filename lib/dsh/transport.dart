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
      if (body != null) req.write(body);
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
// 云端转发：连 relay（dsh-relay-v1），经桌面桥透明隧道访问 dsh web
// 帧协议见 relay/server.mjs 注释。
// ---------------------------------------------------------------------------
class RelayTransport extends DshTransport {
  final Uri relay;
  final String code;
  WebSocket? _ws;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final Map<String, StreamController<String>> _sockets = {};
  final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();
  bool _closed = false;

  RelayTransport(this.relay, {required this.code});

  bool get isConnected => _ws != null;

  Future<void> connect() async {
    if (_ws != null) return;
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
    ws.add(jsonEncode({'type': 'hello', 'role': 'client', 'code': code}));
    // 等 welcome / reject
    final verdict = await _events.stream
        .firstWhere((e) => e['type'] == 'welcome' || e['type'] == 'reject')
        .timeout(const Duration(seconds: 10), onTimeout: () => {'type': 'reject', 'code': 'auth-timeout'});
    if (verdict['type'] != 'welcome') {
      final c = '${verdict['code'] ?? 'rejected'}';
      await close();
      throw TransportException('relay/$c', 'relay 拒绝连接（检查配对码/角色冲突）');
    }
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
    final ws = _ws;
    if (ws == null) throw TransportException('relay/not-connected', '请先 connect()');
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
    final ws = _ws;
    if (ws == null) throw TransportException('relay/not-connected', '请先 connect()');
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
