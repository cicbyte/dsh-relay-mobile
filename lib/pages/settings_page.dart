import 'package:flutter/material.dart';

import '../dsh/dsh_client.dart';
import '../dsh/transport.dart';
import '../theme.dart';
import 'connect_page.dart';

/// 设置中枢（分组卡片式）：
///   连接 → 连接设置子页（push）
///   外观 → 皮肤 A/C 选择卡（走皮肤令牌体系，双皮肤自适配）
///   关于 → 版本/协议
///
/// 拓展方式：在 ListView 里按 `_section('标题', [...])` 追加分组或条目即可，
/// 分组容器/条目样式全部吃 ThemeData + SkinTokens，新皮肤自动适配。
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
          _section(context, '连接', [
            _tile(
              context,
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
          ]),

          // ── 外观（皮肤）──
          _section(context, '外观', [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: _skinCard(context, DshSkin.darkGlass),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: _skinCard(context, DshSkin.brandSplash),
            ),
          ]),

          // ── 拓展位：新分组在此追加（通知 / 存储 / 调试 …）──
          _section(context, '关于', [
            _tile(context,
                icon: Icons.info_outline,
                title: '版本',
                trailing: const _ValueText('1.0.0+1')),
            Divider(height: 1, indent: 56, color: Theme.of(context).colorScheme.outlineVariant),
            _tile(context,
                icon: Icons.hub_outlined,
                title: '协议',
                trailing: const _ValueText('WS v3 · 恢复/批量/序号')),
          ]),
        ],
      ),
    );
  }

  /// 分组卡片：标题 + 圆角容器（装饰吃主题，双皮肤自适配）。
  Widget _section(BuildContext context, String title, List<Widget> children) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
            child: Text(title,
                style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
          ),
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  /// 设置条目：左图标 + 标题/副标题 + 右侧值或箭头。
  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.bodyLarge),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ]),
      ),
    );
  }

  /// 皮肤选择卡：点按即时换肤 + 落盘（与抽屉原快捷切换同一机制）。
  Widget _skinCard(BuildContext context, DshSkin skin) {
    return ValueListenableBuilder<DshSkin>(
      valueListenable: skinNotifier,
      builder: (context, current, _) {
        final theme = Theme.of(context);
        final selected = current == skin;
        final accent = theme.colorScheme.primary;
        return Material(
          color: selected
              ? accent.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              skinNotifier.value = skin;
              SkinStore.save(skin);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: selected ? accent : theme.colorScheme.outlineVariant,
                    width: selected ? 1.5 : 1),
              ),
              child: Row(children: [
                Icon(
                  skin == DshSkin.darkGlass
                      ? Icons.dark_mode_outlined
                      : Icons.wb_sunny_outlined,
                  size: 20,
                  color: selected ? accent : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(skin.label,
                            style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w400)),
                        const SizedBox(height: 2),
                        Text(
                          skin == DshSkin.darkGlass
                              ? '深空蓝渐变 · 玻璃质感 · 蓝青辉光'
                              : '品牌渐变顶栏 · 白卡大圆角 · 柔和投影',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ]),
                ),
                if (selected) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check_circle, color: accent, size: 20),
                ],
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _ValueText extends StatelessWidget {
  const _ValueText(this.value);
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(value,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant));
  }
}
