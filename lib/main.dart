import 'package:flutter/material.dart';

import 'app_shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final skin = await SkinStore.load();
  runApp(DshMobileApp(initialSkin: skin));
}

/// 皮肤状态（全局单例，声明在 theme.dart）：抽屉切换器写这里，MaterialApp 监听重建。

class DshMobileApp extends StatelessWidget {
  const DshMobileApp({super.key, this.initialSkin = DshSkin.darkGlass});

  final DshSkin initialSkin;

  @override
  Widget build(BuildContext context) {
    skinNotifier.value = initialSkin;
    return ValueListenableBuilder<DshSkin>(
      valueListenable: skinNotifier,
      builder: (context, skin, _) {
        return MaterialApp(
          title: 'DSH Mobile',
          debugShowCheckedModeBanner: false,
          theme: DshTheme.of(skin),
          home: const AppRoot(),
        );
      },
    );
  }
}
