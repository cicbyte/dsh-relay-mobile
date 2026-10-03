import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 后台保活开关（全局通知者）：连接期间挂前台服务常驻通知，
/// Android 不冻结进程——切后台 relay/mux 连接照常跑，消息与交互实时到达。
/// 启动时由 [KeepAliveStore.load] 修正初值（默认开）。
final keepAliveNotifier = ValueNotifier<bool>(true);

/// 后台保活偏好持久化（SharedPreferences，key=conn.keepAlive）。
class KeepAliveStore {
  static const _k = 'conn.keepAlive';

  static Future<bool> load() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_k) ?? true; // 默认开：切后台仍工作是用户预期基线
  }

  static Future<void> save(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_k, v);
  }
}

/// 连接配置（持久化）。
class ConnConfig {
  /// 0 = 局域网直连，1 = 云端转发。
  final int mode;
  final String url; // 直连服务地址
  final String relay; // relay 地址
  final String code; // 配对码

  const ConnConfig({
    this.mode = 0,
    this.url = 'http://127.0.0.1:3080',
    this.relay = 'ws://127.0.0.1:8787',
    this.code = '',
  });
}

/// 连接配置与上次会话的本地持久化（SharedPreferences）。
///
/// 目标：重装/重启后不用每次手配——启动即用上次的配置自动重连，
/// 连上后自动打开上次的会话。
class ConnStore {
  static const _kMode = 'conn.mode';
  static const _kUrl = 'conn.url';
  static const _kRelay = 'conn.relay';
  static const _kCode = 'conn.code';
  static const _kLastSession = 'conn.lastSessionId';

  static Future<ConnConfig?> loadConfig() async {
    final p = await SharedPreferences.getInstance();
    final mode = p.getInt(_kMode);
    if (mode == null) return null;
    return ConnConfig(
      mode: mode,
      url: p.getString(_kUrl) ?? 'http://127.0.0.1:3080',
      relay: p.getString(_kRelay) ?? 'ws://127.0.0.1:8787',
      code: p.getString(_kCode) ?? '',
    );
  }

  static Future<void> saveConfig(ConnConfig c) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kMode, c.mode);
    await p.setString(_kUrl, c.url);
    await p.setString(_kRelay, c.relay);
    await p.setString(_kCode, c.code);
  }

  static Future<String?> lastSessionId() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kLastSession);
  }

  static Future<void> saveLastSessionId(String sessionId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLastSession, sessionId);
  }
}
