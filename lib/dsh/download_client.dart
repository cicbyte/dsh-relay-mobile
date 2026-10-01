import 'dart:io';

/// 流式下载客户端（方案 C 直连 / B relay 代理通用）：用 dart:io HttpClient 逐块写盘，
/// 大文件（APK 等）不进内存，支持进度回调 + Range 断点续传。
///
/// 直连（局域网）与 relay 代理（外网）对本类是同一套代码，只是 [base] 不同：
///   直连 base = 宿主 dsh web 地址；relay 代理 base = relay HTTP 地址。
class DownloadClient {
  final Uri base;
  DownloadClient(this.base);

  Uri _dlUri(String downloadId, String deviceId) => base.replace(
        path: '/mobile-bridge/dl/$downloadId',
        query: 'd=${Uri.encodeComponent(deviceId)}',
      );

  /// 流式下载到 [destFile]。支持断点续传（文件已存在则 Range 从断点续）。
  /// [onProgress](received, total)：total 未知时为 -1。返回是否完整下载。
  /// [streamSource]：隧道流式字节流（RelayTransport.streamRequest）；为空则走直连 HttpClient。
  Future<bool> fetchToFile(
    String downloadId,
    String deviceId,
    File destFile, {
    void Function(int received, int total)? onProgress,
    Stream<List<int>>? streamSource,
  }) async {
    // 隧道流式：逐块写盘，断点续传靠本地已有 offset（隧道暂不支持 Range，追加写）
    if (streamSource != null) {
      IOSink? sink;
      try {
        int offset = destFile.existsSync() ? destFile.lengthSync() : 0;
        sink = destFile.openWrite(mode: FileMode.append);
        int received = offset;
        await for (final chunk in streamSource) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, -1);
        }
        await sink.flush();
        return true;
      } catch (_) {
        return false;
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
