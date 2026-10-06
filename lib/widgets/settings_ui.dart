/// 设置体系公共组件：分组卡片 + 条目行（设置页/外观页等共用，装饰吃主题自适配）。
library;

import 'package:flutter/material.dart';

/// 分组卡片：标题 + 圆角容器。
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
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
}

/// 条目行：左图标 + 标题/副标题 + 右侧值/控件。
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.bodyLarge),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                // 副标题允许两行：长提示换行呈现，不靠省略号丢信息
                Text(subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ]),
      ),
    );
  }
}

/// 「值 + ›」尾件（iOS 式进子页）。
class SettingsValueLink extends StatelessWidget {
  const SettingsValueLink({super.key, required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(value,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: color)),
      Icon(Icons.chevron_right, size: 20, color: color),
    ]);
  }
}

/// 分隔线（条目之间，缩进对齐文字列）。
Widget settingsDivider(BuildContext context) => Divider(
    height: 1, indent: 56, color: Theme.of(context).colorScheme.outlineVariant);
