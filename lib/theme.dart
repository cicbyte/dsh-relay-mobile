import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 皮肤（换皮不换布局）：
///   A 深空玻璃 Dark Glass —— 深空蓝渐变底 + 玻璃卡 + 蓝→青辉光
///   C 鲸蓝 Brand Splash —— 品牌渐变顶栏/抽屉 + 白卡大圆角 + 带色投影
enum DshSkin { darkGlass, brandSplash }

extension DshSkinMeta on DshSkin {
  String get label => switch (this) {
        DshSkin.darkGlass => 'A · 深空玻璃',
        DshSkin.brandSplash => 'C · 鲸蓝',
      };

  String get short => switch (this) {
        DshSkin.darkGlass => 'A',
        DshSkin.brandSplash => 'C',
      };
}

/// 皮肤令牌：ThemeData 表达不了的视觉（渐变 / 玻璃面 / 描边 / 专用圆角）。
/// 页面只读令牌取装饰，布局一律不动。
class SkinTokens extends ThemeExtension<SkinTokens> {
  const SkinTokens({
    required this.name,
    required this.appbarGradient,
    required this.drawerGradient,
    required this.composerFill,
    required this.composerBorder,
    required this.composerRadius,
    required this.fieldRadius,
    required this.cardRadius,
    required this.userBubbleGradient,
    required this.glowColor,
  });

  final String name;

  /// 顶栏渐变（null=纯色，吃 AppBarTheme.backgroundColor）
  final Gradient? appbarGradient;

  /// 抽屉面板渐变（null=纯色）
  final Gradient? drawerGradient;

  /// 输入卡填充 / 描边（null=无描边）
  final Color composerFill;
  final Color? composerBorder;
  final double composerRadius;
  final double fieldRadius;
  final double cardRadius;

  /// 用户气泡渐变（null=纯色 primary）
  final Gradient? userBubbleGradient;

  /// 主操作投影色（null=无彩色投影）
  final Color? glowColor;

  @override
  SkinTokens copyWith({
    String? name,
    Gradient? appbarGradient,
    Gradient? drawerGradient,
    Color? composerFill,
    Color? composerBorder,
    double? composerRadius,
    double? fieldRadius,
    double? cardRadius,
    Gradient? userBubbleGradient,
    Color? glowColor,
  }) {
    return SkinTokens(
      name: name ?? this.name,
      appbarGradient: appbarGradient ?? this.appbarGradient,
      drawerGradient: drawerGradient ?? this.drawerGradient,
      composerFill: composerFill ?? this.composerFill,
      composerBorder: composerBorder ?? this.composerBorder,
      composerRadius: composerRadius ?? this.composerRadius,
      fieldRadius: fieldRadius ?? this.fieldRadius,
      cardRadius: cardRadius ?? this.cardRadius,
      userBubbleGradient: userBubbleGradient ?? this.userBubbleGradient,
      glowColor: glowColor ?? this.glowColor,
    );
  }

  @override
  SkinTokens lerp(ThemeExtension<SkinTokens>? other, double t) => this;
}

class DshTheme {
  static ThemeData of(DshSkin skin) => switch (skin) {
        DshSkin.darkGlass => _darkGlass(),
        DshSkin.brandSplash => _brandSplash(),
      };
}

ThemeData _darkGlass() {
  const c = _AColors();
  final scheme = ColorScheme.fromSeed(
    seedColor: c.primary,
    brightness: Brightness.dark,
  ).copyWith(
    primary: c.primary,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFF24365E),
    onPrimaryContainer: const Color(0xFFD9E4FF),
    secondary: c.secondary,
    onSecondary: Colors.white,
    surface: c.surface,
    onSurface: c.onSurface,
    onSurfaceVariant: c.onSurfaceVariant,
    surfaceContainerLowest: const Color(0xFF081020),
    surfaceContainerLow: const Color(0xFF0B1326),
    surfaceContainer: const Color(0xFF0F1B33),
    surfaceContainerHigh: const Color(0xFF14223D),
    surfaceContainerHighest: c.glassBase,
    outlineVariant: const Color(0x2EFFFFFF),
    error: const Color(0xFFFF7A88),
    onError: Colors.white,
  );

  final tokens = const SkinTokens(
    name: 'A · 深空玻璃',
    appbarGradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFF0B1326), Color(0xFF0E1A33)],
    ),
    drawerGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF0D162C), Color(0xFF0B1428)],
    ),
    composerFill: Color(0x12FFFFFF),
    composerBorder: Color(0x1AFFFFFF),
    composerRadius: 24,
    fieldRadius: 14,
    cardRadius: 16,
    userBubbleGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF3E63F4), Color(0xFF4C8DFF)],
    ),
    glowColor: Color(0x664C8CFF),
  );

  return _base(
    scheme: scheme,
    tokens: tokens,
    scaffoldBg: c.surface,
    appBar: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: c.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      iconTheme: const IconThemeData(color: Color(0xFFDCE6F8)),
      actionsIconTheme: const IconThemeData(color: Color(0xFFDCE6F8)),
      shape: const Border(
        bottom: BorderSide(color: Color(0x12FFFFFF), width: 1),
      ),
    ),
    card: CardThemeData(
      color: const Color(0x0EFFFFFF),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0x14FFFFFF)),
      ),
    ),
    input: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0x0EFFFFFF),
      hintStyle: TextStyle(color: c.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0x1AFFFFFF)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0x1AFFFFFF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.primary, width: 1.4),
      ),
    ),
    divider: const DividerThemeData(color: Color(0x14FFFFFF), thickness: 1),
    filledButtonStyle: FilledButton.styleFrom(
      backgroundColor: c.primary,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    textButtonStyle: TextButton.styleFrom(foregroundColor: c.secondary),
    iconButtonColor: c.onSurfaceVariant,
    dialogBg: const Color(0xFF13203C),
    dialogRadius: 20,
    snackBarBg: const Color(0xFF16233F),
  );
}

ThemeData _brandSplash() {
  const c = _CColors();
  final scheme = ColorScheme.fromSeed(
    seedColor: c.primary,
    brightness: Brightness.light,
  ).copyWith(
    primary: c.primary,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFE4EBFF),
    onPrimaryContainer: const Color(0xFF1E347E),
    secondary: c.secondary,
    onSecondary: Colors.white,
    surface: c.surface,
    onSurface: c.onSurface,
    onSurfaceVariant: c.onSurfaceVariant,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFFAFBFF),
    surfaceContainer: const Color(0xFFF2F5FE),
    surfaceContainerHigh: const Color(0xFFEDF1FD),
    surfaceContainerHighest: Colors.white,
    outlineVariant: c.hairline,
    error: const Color(0xFFDC3D4E),
    onError: Colors.white,
  );

  final tokens = const SkinTokens(
    name: 'C · 鲸蓝',
    appbarGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF4F6BED), Color(0xFF38BDF8)],
    ),
    drawerGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF4F6BED), Color(0xFF3F7DE0)],
    ),
    composerFill: Colors.white,
    composerBorder: null,
    composerRadius: 26,
    fieldRadius: 16,
    cardRadius: 16,
    userBubbleGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF4F6BED), Color(0xFF38BDF8)],
    ),
    glowColor: Color(0x524F6BED),
  );

  return _base(
    scheme: scheme,
    tokens: tokens,
    scaffoldBg: c.surface,
    appBar: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      iconTheme: const IconThemeData(color: Colors.white),
      actionsIconTheme: const IconThemeData(color: Colors.white),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(22)),
      ),
    ),
    card: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shadowColor: const Color(0x144F6BED),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE4EBFB)),
      ),
    ),
    input: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      hintStyle: TextStyle(color: c.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE4EBFB)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE4EBFB)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: c.primary, width: 1.4),
      ),
    ),
    divider: const DividerThemeData(color: Color(0xFFE4EBFB), thickness: 1),
    filledButtonStyle: FilledButton.styleFrom(
      backgroundColor: c.primary,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    textButtonStyle: TextButton.styleFrom(foregroundColor: c.primary),
    iconButtonColor: c.onSurfaceVariant,
    dialogBg: Colors.white,
    dialogRadius: 22,
    snackBarBg: const Color(0xFF152347),
  );
}

ThemeData _base({
  required ColorScheme scheme,
  required SkinTokens tokens,
  required Color scaffoldBg,
  required AppBarTheme appBar,
  required CardThemeData card,
  required InputDecorationTheme input,
  required DividerThemeData divider,
  required ButtonStyle filledButtonStyle,
  required ButtonStyle textButtonStyle,
  required Color iconButtonColor,
  required Color dialogBg,
  required double dialogRadius,
  required Color snackBarBg,
}) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scaffoldBg,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: appBar,
    cardTheme: card,
    inputDecorationTheme: input,
    dividerTheme: divider,
    filledButtonTheme: FilledButtonThemeData(style: filledButtonStyle),
    textButtonTheme: TextButtonThemeData(style: textButtonStyle),
    // 注意：**不设**全局 IconButtonTheme.foregroundColor——它会压制 AppBar 图标色
    // （iconTheme/actionsIconTheme），在渐变顶栏上产生灰对蓝低对比。
    dialogTheme: DialogThemeData(
      backgroundColor: dialogBg,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(dialogRadius)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: snackBarBg,
      behavior: SnackBarBehavior.floating,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: iconButtonColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dialogBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(dialogRadius)),
      ),
    ),
    extensions: [tokens],
  );
}

class _AColors {
  const _AColors();
  final primary = const Color(0xFF5B8CFF);
  final secondary = const Color(0xFF4CC2FF);
  final surface = const Color(0xFF0B1628);
  final onSurface = const Color(0xFFE9EFFA);
  final onSurfaceVariant = const Color(0xFFA9BCE2);
  final glassBase = const Color(0xFF16233F);
}

class _CColors {
  const _CColors();
  final primary = const Color(0xFF4F6BED);
  final secondary = const Color(0xFF38BDF8);
  final surface = const Color(0xFFF6F8FE);
  final onSurface = const Color(0xFF152347);
  final onSurfaceVariant = const Color(0xFF43537C);
  final hairline = const Color(0xFFE4EBFB);
}

/// 皮肤选择持久化（SharedPreferences，key=dsh_skin）。
class SkinStore {
  static const _key = 'dsh_skin';

  static Future<DshSkin> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(_key);
      return DshSkin.values.firstWhere(
        (s) => s.name == v,
        orElse: () => DshSkin.darkGlass,
      );
    } catch (_) {
      return DshSkin.darkGlass;
    }
  }

  static Future<void> save(DshSkin skin) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, skin.name);
    } catch (_) {}
  }
}

/// 皮肤状态（全局单例）：抽屉切换器写这里，MaterialApp 监听重建。
final ValueNotifier<DshSkin> skinNotifier = ValueNotifier<DshSkin>(DshSkin.darkGlass);

/// 顶栏渐变挂载点（各页 AppBar 的 flexibleSpace 统一引用；渐变为 null 时留空吃主题底色）。
Widget skinFlexibleSpace(BuildContext context) {
  final tk = Theme.of(context).extension<SkinTokens>();
  final g = tk?.appbarGradient;
  if (g == null) return const SizedBox.shrink();
  return DecoratedBox(decoration: BoxDecoration(gradient: g));
}
