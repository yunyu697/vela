/// Vela 主题：靛蓝紫主色 + 亮/暗双模。
///
/// 设计基调：
///  - 主色靛蓝 (#4F46E5)，辅以紫罗兰、天青、琥珀三色作为功能强调色
///  - 大面积使用柔和渐变背景与半透明「玻璃」卡片，层次靠明度而非描边堆叠
///  - 圆角统一走 [Radii]，间距统一走 [Insets]
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// CupertinoPageTransitionsBuilder 定义在 cupertino 库里，material 不再导出
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

import 'tokens.dart';

/// 品牌色板。
abstract final class VelaColors {
  /// 主色：靛蓝。
  static const Color indigo = Color(0xFF4F46E5);
  static const Color indigoLight = Color(0xFF818CF8);
  static const Color indigoDark = Color(0xFF3730A3);

  /// 辅助色：紫罗兰（渐变末端）。
  static const Color violet = Color(0xFF7C3AED);
  static const Color violetLight = Color(0xFFA78BFA);

  /// 功能色：天青（信息/次要强调）。
  static const Color azure = Color(0xFF0EA5E9);
  static const Color azureLight = Color(0xFF38BDF8);

  /// 功能色：琥珀（警告 / 订阅流量）。
  static const Color amber = Color(0xFFF59E0B);
  static const Color amberLight = Color(0xFFFBBF24);

  /// 功能色：翠绿（成功 / 运行中）。
  static const Color emerald = Color(0xFF10B981);
  static const Color emeraldLight = Color(0xFF34D399);

  /// 功能色：玫红（错误）。
  static const Color rose = Color(0xFFE11D48);
  static const Color roseLight = Color(0xFFFB7185);

  /// 品牌渐变（主 → 紫）。
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6366F1), Color(0xFF8B5CF6), Color(0xFFA855F7)],
    stops: [0.0, 0.55, 1.0],
  );

  /// 冷色渐变（用于次级面板与连接表头）。
  static const LinearGradient coolGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0EA5E9), Color(0xFF6366F1)],
  );

  /// 暖色渐变（用于流量等强调磁贴）。
  static const LinearGradient warmGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF59E0B), Color(0xFFF43F5E)],
  );

  /// 背景微光色（浅色模式）。
  static const Color canvasLight = Color(0xFFF6F7FB);

  /// 背景微光色（深色模式）。
  static const Color canvasDark = Color(0xFF0B0D14);
}

/// 亮色模式配色。
ColorScheme _lightScheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: VelaColors.indigo,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFE0E7FF),
    onPrimaryContainer: Color(0xFF1E1B4B),
    secondary: VelaColors.violet,
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFFEDE9FE),
    onSecondaryContainer: Color(0xFF3B0764),
    tertiary: VelaColors.azure,
    onTertiary: Colors.white,
    tertiaryContainer: Color(0xFFE0F2FE),
    onTertiaryContainer: Color(0xFF0C4A6E),
    error: VelaColors.rose,
    onError: Colors.white,
    errorContainer: Color(0xFFFFE4E6),
    onErrorContainer: Color(0xFF881337),
    surface: Colors.white,
    onSurface: Color(0xFF16181F),
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Color(0xFFFAFBFE),
    surfaceContainer: Color(0xFFF2F4F9),
    surfaceContainerHigh: Color(0xFFEAEDF4),
    surfaceContainerHighest: Color(0xFFE3E7EF),
    onSurfaceVariant: Color(0xFF5A6070),
    outline: Color(0xFFC9CEDA),
    outlineVariant: Color(0xFFE4E8F0),
    shadow: Color(0x1A101828),
    scrim: Color(0x66101828),
    inverseSurface: Color(0xFF1B1E27),
    onInverseSurface: Color(0xFFF4F5F9),
    inversePrimary: VelaColors.indigoLight,
  );
  return scheme;
}

/// 深色模式配色。
ColorScheme _darkScheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: VelaColors.indigoLight,
    onPrimary: Color(0xFF15134A),
    primaryContainer: Color(0xFF312E81),
    onPrimaryContainer: Color(0xFFE0E7FF),
    secondary: VelaColors.violetLight,
    onSecondary: Color(0xFF2E1065),
    secondaryContainer: Color(0xFF4C1D95),
    onSecondaryContainer: Color(0xFFEDE9FE),
    tertiary: VelaColors.azureLight,
    onTertiary: Color(0xFF082F49),
    tertiaryContainer: Color(0xFF075985),
    onTertiaryContainer: Color(0xFFE0F2FE),
    error: VelaColors.roseLight,
    onError: Color(0xFF4C0519),
    errorContainer: Color(0xFF9F1239),
    onErrorContainer: Color(0xFFFFE4E6),
    surface: Color(0xFF12141C),
    onSurface: Color(0xFFE8EAF2),
    surfaceContainerLowest: Color(0xFF0B0D14),
    surfaceContainerLow: Color(0xFF171A23),
    surfaceContainer: Color(0xFF1C1F29),
    surfaceContainerHigh: Color(0xFF242834),
    surfaceContainerHighest: Color(0xFF2D323F),
    onSurfaceVariant: Color(0xFFA6ADBD),
    outline: Color(0xFF444B5C),
    outlineVariant: Color(0xFF2B3040),
    shadow: Color(0x66000000),
    scrim: Color(0x99000000),
    inverseSurface: Color(0xFFE8EAF2),
    onInverseSurface: Color(0xFF16181F),
    inversePrimary: VelaColors.indigo,
  );
  return scheme;
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
    scaffoldBackgroundColor: isDark ? VelaColors.canvasDark : VelaColors.canvasLight,
    splashFactory: splashFactory,
    visualDensity: VisualDensity.standard,
  );

  final baseText = base.textTheme.apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  final textTheme = baseText.copyWith(
    displaySmall: baseText.displaySmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.8,
      height: 1.15,
    ),
    headlineMedium: baseText.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      height: 1.2,
    ),
    headlineSmall: baseText.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      height: 1.25,
    ),
    titleLarge: baseText.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    titleSmall: baseText.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    bodyMedium: baseText.bodyMedium?.copyWith(height: 1.45),
    bodySmall: baseText.bodySmall?.copyWith(
      height: 1.4,
      color: scheme.onSurfaceVariant,
    ),
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
      titleTextStyle: textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
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
      color: isDark ? scheme.surfaceContainerLow : Colors.white,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(borderRadius: Radii.card),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? scheme.surfaceContainerHigh : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: Radii.panel),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
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
      backgroundColor: isDark ? scheme.surfaceContainer : Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      elevation: 0,
      height: 68,
      labelTextStyle: WidgetStatePropertyAll(
        textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
        ),
        side: WidgetStatePropertyAll(
          BorderSide(color: scheme.outlineVariant),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Insets.xl, vertical: Insets.lg),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        ),
        textStyle: WidgetStatePropertyAll(
          textTheme.labelLarge?.copyWith(fontSize: 14.5),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Insets.xl, vertical: Insets.lg),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
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
      fillColor: isDark ? scheme.surfaceContainer : scheme.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.lg,
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
        borderSide: BorderSide(color: scheme.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide(color: scheme.error, width: 1.6),
      ),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontFamily: fontFamily),
      floatingLabelStyle: TextStyle(
        color: scheme.primary,
        fontWeight: FontWeight.w600,
        fontFamily: fontFamily,
      ),
      helperStyle: textTheme.bodySmall,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainer,
      selectedColor: scheme.primaryContainer,
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: textTheme.labelMedium,
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.xs,
      ),
      shape: const RoundedRectangleBorder(borderRadius: Radii.chip),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      shape: const RoundedRectangleBorder(borderRadius: Radii.card),
      contentPadding: const EdgeInsets.symmetric(horizontal: Insets.lg),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isDark ? scheme.surfaceContainerHighest : scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface, fontFamily: fontFamily),
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
