/// Vela 主题：单一黛蓝主色 + 中性纸面底色，亮/暗双模。
///
/// 设计基调（克制优先）：
///  - **一个主色**：黛蓝 #3E5C76。除主色外不再引入第二个品牌色，
///    页面里出现的其他颜色只承担语义（运行中 / 警告 / 错误），
///    且全部降到低饱和，避免「彩虹图标墙」。
///  - **靠留白分层，不靠装饰**：卡片是白纸 + 1px 发丝线，没有投影、
///    没有半透明玻璃、没有渐变。层次来自底色差与间距，而非特效。
///  - **圆角收小**：卡片 12、按钮 8。大圆角会吃掉可用面积，
///    也让界面显得「软塌」。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// CupertinoPageTransitionsBuilder 定义在 cupertino 库里，material 不再导出
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

import 'tokens.dart';

/// 品牌与语义色板。
///
/// 除 [primary] 之外的色值都是**语义色**：只在表达状态时使用，
/// 不要拿来做装饰性图标底色。
abstract final class VelaColors {
  // ---------------------------------------------------------------- 主色
  /// 主色：黛蓝。
  static const Color ink = Color(0xFF3E5C76);

  /// 深色模式的主色。
  ///
  /// 取 #7E9AB2 而不是更浅的 #9BB3C8：后者对深色表面约 8:1，做小图标没问题，
  /// 但整块实心按钮会变成页面上最亮的东西，和「素雅」相悖。这一档对表面
  /// 仍有约 6:1，按钮文字（onPrimary #14232E）对底色 5.4:1，都过 AA。
  static const Color inkLight = Color(0xFF7E9AB2);

  /// 兼容旧引用：靛蓝即主色。
  static const Color indigo = ink;
  static const Color indigoLight = inkLight;
  static const Color indigoDark = Color(0xFF2C4459);

  // ------------------------------------------------------------ 语义色
  /// 运行中 / 成功。
  static const Color emerald = Color(0xFF4C7A62);
  static const Color emeraldLight = Color(0xFF7FB097);

  /// 警告 / 进行中。
  static const Color amber = Color(0xFF9A7429);
  static const Color amberLight = Color(0xFFD2B172);

  /// 信息 / 中性强调。
  static const Color azure = Color(0xFF456E8A);
  static const Color azureLight = Color(0xFF8FB0C4);

  /// 错误 / 阻断。
  static const Color rose = Color(0xFFA8443A);
  static const Color roseLight = Color(0xFFD98A80);

  /// 次级识别色（mihomo 标签、收藏星标）。
  static const Color violet = Color(0xFF6B5E86);
  static const Color violetLight = Color(0xFFA79BC0);

  // ------------------------------------------------------------ 画布
  /// 画布（浅色）：带一点暖调的纸面白。
  static const Color canvasLight = Color(0xFFF6F6F4);

  /// 画布（深色）：近墨而非纯黑。
  ///
  /// 纯黑会让 1px 发丝线与低透明度叠加全部失效，界面只剩「黑底白字」，
  /// 既没有层次也刺眼。这里抬到 #121316 并留一点蓝调。
  static const Color canvasDark = Color(0xFF121316);

  /// 把语义色按亮度取「适合当前模式」的那一档。
  ///
  /// 深色模式下浅一档的色值才有足够对比度；浅色模式下用原色。
  static Color resolve(Color light, Brightness brightness) =>
      brightness == Brightness.dark
          ? switch (light) {
              emerald => emeraldLight,
              amber => amberLight,
              azure => azureLight,
              rose => roseLight,
              violet => violetLight,
              ink => inkLight,
              _ => light,
            }
          : light;
}

/// 亮色模式配色。
ColorScheme _lightScheme() {
  return const ColorScheme(
    brightness: Brightness.light,
    primary: VelaColors.ink,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFE9EFF5),
    onPrimaryContainer: Color(0xFF23394A),
    secondary: Color(0xFF6E7B87),
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFFEDEFF2),
    onSecondaryContainer: Color(0xFF2A3138),
    tertiary: Color(0xFF8A7A68),
    onTertiary: Colors.white,
    tertiaryContainer: Color(0xFFF2EDE7),
    onTertiaryContainer: Color(0xFF3A3128),
    error: VelaColors.rose,
    onError: Colors.white,
    errorContainer: Color(0xFFF7E7E4),
    onErrorContainer: Color(0xFF4A1D18),
    surface: Colors.white,
    onSurface: Color(0xFF1C1E21),
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Color(0xFFFCFCFB),
    surfaceContainer: Color(0xFFF3F3F0),
    surfaceContainerHigh: Color(0xFFEDEDE9),
    surfaceContainerHighest: Color(0xFFE6E6E1),
    onSurfaceVariant: Color(0xFF676B70),
    outline: Color(0xFFD5D4CE),
    outlineVariant: Color(0xFFEAE9E4),
    shadow: Color(0x14101828),
    scrim: Color(0x59101828),
    inverseSurface: Color(0xFF24262A),
    onInverseSurface: Color(0xFFF2F1EE),
    inversePrimary: VelaColors.inkLight,
  );
}

/// 深色模式配色。
///
/// 取值理由：
///  - 主色用浅一档的 [VelaColors.inkLight]：黛蓝原色在深底上对比度不足，
///    浅一档后对表面约 8:1，作为图标/文字色才清晰。
///  - 表面层级按「越低越深」递增，相邻层差约 4% 亮度，肉眼能分辨又不显脏。
///  - 正文 #E7E6E2 对表面 #191A1D 约 14:1，次要文字 #9EA1A6 约 6.7:1，
///    都超过 WCAG AA。
ColorScheme _darkScheme() {
  return const ColorScheme(
    brightness: Brightness.dark,
    primary: VelaColors.inkLight,
    onPrimary: Color(0xFF14232E),
    primaryContainer: Color(0xFF2A3B4A),
    onPrimaryContainer: Color(0xFFD6E4EF),
    secondary: Color(0xFF9AA6B2),
    onSecondary: Color(0xFF1B2229),
    secondaryContainer: Color(0xFF2C333A),
    onSecondaryContainer: Color(0xFFDCE2E8),
    tertiary: Color(0xFFB8A692),
    onTertiary: Color(0xFF2E251B),
    tertiaryContainer: Color(0xFF3E3428),
    onTertiaryContainer: Color(0xFFEDE1D3),
    error: VelaColors.roseLight,
    onError: Color(0xFF3D1512),
    errorContainer: Color(0xFF5A241F),
    onErrorContainer: Color(0xFFF7E7E4),
    surface: Color(0xFF191A1D),
    onSurface: Color(0xFFE7E6E2),
    surfaceContainerLowest: Color(0xFF0E0F11),
    surfaceContainerLow: Color(0xFF1D1E22),
    surfaceContainer: Color(0xFF222327),
    surfaceContainerHigh: Color(0xFF282A2E),
    surfaceContainerHighest: Color(0xFF313338),
    onSurfaceVariant: Color(0xFF9EA1A6),
    // 交互元素的边界色。#4A4C51 时对卡片只有 1.8~2.0:1——描边按钮
    // （停止 / 导出 / 删除）在暗色下几乎看不出边界。这里取能让四种暗色
    // 表面都过 3:1 的最低值（最差的 surfaceContainerHigh 上 3.21:1），
    // 再亮就会盖过次要文字。
    //
    // 注意：卡片/分隔线用的是 outlineVariant（#2E3034），仍是发丝线；
    // 这条只管「需要被看见」的边界。
    outline: Color(0xFF74777E),
    outlineVariant: Color(0xFF2E3034),
    shadow: Color(0x66000000),
    scrim: Color(0x99000000),
    inverseSurface: Color(0xFFE7E6E2),
    onInverseSurface: Color(0xFF191A1D),
    inversePrimary: VelaColors.ink,
  );
}

/// 构建 Vela 主题。
///
/// [platform] 传入可让状态栏 / 标题栏图标颜色跟随系统深浅色，
/// 桌面端调用方应在 `ThemeMode` 变化时重新构建。
///
/// [fontFamily] 指定全局字体族。会同时作用于正文字号体系与按钮、
/// 输入框等组件主题里的文字样式——否则组件自带 textStyle 会覆盖掉
/// 字体族，出现「正文是自定义字体、按钮却回落到系统字体」的不一致。
ThemeData buildVelaTheme({
  Brightness brightness = Brightness.light,
  TargetPlatform? platform,
  String? fontFamily,
}) {
  final scheme =
      brightness == Brightness.dark ? _darkScheme() : _lightScheme();
  final isDark = brightness == Brightness.dark;
  final targetPlatform = platform ?? defaultTargetPlatform;

  // 水波纹实现选择：
  //  - InkSparkle 走 fragment shader（ink_sparkle.frag），每帧一次全屏
  //    shader pass，在桌面端（尤其 macOS 的 Impeller）开销极高，点击后
  //    会有明显拖尾感。Flutter 官方默认也只在 Android 上用它。
  //  - 桌面端统一用 InkRipple：实现简单、无 GPU shader 开销。
  final splashFactory = targetPlatform == TargetPlatform.android && !kIsWeb
      ? InkSparkle.splashFactory
      : InkRipple.splashFactory;

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    fontFamily: fontFamily,
    scaffoldBackgroundColor:
        isDark ? VelaColors.canvasDark : VelaColors.canvasLight,
    splashFactory: splashFactory,
    visualDensity: VisualDensity.standard,
  );

  final baseText = base.textTheme.apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  // 字号层级只保留三档明显差异（标题 / 小标题 / 正文），
  // 字重统一压到 w600 以内：整页都是 w700+ 会让标题互相打架。
  final textTheme = baseText.copyWith(
    displaySmall: baseText.displaySmall?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: -0.6,
      height: 1.2,
    ),
    headlineMedium: baseText.headlineMedium?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: -0.4,
      height: 1.25,
    ),
    headlineSmall: baseText.headlineSmall?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      height: 1.3,
    ),
    titleLarge: baseText.titleLarge?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: -0.1,
    ),
    titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    titleSmall: baseText.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w500),
    bodyLarge: baseText.bodyLarge?.copyWith(height: 1.5),
    bodyMedium: baseText.bodyMedium?.copyWith(height: 1.5),
    bodySmall: baseText.bodySmall?.copyWith(
      height: 1.45,
      color: scheme.onSurfaceVariant,
    ),
  );

  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Radii.md),
  );

  return base.copyWith(
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
      systemOverlayStyle: isDark
          ? SystemUiOverlayStyle.light.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
            )
          : SystemUiOverlayStyle.dark.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
            ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.card,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: Radii.panel,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: scheme.surfaceContainerHigh,
      selectedIconTheme: IconThemeData(color: scheme.onSurface),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: isDark ? scheme.surfaceContainerLow : Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.surfaceContainerHigh,
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStatePropertyAll(
        textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w500),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(buttonShape),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.surfaceContainerHigh
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
        ),
        shape: WidgetStatePropertyAll(buttonShape),
        // 前景色必须显式给 onPrimary：
        // ButtonStyle.textStyle 里的 color **会覆盖** foregroundColor 的
        // 解析结果，而 textTheme.labelLarge 经 apply(bodyColor:) 带上了
        // onSurface。结果就是「深色模式下浅色底 + 浅色字」的低对比按钮。
        foregroundColor: WidgetStatePropertyAll(scheme.onPrimary),
        iconColor: WidgetStatePropertyAll(scheme.onPrimary),
        textStyle: WidgetStatePropertyAll(
          textTheme.labelLarge?.copyWith(
            fontSize: 14,
            color: scheme.onPrimary,
          ),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
        ),
        shape: WidgetStatePropertyAll(buttonShape),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
        foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
        textStyle: WidgetStatePropertyAll(
          textTheme.labelLarge?.copyWith(fontSize: 14),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.sm),
        ),
        shape: WidgetStatePropertyAll(buttonShape),
        foregroundColor: WidgetStatePropertyAll(scheme.primary),
        minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // 输入框用「比卡片深一档」的填充：浅色下是浅灰、深色下比卡片略亮，
      // 这样即使不画描边也能看出可输入区域（深色下卡片本身就是 surfaceContainerLow，
      // 若填充取同色，输入框会整块消失在卡片里）。
      fillColor: scheme.surfaceContainer,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.md,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide(color: scheme.error, width: 1.4),
      ),
      labelStyle:
          TextStyle(color: scheme.onSurfaceVariant, fontFamily: fontFamily),
      floatingLabelStyle: TextStyle(
        color: scheme.primary,
        fontWeight: FontWeight.w500,
        fontFamily: fontFamily,
      ),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontFamily: fontFamily),
      helperStyle: textTheme.bodySmall,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: scheme.surfaceContainerHigh,
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: textTheme.labelMedium,
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.xxs,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdRadius),
      contentPadding: const EdgeInsets.symmetric(horizontal: Insets.md),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      textStyle: textTheme.bodyMedium,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor:
          isDark ? scheme.surfaceContainerHighest : scheme.inverseSurface,
      contentTextStyle: TextStyle(
        color: scheme.onInverseSurface,
        fontFamily: fontFamily,
      ),
      shape: const RoundedRectangleBorder(borderRadius: Radii.mdRadius),
      insetPadding: const EdgeInsets.all(Insets.lg),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : scheme.onSurfaceVariant,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: isDark ? scheme.surfaceContainerHighest : scheme.inverseSurface,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      textStyle: TextStyle(
        color: scheme.onInverseSurface,
        fontSize: 12,
        fontFamily: fontFamily,
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  ).copyWith(
    platform: platform,
  );
}
