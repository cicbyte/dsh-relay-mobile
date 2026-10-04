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

/// 起后台保活前台服务（常驻低优先级通知，进程不被冻结）。失败静默（false）。
Future<bool> keepAliveStart() async {
  try {
    return await _deviceChannel.invokeMethod<bool>('keepAliveStart') ?? false;
  } catch (_) {
    return false;
  }
}

/// 停后台保活。失败静默。
Future<void> keepAliveStop() async {
  try {
    await _deviceChannel.invokeMethod<bool>('keepAliveStop');
  } catch (_) {}
}

/// 请求电池优化白名单（一次性系统弹窗；部分国产 ROM 另需手动允许自启动）。
Future<void> requestBatteryExemption() async {
  try {
    await _deviceChannel.invokeMethod<bool>('requestBatteryExemption');
  } catch (_) {}
}

/// 后台事件通知（回答完成/需要确认）：高优先级通道，点开直达 App。
/// 携 sessionId 时点开直达对应会话页。前台时不要调用（UI 内已呈现）。失败静默。
Future<void> notifyEvent(String title, String text, {String? sessionId}) async {
  try {
    await _deviceChannel.invokeMethod<bool>('notifyEvent', {
      'title': title,
      'text': text,
      if (sessionId != null) 'sessionId': sessionId,
    });
  } catch (_) {}
}

/// 更新保活常驻通知为运行中进度（系统秒表从 chronometerStartMs 实时走字，
/// 无需反复刷新）；前台服务没在跑时原生侧静默忽略。回前台/回合结束传
/// 复位文案（chronometerStartMs=0 关秒表）。
Future<void> keepAliveUpdate(
  String title,
  String text, {
  String? sessionId,
  int chronometerStartMs = 0,
}) async {
  try {
    await _deviceChannel.invokeMethod<bool>('keepAliveUpdate', {
      'title': title,
      'text': text,
      if (sessionId != null) 'sessionId': sessionId,
      'chronometerStartMs': chronometerStartMs,
    });
  } catch (_) {}
}

/// 原生事件（通知点开直达会话页等）。app_shell 初始化时注册一次。
void setDshNativeEventHandler(
  Future<void> Function(String method, Map<dynamic, dynamic> args)? handler,
) {
  _eventChannel.setMethodCallHandler(
    handler == null
        ? null
        : (call) async {
            final args = call.arguments as Map?;
            await handler(call.method, args ?? const {});
          },
  );
}

const MethodChannel _eventChannel = MethodChannel('dsh/notify');
