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
