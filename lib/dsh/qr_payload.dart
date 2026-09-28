/// 扫码入网 payload 解析。
///
/// 两种二维码（桌面 dsh web / relay 管理台生成）：
///   `dshrelay[s]://<host>:<port>/?pair=<一次性配对码>&room=<房间hex8>&name=<环境名>`
///   `dshlan://<ip>:<port>/?code=<安全码>&name=<环境名>`
class QrTarget {
  /// true = 云端转发；false = 局域网直连
  final bool relay;

  /// 转发：ws(s)://host:port；局域网：http://ip:port
  final String addr;
  final String pairCode;
  final String room;
  final String lanCode;
  final String name;

  const QrTarget({
    required this.relay,
    required this.addr,
    this.pairCode = '',
    this.room = '',
    this.lanCode = '',
    this.name = '',
  });
}

QrTarget? parseQrPayload(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final uri = Uri.tryParse(s);
  if (uri == null) return null;
  switch (uri.scheme) {
    case 'dshrelay':
    case 'dshrelays':
      final host = uri.host;
      if (host.isEmpty) return null;
      final port = uri.hasPort ? uri.port : 8787;
      final secure = uri.scheme == 'dshrelays';
      return QrTarget(
        relay: true,
        addr: '${secure ? 'wss' : 'ws'}://$host:$port',
        pairCode: uri.queryParameters['pair'] ?? '',
        room: uri.queryParameters['room'] ?? '',
        name: _decode(uri.queryParameters['name'] ?? ''),
      );
    case 'dshlan':
      final host = uri.host;
      if (host.isEmpty) return null;
      final port = uri.hasPort ? uri.port : 3080;
      return QrTarget(
        relay: false,
        addr: 'http://$host:$port',
        lanCode: uri.queryParameters['code'] ?? '',
        name: _decode(uri.queryParameters['name'] ?? ''),
      );
    default:
      return null;
  }
}

String _decode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}
