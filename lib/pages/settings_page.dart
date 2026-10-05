import 'package:flutter/material.dart';

import '../device_info.dart';
import '../dsh/conn_store.dart';
import '../dsh/dsh_client.dart';
import '../dsh/transport.dart';
import '../theme.dart';
import '../widgets/settings_ui.dart';
import 'appearance_page.dart';
import 'connect_page.dart';

/// 设置中枢（分组卡片式）：
///   连接 → 连接设置子页（push）
///   外观 → 外观子页（主题四选一 + 拓展位）
///   关于 → 版本/协议
///
/// 拓展方式：按 `SettingsSection('标题', [...])` 追加分组或条目即可，
/// 全部吃 ThemeData + SkinTokens，新皮肤自动适配。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.onConnected,
    required this.onOpenDrawer,
    this.modeLabel = '未连接',
    this.connected = false,
  });

  /// 与 ConnectPage 同型：连接成功回调（transport 所有权移交 AppRoot）。
  final Future<void> Function({
    required DshTransport transport,
    required DshClient client,
    required String modeLabel,
  }) onConnected;
  final VoidCallback onOpenDrawer;

  /// 「连接」条目副标题（当前连接方式/环境）。
  final String modeLabel;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Builder(builder: skinFlexibleSpace),
        leading: IconButton(icon: const Icon(Icons.menu), onPressed: onOpenDrawer),
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          // ── 连接 ──
          SettingsSection(
            title: '连接',
            children: [
              SettingsTile(
                icon: Icons.link,
                title: '连接设置',
                subtitle: connected ? modeLabel : '未连接 · 点此配置入网',
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ConnectPage(
                      onConnected: onConnected,
                      onOpenDrawer: onOpenDrawer,
                    ),
                  ));
                },
              ),
              // 后台保活（前台服务）：开关即时生效（AppRoot 监听 keepAliveNotifier）
              ValueListenableBuilder<bool>(
                valueListenable: keepAliveNotifier,
                builder: (context, v, _) => SettingsTile(
                  icon: Icons.bolt_outlined,
                  title: '后台保持连接',
                  subtitle: '切后台仍实时收消息/交互（常驻低优先级通知）',
                  trailing: Switch(
                    value: v,
                    onChanged: (nv) async {
                      keepAliveNotifier.value = nv;
                      await KeepAliveStore.save(nv);
                    },
                  ),
                ),
              ),
              SettingsTile(
                icon: Icons.battery_saver_outlined,
                title: '电池优化白名单',
                subtitle: '减少系统杀后台；部分国产 ROM 另需允许自启动',
                trailing: const Icon(Icons.chevron_right),
                onTap: requestBatteryExemption,
              ),
            ],
          ),

          // ── 外观 ──
          SettingsSection(
            title: '外观',
            children: [
              ValueListenableBuilder<DshSkin>(
                valueListenable: skinNotifier,
                builder: (context, current, _) => SettingsTile(
                  icon: Icons.palette_outlined,
                  title: '主题',
                  subtitle: current.desc,
                  trailing: SettingsValueLink(value: current.short),
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const AppearancePage(),
                    ));
                  },
                ),
              ),
            ],
          ),

          // ── 拓展位：新分组在此追加（通知 / 存储 / 调试 …）──
          SettingsSection(
            title: '关于',
            children: [
              SettingsTile(
                icon: Icons.info_outline,
                title: '版本',
                trailing: _value(context, '1.4.9'),
              ),
              settingsDivider(context),
              SettingsTile(
                icon: Icons.hub_outlined,
                title: '协议',
                trailing: _value(context, 'WS v3 · 恢复/批量/序号'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _value(BuildContext context, String text) => Text(text,
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant));
}
