import 'package:flutter/services.dart';

/// 设备信息（平台通道）。
const MethodChannel _deviceChannel = MethodChannel('dsh/device');

String? _timeZoneIdCache;

/// IANA 时区 ID（如 Asia/Shanghai）；不可用时返回 null。
///
/// Dart 的 `DateTime.now().timeZoneName` 只有 CST 这类缩写，会被
/// session/prompt 拒绝（session/invalid-time-zone），必须经原生取。
Future<String?> deviceTimeZoneId() async {
  if (_timeZoneIdCache != null) return _timeZoneIdCache;
  try {
    final id = await _deviceChannel.invokeMethod<String>('timeZoneId');
    if (id != null && id.isNotEmpty) _timeZoneIdCache = id;
    return _timeZoneIdCache;
  } catch (_) {
    return null;
  }
}

/// 把 app 私有目录里的已下载文件保存到系统「下载」目录（平台通道，仅 Android）。
/// Android 10+ 走 MediaStore 免权限；更早回退公共 Downloads（无权限会抛错）。
/// 返回保存位置描述；失败抛 PlatformException（调用方提示）。
Future<String> saveFileToDownloads(String path, String name) async {
  final loc = await _deviceChannel.invokeMethod<String>('saveToDownloads', {
    'path': path,
    'name': name,
  });
  return loc ?? '';
}
