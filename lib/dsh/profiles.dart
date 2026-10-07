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

  /// 环境去重键：云端转发 = relay 地址 + 房间码；局域网 = 地址。
  /// 同键视为同一环境（重复扫码/粘贴不应产生新环境）。
  static String dedupKeyOf(EnvProfile e) {
    String norm(String s) =>
        s.trim().replaceAll(RegExp(r'/+$'), '').toLowerCase();
    return e.mode == 1
        ? 'r:${norm(e.relay)}|${e.roomCode.trim()}'
        : 'l:${norm(e.url)}';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mode': mode,
    'url': url,
    // 敏感码恒不进 SharedPreferences JSON（历史存量由 fromJson 迁入安全存储，
    // 下次 save 起清零）
    'lanCode': '',
    'relay': relay,
    'roomCode': roomCode,
    'pairingCode': '',
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

  static String _lanCodeKey(String profileId) => 'prof.lanCode.$profileId';

  static String _pairCodeKey(String profileId) => 'prof.pairCode.$profileId';

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
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => EnvProfile.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final hydrated = await dedupe(list);
      // 敏感码（安全码/一次性配对码）不在 SharedPreferences JSON 里，
      // 从安全存储回填。存储为空时保留 fromJson 解析出的存量明文值——
      // 否则无重复环境的常规用户升级后码即被空值静默清空（直连 401）；
      // 检出存量明文则 load 末尾立即 save 完成一次性迁移（写入安全存储
      // 并把 JSON 明文清掉，toJson 恒空）。
      // per-key try：单个 key 抛 PlatformException（Keystore 失效/备份恢复
      // 后常见）只按空串处理，不得让整个环境列表「消失」。
      var migrated = false;
      for (final e in hydrated) {
        final lan = await _readCode(_lanCodeKey(e.id));
        final pair = await _readCode(_pairCodeKey(e.id));
        if (lan.isNotEmpty) e.lanCode = lan;
        if (pair.isNotEmpty) e.pairingCode = pair;
        if ((lan.isEmpty && e.lanCode.isNotEmpty) ||
            (pair.isEmpty && e.pairingCode.isNotEmpty)) {
          migrated = true;
        }
      }
      if (migrated) await save(hydrated);
      return hydrated;
    } catch (_) {
      return [];
    }
  }

  /// 单 key 安全读取：失败按空串（对齐 tokenOf 的防御；Keystore 异常不放大）
  static Future<String> _readCode(String key) async {
    try {
      return await _secure.read(key: key) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 去重：同键环境只留一条（优先保留已配对的），被丢弃项清理设备令牌并回写。
  /// 存量版本重复扫码会堆积完全相同的环境，升级后首次加载即清扫。
  static Future<List<EnvProfile>> dedupe(List<EnvProfile> list) async {
    final kept = <String, EnvProfile>{};
    final drop = <EnvProfile>[];
    for (final e in list) {
      final key = EnvProfile.dedupKeyOf(e);
      final cur = kept[key];
      if (cur == null) {
        kept[key] = e;
      } else if (e.paired && !cur.paired) {
        kept[key] = e;
        drop.add(cur);
      } else {
        drop.add(e);
      }
    }
    if (drop.isEmpty) return list;
    for (final d in drop) {
      await clearToken(d.id);
      // 丢弃环境一并清安全码/一次性配对码
      await _secure.delete(key: _lanCodeKey(d.id));
      await _secure.delete(key: _pairCodeKey(d.id));
    }
    final result = list.where((e) => !drop.contains(e)).toList();
    await save(result);
    return result;
  }

  static Future<void> save(List<EnvProfile> profiles) async {
    final p = await SharedPreferences.getInstance();
    // 敏感码不进 SharedPreferences（明文 JSON，root/备份可读）：与设备令牌
    // 一致进安全存储；JSON 里恒写空串
    for (final e in profiles) {
      try {
        if (e.lanCode.isEmpty) {
          await _secure.delete(key: _lanCodeKey(e.id));
        } else {
          await _secure.write(key: _lanCodeKey(e.id), value: e.lanCode);
        }
        // 一次性配对码：核销后调用方清空字段 → 这里同步删除
        if (e.pairingCode.isEmpty) {
          await _secure.delete(key: _pairCodeKey(e.id));
        } else {
          await _secure.write(key: _pairCodeKey(e.id), value: e.pairingCode);
        }
      } catch (_) {
        /* 平台不支持安全存储：码不落盘，下次重输/重扫 */
      }
    }
    await p.setString(
      _kProfiles,
      jsonEncode(profiles.map((e) => e.toJson()).toList()),
    );
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
    } catch (_) {
      /* 平台不支持安全存储时静默：下次重新配对 */
    }
  }

  /// 清除设备身份（重新配对）
  static Future<void> clearToken(String profileId) async {
    try {
      await _secure.delete(key: _tokenKey(profileId));
    } catch (_) {}
  }

  /// 清除环境的敏感码（删除环境时调用；对齐 dedupe「丢弃即清」语义，
  /// 防止 prof.lanCode/pairCode 孤儿键残留安全存储——第二轮审查 #917）
  static Future<void> clearCodes(String profileId) async {
    try {
      await _secure.delete(key: _lanCodeKey(profileId));
    } catch (_) {}
    try {
      await _secure.delete(key: _pairCodeKey(profileId));
    } catch (_) {}
  }
}
