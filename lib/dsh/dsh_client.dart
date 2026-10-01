import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'transport.dart';

/// DSH 服务端协议客户端（传输层可插拔：直连 / 云端转发）。
///
/// 协议三通道：
///  1. 一元 RPC：POST /api/<namespace>/<method>，封套
///     {"type":"client-request","rpcId":uuid,"method":endpoint,"payload":{"args":{...}}}
///     → {"type":"server-response","rpcId":...,"result":{"ok":true,"value":...}|{"ok":false,"error":...}}
///  2. 流式 RPC：/api/remote.mux 多路复用
///     客户端 {"type":"open","streamId",endpoint,"payload":{"args":{...}}} / {"type":"cancel","streamId"}
///     服务端 {"type":"item","streamId","value"} / {"type":"error","streamId","error"} / {"type":"end","streamId"}
///  3. 鉴权：GET /?token=<launchToken>（不跟随 303）换 dsh-auth-* cookie，之后全部请求带 Cookie。
///
/// 信任栅栏要求 Host 为 loopback 或 trustedHosts——直连走 adb reverse、
/// 云端转发走 dsh（手机通道插件；桥对本机 dsh 固定 Host=loopback），都无需额外配置；
/// 不要发送 Origin / sec-fetch-site 头。

class DshRpcException implements Exception {
  final String code;
  final String message;
  DshRpcException(this.code, this.message);
  @override
  String toString() => 'DshRpcException($code): $message';
}

String _uuid() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class DshClient {
  final DshTransport transport;
  String? cookie;

  DshClient(this.transport, {this.cookie});

  Map<String, String> get _authHeaders => {if (cookie != null) 'cookie': cookie!};

  /// token 换签名 cookie。从 Set-Cookie 取 dsh-auth-*。
  Future<String> authorize(String token) async {
    final resp = await transport.request('GET', '/?token=${Uri.encodeComponent(token)}');
    final auth = resp.setCookie.firstWhere(
      (c) => c.toLowerCase().startsWith('dsh-auth-'),
      orElse: () => '',
    );
    if (auth.isEmpty) {
      throw DshRpcException('auth/failed', 'token 无效或已过期：未收到 dsh-auth cookie');
    }
    cookie = auth.split(';').first;
    return cookie!;
  }

  /// 一元 RPC。[endpoint] 形如 "session/list"；[args] 为 payload.args 的内容。
  Future<Map<String, dynamic>> rpc(String endpoint, Map<String, dynamic> args) async {
    final v = await rpcValue(endpoint, args);
    return Map<String, dynamic>.from(v is Map ? v : const {});
  }

  /// 零手工令牌：经隧道向桥要本机 dsh launch token（手机通道插件的环回限定路由）。
  /// 插件旧版本/路由不可用时返回 ''，调用方回退手动输入。
  Future<String> fetchLaunchToken() async {
    try {
      final resp = await transport.request('GET', '/mobile-bridge/launch-token');
      if (resp.status != 200 || resp.body.isEmpty) return '';
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (j['code'] == 200 && j['result'] is Map) {
        return '${j['result']['token'] ?? ''}';
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  /// 工作区快速路径（环回限定，经隧道）：{ quick: [...], roots: [...], platform, home }。
  /// 插件旧版本/路由不可用返回 null，调用方回退默认工作区。
  Future<Map<String, dynamic>?> workspaceRoots() async {
    try {
      final resp = await transport.request('GET', '/mobile-bridge/workspace-roots');
      if (resp.status != 200 || resp.body.isEmpty) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (j['code'] == 200 && j['result'] is Map) {
        return Map<String, dynamic>.from(j['result']);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 列子目录（环回限定，经隧道）：{ ok, path, parent, dirs: [{path,label}] }。
  /// [showHidden] 为 true 时含点开头目录。失败返回 null。
  Future<Map<String, dynamic>?> workspaceList(String dir, {bool showHidden = false, bool withFiles = false}) async {
    try {
      final q = Uri(
        path: '/mobile-bridge/workspace-list',
        queryParameters: {
          'path': dir,
          if (showHidden) 'hidden': '1',
          if (withFiles) 'files': '1',
        },
      ).toString();
      final resp = await transport.request('GET', q);
      if (resp.status != 200 || resp.body.isEmpty) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (j['code'] == 200 && j['result'] is Map) {
        return Map<String, dynamic>.from(j['result']);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 流式下载的可达 HTTP base（直连=宿主 / 隧道=relay）。
  Uri get downloadBase => transport.downloadBase;

  /// 创建附件下载链接（设备绑定、默认 30min、上限 7 天）：{ downloadId, expiresAt, ttl }。
  /// [deviceId] 经 x-device-id 头绑定（方案 A，不进链接明文）。失败返回 null。
  /// [workspaceRoot] 为当前会话 cwd——桥端只放行「工作区池 + 全局池」内文件。
  Future<Map<String, dynamic>?> dlCreate(String filePath,
      {int? expiresInSec, required String deviceId, String? workspaceRoot}) async {
    try {
      final resp = await transport.request(
        'POST',
        '/mobile-bridge/dl-create',
        headers: {'content-type': 'application/json; charset=utf-8', 'x-device-id': deviceId},
        body: jsonEncode({
          'path': filePath,
          if (expiresInSec != null) 'expiresInSec': expiresInSec,
          'deviceId': deviceId,
          if (workspaceRoot != null && workspaceRoot.isNotEmpty) 'workspaceRoot': workspaceRoot,
        }),
      );
      if (resp.status != 200 || resp.body.isEmpty) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (j['code'] == 200 && j['result'] is Map) {
        return Map<String, dynamic>.from(j['result']);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 下载文件字节（设备绑定，app 内拉取）。返回文件字节，失败返回 null。
  Future<List<int>?> dlFetch(String downloadId, String deviceId) async {
    try {
      final q = Uri(
        path: '/mobile-bridge/dl/$downloadId',
        queryParameters: {'d': deviceId},
      ).toString();
      final resp = await transport.request('GET', q, headers: {'x-device-id': deviceId});
      if (resp.status != 200) return null;
      return resp.bytes;
    } catch (_) {
      return null;
    }
  }

  /// 隧道流式下载字节流（大文件经分块）。仅隧道传输有效；直连返回 null（走 DownloadClient HttpClient）。
  /// [offset] 本地断点（>0 时发 Range 续传，桥转发 range 头、dsh 侧回 206）。
  /// [onMeta] 首块元数据（contentLength, status）：206 时 contentLength=剩余长度。
  Stream<List<int>>? dlStream(String downloadId, String deviceId,
      {int offset = 0, void Function(int contentLength, int status)? onMeta}) {
    final q = Uri(
      path: '/mobile-bridge/dl/$downloadId',
      queryParameters: {'d': deviceId},
    ).toString();
    try {
      return (transport as dynamic).streamRequest('GET', q, headers: {
        'x-device-id': deviceId,
        if (offset > 0) 'range': 'bytes=$offset-',
      }, onMeta: onMeta) as Stream<List<int>>;
    } catch (_) {
      return null;
    }
  }

  /// 下载池列表：{ items: [{name,path,size,mtime,pool}], workspace, global }。
  /// [workspaceRoot] 为当前会话 cwd（空则只有全局池）。插件旧版本返回 null。
  Future<Map<String, dynamic>?> dlPool({String? workspaceRoot}) async {
    try {
      final q = Uri(
        path: '/mobile-bridge/dl-pool',
        queryParameters: {
          if (workspaceRoot != null && workspaceRoot.isNotEmpty) 'workspace': workspaceRoot,
        },
      ).toString();
      final resp = await transport.request('GET', q);
      if (resp.status != 200 || resp.body.isEmpty) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (j['code'] == 200 && j['result'] is Map) {
        return Map<String, dynamic>.from(j['result']);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 添加文件入下载池（复制，原文件保留）：返回 { name, path, size, mtime, pool }。
  /// [toWorkspace] 为 true 时入工作区池（需 [workspaceRoot]），否则入全局池。失败返回 null。
  Future<Map<String, dynamic>?> dlStage(String filePath,
      {required String deviceId, String? workspaceRoot, required bool toWorkspace}) async {
    try {
      final resp = await transport.request(
        'POST',
        '/mobile-bridge/dl-stage',
        headers: {'content-type': 'application/json; charset=utf-8', 'x-device-id': deviceId},
        body: jsonEncode({
          'path': filePath,
          'deviceId': deviceId,
          'target': toWorkspace ? 'workspace' : 'global',
          if (workspaceRoot != null && workspaceRoot.isNotEmpty) 'workspaceRoot': workspaceRoot,
        }),
      );
      if (resp.status != 200 || resp.body.isEmpty) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (j['code'] == 200 && j['result'] is Map) {
        return Map<String, dynamic>.from(j['result']);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 删除下载池内文件。[fromWorkspace] 为 true 时删工作区池（需 [workspaceRoot]）。
  Future<bool> dlPoolDelete(String name,
      {required String deviceId, String? workspaceRoot, required bool fromWorkspace}) async {
    try {
      final resp = await transport.request(
        'POST',
        '/mobile-bridge/dl-pool-delete',
        headers: {'content-type': 'application/json; charset=utf-8', 'x-device-id': deviceId},
        body: jsonEncode({
          'name': name,
          'pool': fromWorkspace ? 'workspace' : 'global',
          'deviceId': deviceId,
          if (workspaceRoot != null && workspaceRoot.isNotEmpty) 'workspaceRoot': workspaceRoot,
        }),
      );
      if (resp.status != 200 || resp.body.isEmpty) return false;
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      return j['code'] == 200;
    } catch (_) {
      return false;
    }
  }

  /// 列出有效下载链接（管理页）：{ items: [...] }。
  Future<Map<String, dynamic>?> dlList() async {
    try {
      final resp = await transport.request('GET', '/mobile-bridge/dl-list');
      if (resp.status != 200 || resp.body.isEmpty) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (j['code'] == 200 && j['result'] is Map) {
        return Map<String, dynamic>.from(j['result']);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 撤销下载链接。成功返回 true。
  Future<bool> dlRevoke(String downloadId) async {
    try {
      final resp = await transport.request(
        'POST',
        '/mobile-bridge/dl-revoke',
        headers: {'content-type': 'application/json; charset=utf-8'},
        body: jsonEncode({'downloadId': downloadId}),
      );
      if (resp.status != 200 || resp.body.isEmpty) return false;
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      return j['code'] == 200;
    } catch (_) {
      return false;
    }
  }

  /// 一元 RPC，返回原始 result.value（数组等非对象形状的端点用这个）。
  Future<dynamic> rpcValue(String endpoint, Map<String, dynamic> args) async {
    final body = jsonEncode({
      'type': 'client-request',
      'rpcId': _uuid(),
      'method': endpoint,
      'payload': {'args': args},
    });
    final resp = await transport.request(
      'POST',
      '/api/$endpoint',
      headers: {'content-type': 'application/json; charset=utf-8', ..._authHeaders},
      body: body,
    );
    if (resp.status == 401) {
      // 401 体是纯文本 unauthorized——先于 JSON 解码判出，给可行动的提示
      throw DshRpcException('auth/required', '未授权：请填 launch token（dsh 行配置页「扫码接入」的安全码）后重连');
    }
    if (resp.body.isEmpty) {
      throw DshRpcException('http/${resp.status}', '空响应（多半是 cookie 失效或 Host 未被信任）');
    }
    final msg = jsonDecode(resp.body) as Map<String, dynamic>;
    final result = msg['result'] as Map<String, dynamic>?;
    if (result == null) {
      throw DshRpcException('protocol/bad-response', '响应缺少 result 字段: ${resp.body}');
    }
    if (result['ok'] != true) {
      final err = Map<String, dynamic>.from(result['error'] ?? {});
      throw DshRpcException('${err['code'] ?? 'unknown'}', '${err['message'] ?? ''}');
    }
    return result['value'];
  }

  // ---- 业务便捷方法（wire 参数名与服务端描述符严格一致）----

  /// session/list：wire 参数名是 _request（不是 request）。
  Future<Map<String, dynamic>> sessionList({String? cursor}) => rpc('session/list', {
        '_request': {if (cursor != null) 'cursor': cursor},
      });

  Future<String> sessionCreate({String? cwd}) async {
    final v = await rpc('session/create', {
      'request': {if (cwd != null) 'cwd': cwd},
    });
    return '${v['sessionId']}';
  }

  /// clientTimeZone 必须是 UTC 或 IANA Area/Location（如 Asia/Shanghai），
  /// Dart 的 timeZoneName 是 CST 这类缩写，服务端会拒（session/invalid-time-zone）；
  /// 由调用方经平台通道取（lib/widgets 起的 device_info.dart），取不到就不传。
  Future<void> sessionPrompt(String sessionId, String text,
      {String mode = 'queue', String? clientTimeZone}) async {
    await rpc('session/prompt', {
      'request': {
        'requestId': _uuid(),
        'sessionId': sessionId,
        'mode': mode,
        'content': [
          {'type': 'text', 'text': text},
        ],
        if (clientTimeZone != null) 'clientTimeZone': clientTimeZone,
      },
    });
  }

  Future<void> sessionCancel(String sessionId) =>
      rpc('session/cancel', {
        'request': {'sessionId': sessionId}
      });

  /// subagents/list：父会话的子代理目录
  /// → {entries:[{kind:'child',id,mode,label?,activity,hasChildren}], parentAvailable}。
  Future<Map<String, dynamic>> subagentList(String parentSessionId) =>
      rpc('subagents/list', {'parentSessionId': parentSessionId});

  /// subagents/prompt：向 continuable 子代理发消息（one-shot 不可发）。
  /// 带附件发消息：content = [text?|image|file] 块数组（对齐桌面 serializeAttachments）。
  /// 图片块 {type:image, mediaType, data(base64), name?}；
  /// 文件块 {type:file, receiptId, name?}（先 fileUploads/upload 拿收据）。
  Future<void> sessionPromptBlocks(
    String sessionId,
    List<Map<String, dynamic>> content, {
    String mode = 'queue',
    String? clientTimeZone,
  }) async {
    await rpc('session/prompt', {
      'request': {
        'requestId': _uuid(),
        'sessionId': sessionId,
        'mode': mode,
        'content': content,
        if (clientTimeZone != null) 'clientTimeZone': clientTimeZone,
      },
    });
  }

  /// 上传附件 → {receiptId, file:{attachmentId,name,bytes}}（data=base64；
  /// args 为 agentId + request 包裹，与 commands/execute 同族）。
  Future<Map<String, dynamic>> uploadFile(
          String sessionId, String name, List<int> bytes) =>
      rpc('fileUploads/upload', {
        'agentId': sessionId,
        'request': {'data': base64Encode(bytes), 'name': name},
      });

  /// 斜杠命令目录（commands/list；args=agentId 平铺）→ [{name, description,
  /// input?: {hint, attachments?}}]，name 小写无斜杠。
  Future<List<dynamic>> commandList(String sessionId) async {
    final v = await rpcValue('commands/list', {'agentId': sessionId});
    return v is List ? v : const [];
  }

  /// @引用候选：文件/目录（fileReferences/list；args=agentId+query 平铺）。
  /// 每项 {path, kind: 'file'|'directory'}。
  Future<List<dynamic>> fileReferenceCandidates(String sessionId, String query) async {
    final v = await rpcValue('fileReferences/list',
        {'agentId': sessionId, 'query': query});
    return v is List ? v : const [];
  }

  /// @引用候选：会话（sessionReferenceResolver/candidates；args=agentId+query）。
  /// 每项 {mention, sessionId, label, cwd?, sameWorkspace, createdAt}——
  /// mention 即规范 `@[label](dsh-session:<base64url id>)`，原样插入即可。
  Future<List<dynamic>> sessionReferenceCandidates(
      String sessionId, String query) async {
    final v = await rpcValue('sessionReferenceResolver/candidates',
        {'agentId': sessionId, 'query': query});
    return v is List ? v : const [];
  }

  /// 队列项编辑（对齐桌面 QueueDock → session/updateQueue，request 包裹）。
  /// [action] 三选一：{kind:'remove'} 撤回 / {kind:'steer'} 立即执行 /
  /// {kind:'edit', content:[blocks]} 改写。返回 {accepted:true}。
  Future<Map<String, dynamic>> updateQueue(
          String sessionId, String itemId, Map<String, dynamic> action) =>
      rpc('session/updateQueue', {
        'request': {'sessionId': sessionId, 'itemId': itemId, 'action': action}
      });

  /// 模型目录：{default,routableProviders,groups:[{id,name,models:[...]}],failures}。
  Future<Map<String, dynamic>> modelCatalog() => rpc('session/modelCatalog', {});

  /// 切换模型（对齐桌面 ModelSelect → session/selectModel；args 为 request 包裹）。
  Future<Map<String, dynamic>> selectModel(
          String sessionId, String provider, String model) =>
      rpc('session/selectModel', {
        'request': {
          'sessionId': sessionId,
          'provider': provider,
          'model': model,
        }
      });

  /// 会话投影（session/control）：queues/inbox/model/goal/title/todos 等。
  Future<Map<String, dynamic>> sessionControl(String sessionId) =>
      rpc('session/control', {'sessionId': sessionId});

  Future<void> subagentPrompt({
    required String parentSessionId,
    required String childSessionId,
    required String text,
    String delivery = 'queue',
    String? clientTimeZone,
  }) =>
      rpc('subagents/prompt', {
        'requestId': _uuid(),
        'parentSessionId': parentSessionId,
        'childSessionId': childSessionId,
        'mode': 'continuable',
        'delivery': delivery,
        'content': [
          {'type': 'text', 'text': text}
        ],
        if (clientTimeZone != null) 'clientTimeZone': clientTimeZone,
      });

  /// subagents/interruptByParent：父会话中断 continuable 子代理。
  Future<void> subagentInterrupt({
    required String parentSessionId,
    required String childSessionId,
  }) =>
      rpc('subagents/interruptByParent', {
        'childSessionId': childSessionId,
        'parentSessionId': parentSessionId,
        'mode': 'continuable',
      });
}

/// SessionAddress：普通会话 `{kind:'session', sessionId}`；
/// subagent 会话 `{kind:'subagent', parentSessionId, childSessionId, mode}`。
Map<String, dynamic> sessionAddress({
  required String sessionId,
  String? parentSessionId,
  String mode = 'one-shot',
}) {
  if (parentSessionId == null || parentSessionId.isEmpty) {
    return {'kind': 'session', 'sessionId': sessionId};
  }
  return {
    'kind': 'subagent',
    'parentSessionId': parentSessionId,
    'childSessionId': sessionId,
    'mode': mode,
  };
}

/// remote.mux 多路复用流客户端（传输层无关）。
class DshMux {
  final DshClient client;
  TransportSocket? _sock;
  final Map<String, StreamController<Map<String, dynamic>>> _streams = {};
  bool _closed = false;
  bool _reconnecting = false;

  /// 断线自动重连成功后的回调（上层用于自动重订阅逻辑流）。
  void Function()? onReconnected;

  DshMux(this.client);

  bool get isConnected => _sock != null;

  Future<void> connect() async {
    // 直连模式下 DSH 服务端每 2s 发 WS Ping、连续 2 次未回 Pong 即 terminate
    // （dsh-api-gateway MAX_MISSED_HEARTBEATS=2）；dart:io 自动回 Pong，但主 isolate
    // 被大快照阻塞会延迟应答——消费侧控制单帧工作量（maxMessages 不宜过大）。
    // 云端转发模式下 ping/pong 由 dsh（手机通道）就地应答，手机链路另有 relay 自己的心跳。
    final sock = await client.transport.openSocket(
      '/api/remote.mux',
      headers: {if (client.cookie != null) 'cookie': client.cookie!},
    );
    _sock = sock;
    sock.messages.listen(
      (data) {
        Map<String, dynamic> msg;
        try {
          msg = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        final sid = '${msg['streamId']}';
        final ctrl = _streams[sid];
        switch (msg['type']) {
          case 'item':
            ctrl?.add(Map<String, dynamic>.from(msg['value'] as Map));
          case 'error':
            final err = Map<String, dynamic>.from(msg['error'] as Map? ?? {});
            ctrl?.addError(DshRpcException('${err['code'] ?? 'stream'}', '${err['message'] ?? ''}'));
          case 'end':
            _streams.remove(sid);
            ctrl?.close();
        }
      },
      onDone: _handleDisconnect,
      onError: (_) => _handleDisconnect(),
      cancelOnError: true,
    );
  }

  void _handleDisconnect() {
    if (_closed) return;
    _sock = null;
    for (final c in _streams.values) {
      if (!c.isClosed) c.addError(DshRpcException('mux/disconnected', '流通道断开'));
    }
    _streams.clear();
    // 单飞重连：3s 后自动重连一次，成功后通知上层重订阅
    if (!_reconnecting) {
      _reconnecting = true;
      Timer(const Duration(seconds: 3), () async {
        _reconnecting = false;
        if (_closed || _sock != null) return;
        try {
          await connect();
          onReconnected?.call();
        } catch (_) {/* 上层展示错误并提供手动重试 */}
      });
    }
  }

  /// 打开一条逻辑流。[endpoint] 形如 "session/follow"。
  Stream<Map<String, dynamic>> open(String endpoint, Map<String, dynamic> args) {
    final sock = _sock;
    if (sock == null) {
      return Stream.error(DshRpcException('mux/not-connected', '请先 connect()'));
    }
    final sid = _uuid();
    final ctrl = StreamController<Map<String, dynamic>>();
    _streams[sid] = ctrl;
    ctrl.onCancel = () {
      if (_streams.remove(sid) != null && _sock != null) {
        _sock!.send(jsonEncode({'type': 'cancel', 'streamId': sid}));
      }
    };
    sock.send(jsonEncode({
      'type': 'open',
      'streamId': sid,
      'endpoint': endpoint,
      'payload': {'args': args},
    }));
    return ctrl.stream;
  }

  void close() {
    _closed = true;
    _sock?.close();
    _sock = null;
    for (final c in _streams.values) {
      if (!c.isClosed) c.close();
    }
    _streams.clear();
  }
}

/// ---- 会话域的松散模型（wire 形状，渲染友好）----

class SessionSummary {
  final String sessionId;
  final String title;
  final bool running;
  final bool blank;
  final String? cwd;
  final String? parentSessionId;
  final String? origin;
  final int? updatedAt;

  SessionSummary({
    required this.sessionId,
    required this.title,
    required this.running,
    required this.blank,
    this.cwd,
    this.parentSessionId,
    this.origin,
    this.updatedAt,
  });

  factory SessionSummary.fromJson(Map<String, dynamic> j) {
    // projections.values 是开放键集；title 是 string|null，缺失=未生成
    String title = '';
    final projections = j['projections'] as Map<String, dynamic>?;
    final values = projections?['values'] as Map<String, dynamic>?;
    final t = values?['title'];
    if (t is String && t.isNotEmpty) title = t;
    return SessionSummary(
      sessionId: '${j['sessionId']}',
      title: title,
      running: j['running'] == true,
      blank: j['blank'] == true,
      cwd: j['cwd'] != null ? '${j['cwd']}' : null,
      parentSessionId: j['parentSessionId'] != null ? '${j['parentSessionId']}' : null,
      origin: j['origin'] != null ? '${j['origin']}' : null,
      updatedAt: j['updatedAt'] is num ? (j['updatedAt'] as num).toInt() : null,
    );
  }
}

/// 一条会话历史记录（follow snapshot.records / page.records 元素）。
class WireRecord {
  final String type;
  final int seq;
  final int time;
  final Map<String, dynamic> data;

  /// 协议噪声标记（快照 event.ignorable）：渲染层可直接过滤。
  final bool ignorable;

  WireRecord({
    required this.type,
    required this.seq,
    required this.time,
    required this.data,
    this.ignorable = false,
  });

  /// 元素形如 {"type":"event","event":{type,seq,time,data,ignorable}}。
  factory WireRecord.fromJson(Map<String, dynamic> j) {
    final e = Map<String, dynamic>.from(j['event'] as Map? ?? j);
    return WireRecord(
      type: '${e['type'] ?? j['type'] ?? 'unknown'}',
      seq: (e['seq'] as num? ?? 0).toInt(),
      time: (e['time'] as num? ?? 0).toInt(),
      data: Map<String, dynamic>.from(e['data'] as Map? ?? {}),
      ignorable: e['ignorable'] == true,
    );
  }
}
