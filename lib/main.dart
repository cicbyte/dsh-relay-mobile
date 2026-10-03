import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'dsh/conn_store.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final skin = await SkinStore.load();
  keepAliveNotifier.value = await KeepAliveStore.load(); // 后台保活偏好（默认开）
  runApp(DshMobileApp(initialSkin: skin));
}

/// 皮肤状态（全局单例，声明在 theme.dart）：抽屉切换器写这里，MaterialApp 监听重建。

/// 全局 ScaffoldMessenger：下载面板被关掉后，后台下载完成/失败的通知
/// 没有局部 context 可用，统一从这里发（App 任意位置可见）。
final rootMessengerKey = GlobalKey<ScaffoldMessengerState>();

class DshMobileApp extends StatelessWidget {
  const DshMobileApp({super.key, this.initialSkin = DshSkin.darkGlass});

  final DshSkin initialSkin;

  @override
  Widget build(BuildContext context) {
    skinNotifier.value = initialSkin;
    return ValueListenableBuilder<DshSkin>(
      valueListenable: skinNotifier,
      builder: (context, skin, _) {
        final theme = DshTheme.of(skin);
        return MaterialApp(
          title: 'DSH Mobile',
          debugShowCheckedModeBanner: false,
          theme: theme,
          scaffoldMessengerKey: rootMessengerKey,
          // 换肤走颜色补间（ThemeData + SkinTokens 全量 lerp）：~240ms 平滑过渡，杜绝闪屏。
          builder: (context, child) => AnimatedTheme(
            data: theme,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const AppRoot(),
        );
      },
    );
  }
}
