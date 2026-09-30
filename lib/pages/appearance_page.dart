import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/settings_ui.dart';

/// 外观子页：主题四选一（色板 + 名称 + 描述 + 勾选，单选行全展开零挤压）。
/// 拓展位：字号 / 消息密度 / 动效等外观项在此追加。
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Builder(builder: skinFlexibleSpace),
        title: const Text('外观'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          SettingsSection(
            title: '主题',
            children: [
              for (final s in DshSkin.values) _skinRow(context, s),
            ],
          ),
          // ── 拓展位：字号 / 密度 / 动效 … ──
        ],
      ),
    );
  }

  Widget _skinRow(BuildContext context, DshSkin skin) {
    return ValueListenableBuilder<DshSkin>(
      valueListenable: skinNotifier,
      builder: (context, current, _) {
        final theme = Theme.of(context);
        final selected = current == skin;
        final accent = theme.colorScheme.primary;
        return InkWell(
          onTap: () {
            skinNotifier.value = skin;
            SkinStore.save(skin);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              _Swatch(skin.swatch),
              const SizedBox(width: 14),
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
                      Text(skin.desc,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ]),
              ),
              if (selected) ...[
                const SizedBox(width: 10),
                Icon(Icons.check_circle, color: accent, size: 22),
              ],
            ]),
          ),
        );
      },
    );
  }
}

/// 迷你色板：底色圆角块 + 右下角强调色点。
class _Swatch extends StatelessWidget {
  const _Swatch(this.colors);

  final ({Color bg, Color accent}) colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 32,
      decoration: BoxDecoration(
        color: colors.bg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0x26000000)),
      ),
      child: Align(
        alignment: Alignment.bottomRight,
        child: Container(
          width: 16,
          height: 16,
          margin: const EdgeInsets.all(4),
          decoration:
              BoxDecoration(color: colors.accent, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
