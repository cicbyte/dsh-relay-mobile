import 'dart:io';

/// 隧道流工厂：按本地断点 [offset] 构造字节流；onMeta 回调 (contentLength, status)——
/// 200=全文长度 / 206=剩余长度 / 416=本地已完整 / ≥400=错误。
typedef StreamFactory = Stream<List<int>>? Function(
    int offset, void Function(int contentLength, int status) onMeta);

/// 流式下载客户端（方案 C 直连 / B relay 代理通用）：用 dart:io HttpClient 逐块写盘，
/// 大文件（APK 等）不进内存，支持进度回调 + Range 断点续传。
///
/// 直连（局域网）与 relay 代理（外网）对本类是同一套代码，只是 [base] 不同：
///   直连 base = 宿主 dsh web 地址；relay 代理 base = relay HTTP 地址。
/// 两路都支持断点续传：直连走 HttpClient Range；隧道走 [streamFactory] 的
/// offset→Range→206 追加写（桥转发 range 头，meta 帧带 status 判定续传/覆盖/完成/失败）。
class DownloadClient {
  final Uri base;
  DownloadClient(this.base);

  Uri _dlUri(String downloadId, String deviceId) => base.replace(
        path: '/mobile-bridge/dl/$downloadId',
        query: 'd=${Uri.encodeComponent(deviceId)}',
      );

  /// 流式下载到 [destFile]。支持断点续传（本地已有部分 → Range 从断点续）。
  /// [onProgress](received, total)：total 未知时为 -1。返回是否完整下载。
  /// [streamFactory]：隧道流式字节流工厂（RelayTransport.streamRequest）；
  /// 为空则走直连 HttpClient。
  /// [cancelled]：取消探测（循环内轮询）；取消/失败都返回 false，
  /// 已写部分保留在 [destFile] 供下次断点续传——由调用方区分取消与失败。
  Future<bool> fetchToFile(
    String downloadId,
    String deviceId,
    File destFile, {
    void Function(int received, int total)? onProgress,
    StreamFactory? streamFactory,
    bool Function()? cancelled,
  }) async {
    // 隧道流式：Range 断点续传（本地 offset → range 头 → 206 追加写）。
    // meta 帧先于任何数据块到达：status 决定写模式——206 追加 / 200 覆盖 /
    // 416 本地已完整（true）/ ≥400 失败（false，流空结束不挂死）。
    // 断线时已写部分保留，下次续传从新 offset 接着写。
    if (streamFactory != null) {
      IOSink? sink;
      try {
        final offset = destFile.existsSync() ? destFile.lengthSync() : 0;
        int status = 0;
        int total = -1;
        bool failed = false;
        final stream = streamFactory(offset, (cl, st) {
          status = st;
          total = st == 206 ? offset + cl : cl;
          if (st >= 400) failed = true;
        });
        if (stream == null) return false;
        int received = 0;
        await for (final chunk in stream) {
          if (cancelled?.call() == true) return false; // 取消：保留断点
          if (failed || status == 416) break; // 空/立即结束，不写盘
          if (sink == null) {
            // 206=服务端从断点续（追加）；200/无 meta（老桥）=从头（覆盖，防错位）
            final resume = status == 206 && offset > 0;
            sink = destFile.openWrite(mode: resume ? FileMode.append : FileMode.write);
            received = resume ? offset : 0;
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        if (status == 416) return true; // 起点越界 = 本地已完整
        if (failed) return false; // 错误响应（过期/设备不匹配等）
        await sink?.flush();
        return true;
      } catch (_) {
        return false; // 断线：保留已写部分，下次断点续传
      } finally {
        try {
          await sink?.close();
        } catch (_) {}
      }
    }

    // 直连 HttpClient：Range 断点续传
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      final req = await client.getUrl(_dlUri(downloadId, deviceId));
      req.headers.set('x-device-id', deviceId);

      // 断点续传：本地已有部分 → Range 从断点续
      int offset = 0;
      if (destFile.existsSync()) offset = destFile.lengthSync();
      if (offset > 0) req.headers.set('range', 'bytes=$offset-');

      final resp = await req.close();
      // 416 = 起点越界（文件已完整），按已完成处理
      if (resp.statusCode == 416) return true;
      // 206=续传 / 200=全新；其余状态码失败
      if (resp.statusCode != 200 && resp.statusCode != 206) return false;

      // 206 续传追加写；200 全新覆盖写
      sink = destFile.openWrite(mode: resp.statusCode == 206 ? FileMode.append : FileMode.write);

      final total = resp.contentLength < 0 ? -1 : resp.contentLength + offset;
      int received = offset;
      await for (final chunk in resp) {
        if (cancelled?.call() == true) return false; // 取消：保留断点
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }
}
