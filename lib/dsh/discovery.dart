import 'dart:async';

import 'package:nsd/nsd.dart';

/// 局域网自动发现（mDNS/NSD `_dsh._tcp`）。
///
/// 桌面侧（dsh web / 桥）广播服务实例；手机扫描出候选设备列表，
/// 点选后把 ip:port 落成「局域网环境」。
class LanService {
  final String name;
  final String host;
  final int port;
  const LanService({required this.name, required this.host, required this.port});

  /// dsh web 基址（http）
  String get url => 'http://$host:$port';

  @override
  String toString() => '$name ($host:$port)';
}

/// 发现会话：listen 即开始，cancel 即释放（页面 dispose 必须取消）。
Stream<LanService> discoverLanServices({Duration timeout = const Duration(seconds: 12)}) {
  final ctrl = StreamController<LanService>();
  Discovery? discovery;
  Timer? timer;
  final seen = <String>{};

  () async {
    try {
      discovery = await startDiscovery('_dsh._tcp', ipLookupType: IpLookupType.v4);
      void pump() {
        for (final s in discovery!.services) {
          final host = s.host;
          if (host == null || s.port == null) continue;
          final key = '$host:${s.port}';
          if (seen.add(key)) {
            ctrl.add(LanService(name: '${s.name ?? ''}', host: host, port: s.port!));
          }
        }
      }

      discovery!.addListener(pump);
      timer = Timer(timeout, () async {
        if (!ctrl.isClosed) await ctrl.close();
      });
      pump();
    } catch (e) {
      if (!ctrl.isClosed) {
        ctrl.addError(e);
        await ctrl.close();
      }
    }
  }();

  ctrl.onCancel = () async {
    timer?.cancel();
    final d = discovery;
    if (d != null) {
      try {
        await stopDiscovery(d);
      } catch (_) {}
    }
  };
  return ctrl.stream;
}
