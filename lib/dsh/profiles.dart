import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conn_store.dart';

/// 环境 Profile：一个可切换的连接目标（家里/公司/…）。
///
/// 双模式四入网方式共用此模型：
/// - 局域网直连（mode=0）：url + 安全码（lanCode），发现/扫码/手输均落到这里；
/// - 云端转发（mode=1）：relay + 房间码（roomCode，寻址可空）+ 配对/令牌身份。
///
/// 设备令牌是长效凭证，进 flutter_secure_storage（Android Keystore/iOS
/// Keychain）；其余元数据随 SharedPreferences 的 JSON 列表持久化。
class EnvProfile {
  String id;
  String name;

  /// 0 = 局域网直连，1 = 云端转发
  int mode;

  // ---- 局域网 ----
  String url; // http://ip:port
  String lanCode; // 安全码

  // ---- 云端转发 ----
  String relay; // ws(s)://host:port
  String roomCode; // 房间码（寻址；绑房间的配对码/令牌可省）
  String pairingCode; // 一次性配对码（用后清空）

  /// 设备身份（令牌在安全存储，键 `dev.token.<id>`）
  String deviceId;
  String lastError;
  int lastConnectedAt;

  EnvProfile({
    required this.id,
    required this.name,
    this.mode = 1,
    this.url = 'http://127.0.0.1:3080',
    this.lanCode = '',
    this.relay = 'ws://127.0.0.1:8787',
    this.roomCode = '',
    this.pairingCode = '',
    this.deviceId = '',
    this.lastError = '',
    this.lastConnectedAt = 0,
  });

  bool get isRelay => mode == 1;

  /// 是否已有设备身份（转发模式下=已配对）
  bool get paired => deviceId.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mode': mode,
        'url': url,
        'lanCode': lanCode,
        'relay': relay,
        'roomCode': roomCode,
        'pairingCode': pairingCode,
        'deviceId': deviceId,
        'lastError': lastError,
        'lastConnectedAt': lastConnectedAt,
      };

  static EnvProfile fromJson(Map<String, dynamic> j) => EnvProfile(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        mode: (j['mode'] as num? ?? 1).toInt(),
        url: '${j['url'] ?? 'http://127.0.0.1:3080'}',
        lanCode: '${j['lanCode'] ?? ''}',
        relay: '${j['relay'] ?? 'ws://127.0.0.1:8787'}',
        roomCode: '${j['roomCode'] ?? ''}',
        pairingCode: '${j['pairingCode'] ?? ''}',
        deviceId: '${j['deviceId'] ?? ''}',
        lastError: '${j['lastError'] ?? ''}',
        lastConnectedAt: (j['lastConnectedAt'] as num? ?? 0).toInt(),
      );
}

/// 环境列表 + 活动环境 + 设备令牌的安全持久化。
class ProfileStore {
  static const _kProfiles = 'env.profiles';
  static const _kActive = 'env.activeId';
  static const _secure = FlutterSecureStorage();

  static String _tokenKey(String profileId) => 'dev.token.$profileId';

  static Future<List<EnvProfile>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kProfiles);
    if (raw == null || raw.isEmpty) {
      // 一次性迁移：旧单配置（ConnStore）→ 默认环境
      final legacy = await ConnStore.loadConfig();
      if (legacy == null) return [];
      final prof = EnvProfile(
        id: 'default',
        name: '默认环境',
        mode: legacy.mode,
        url: legacy.url,
        relay: legacy.relay,
        roomCode: legacy.code,
      );
      await save([prof]);
      await setActive(prof.id);
      return [prof];
    }
    try {
      final list = (jsonDecode(raw) as List).whereType<Map>().map((e) => EnvProfile.fromJson(Map<String, dynamic>.from(e))).toList();
      return list;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<EnvProfile> profiles) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kProfiles, jsonEncode(profiles.map((e) => e.toJson()).toList()));
  }

  static Future<String?> activeId() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kActive);
  }

  static Future<void> setActive(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kActive, id);
  }

  /// 读设备令牌（安全存储；可能因换机/清库缺失 → 视为未配对）
  static Future<String?> tokenOf(String profileId) async {
    if (profileId.isEmpty) return null;
    try {
      return await _secure.read(key: _tokenKey(profileId));
    } catch (_) {
      return null;
    }
  }

  /// 落盘一次性设备令牌（配对成功/轮换后立即调用）
  static Future<void> saveToken(String profileId, String token) async {
    if (profileId.isEmpty) return;
    try {
      await _secure.write(key: _tokenKey(profileId), value: token);
    } catch (_) {/* 平台不支持安全存储时静默：下次重新配对 */}
  }

  /// 清除设备身份（重新配对）
  static Future<void> clearToken(String profileId) async {
    try {
      await _secure.delete(key: _tokenKey(profileId));
    } catch (_) {}
  }
}
