/// 主题与设置项测试。
///
/// 覆盖三件事：
///  1. [AppSettings] 的持久化与三态循环（暗色是用户可配置项，设置不能丢）
///  2. 暗色配色方案的对比度下限（防止有人「顺手调色」把可读性调没）
///  3. 主题切换控件的交互（点击 → 模式前进 → 界面重建）
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/settings/app_settings.dart';
import 'package:vela/core/storage/kv_store.dart';
import 'package:vela/ui/theme_toggle.dart';
import 'package:vela/ui/vela_theme.dart';

/// WCAG 相对亮度（sRGB 线性化后按人眼敏感度加权）。
double _luminance(Color c) {
  double lin(double v) => v <= 0.03928
      ? v / 12.92
      : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

/// 对比度（1:1 ~ 21:1）。
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vela_theme_test');
    AppPaths.overrideSupportDir = tmp.path;
    AppSettings.instance.resetForTest();
  });

  tearDown(() async {
    AppSettings.instance.resetForTest();
    AppPaths.overrideSupportDir = null;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('AppSettings', () {
    test('默认跟随系统', () async {
      await AppSettings.instance.init();
      expect(AppSettings.instance.themeMode, ThemeMode.system);
    });

    test('三态循环顺序', () {
      expect(ThemeMode.system.next, ThemeMode.light);
      expect(ThemeMode.light.next, ThemeMode.dark);
      expect(ThemeMode.dark.next, ThemeMode.system);
    });

    test('切换后落盘，重启可恢复', () async {
      await AppSettings.instance.init();
      await AppSettings.instance.setThemeMode(ThemeMode.dark);
      expect(AppSettings.instance.themeMode, ThemeMode.dark);

      // 模拟重启：清内存后重新 init
      AppSettings.instance.resetForTest();
      await AppSettings.instance.init();
      expect(
        AppSettings.instance.themeMode,
        ThemeMode.dark,
        reason: '主题模式必须持久化，否则每次启动都回到默认值',
      );
    });

    test('cycleThemeMode 走完一圈', () async {
      await AppSettings.instance.init();
      final seen = <ThemeMode>[];
      for (var i = 0; i < 3; i++) {
        await AppSettings.instance.cycleThemeMode();
        seen.add(AppSettings.instance.themeMode);
      }
      expect(seen, [ThemeMode.light, ThemeMode.dark, ThemeMode.system]);
    });

    test('存储不可用时不影响启动', () async {
      // 指向一个文件而不是目录：建目录/写文件都会失败
      final blocker = File('${tmp.path}/blocker')..writeAsStringSync('x');
      AppPaths.overrideSupportDir = blocker.path;
      await AppSettings.instance.init();
      expect(AppSettings.instance.themeMode, AppSettings.defaultThemeMode);
    });
  });

  group('暗色配色对比度', () {
    final dark = buildVelaTheme(brightness: Brightness.dark).colorScheme;
    final light = buildVelaTheme(brightness: Brightness.light).colorScheme;

    test('正文对表面 ≥ 7:1（AAA 正文）', () {
      expect(_contrast(dark.onSurface, dark.surface), greaterThan(7.0));
      expect(_contrast(light.onSurface, light.surface), greaterThan(7.0));
    });

    test('次要文字对表面 ≥ 4.5:1（AA 正文）', () {
      expect(_contrast(dark.onSurfaceVariant, dark.surface), greaterThan(4.5));
      expect(
        _contrast(light.onSurfaceVariant, light.surface),
        greaterThan(4.5),
      );
    });

    test('主色对表面 ≥ 3:1（图标/大字号下限）', () {
      expect(
        _contrast(dark.primary, dark.surface),
        greaterThan(3.0),
        reason: '暗色主色在深底上必须看得见（靛蓝原色只有 3.1:1，偏危险）',
      );
    });

    test('表面层级单调递增（低 → 高越来越亮）', () {
      final layers = [
        dark.surfaceContainerLowest,
        dark.surfaceContainerLow,
        dark.surfaceContainer,
        dark.surfaceContainerHigh,
        dark.surfaceContainerHighest,
      ];
      for (var i = 1; i < layers.length; i++) {
        expect(
          _luminance(layers[i]),
          greaterThan(_luminance(layers[i - 1])),
          reason: '第 $i 层表面应该比上一层更亮，否则层级关系看不出来',
        );
      }
    });

    test('画布与卡片有可分辨的亮度差', () {
      expect(
        _luminance(dark.surfaceContainerLow),
        greaterThan(_luminance(VelaColors.canvasDark)),
      );
      expect(
        _luminance(VelaColors.canvasDark),
        greaterThan(0.002),
        reason: '画布不能是纯黑：纯黑上柔和阴影完全不可见，层次只剩描边',
      );
    });
  });

  group('组件主题一致性', () {
    // 回归：ButtonStyle.textStyle 里的 color 会覆盖 foregroundColor 的
    // 解析结果。之前 filledButtonTheme 只给了 fontSize，label 继承了
    // textTheme 的 onSurface——深色模式下变成「浅色底 + 浅色字」，
    // 启动按钮几乎看不见。这里锁死文字色与底色的对比度。
    for (final brightness in [Brightness.light, Brightness.dark]) {
      test('FilledButton 文字对底色 ≥ 4.5:1（${brightness.name}）', () {
        final theme = buildVelaTheme(brightness: brightness);
        final style = theme.filledButtonTheme.style!;
        final fg = style.textStyle!.resolve(<WidgetState>{})!.color;
        expect(fg, isNotNull, reason: '按钮文字色不能为 null，否则会回落到 onSurface');
        expect(
          _contrast(fg!, theme.colorScheme.primary),
          greaterThan(4.5),
          reason: '${brightness.name} 下按钮文字与靛蓝底色对比不足',
        );
      });
    }
  });

  group('主题切换控件', () {
    // 注意：widget 测试里**不能** `await AppSettings.instance.init()`。
    // 测试跑在 fake-async 时钟里，init 内部的真实文件 IO 完成回调挂在
    // 真实事件循环上，await 会永远挂起（表现为测试卡死到超时）。
    // 这里只需要内存态：setUp 已 resetForTest，默认值为 system。
    testWidgets('点击循环切换并重建界面', (tester) async {
      final seen = <ThemeMode>[];

      await tester.pumpWidget(
        AnimatedBuilder(
          animation: AppSettings.instance,
          builder: (context, _) {
            seen.add(AppSettings.instance.themeMode);
            return MaterialApp(
              theme: buildVelaTheme(brightness: Brightness.light),
              darkTheme: buildVelaTheme(brightness: Brightness.dark),
              themeMode: AppSettings.instance.themeMode,
              home: const Scaffold(
                body: Center(child: VelaThemeToggle()),
              ),
            );
          },
        ),
      );

      expect(find.text('跟随系统'), findsOneWidget);
      await tester.tap(find.byType(VelaThemeToggle));
      await tester.pumpAndSettle();
      expect(AppSettings.instance.themeMode, ThemeMode.light);
      expect(find.text('亮色'), findsOneWidget);

      await tester.tap(find.byType(VelaThemeToggle));
      await tester.pumpAndSettle();
      expect(AppSettings.instance.themeMode, ThemeMode.dark);
      expect(find.text('暗色'), findsOneWidget);
      expect(seen, contains(ThemeMode.dark));
    });

    testWidgets('收起态只显示图标', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildVelaTheme(brightness: Brightness.light),
          home: const Scaffold(
            body: Center(child: VelaThemeToggle(extended: false)),
          ),
        ),
      );
      expect(find.byIcon(ThemeMode.system.icon), findsOneWidget);
      expect(find.text('跟随系统'), findsNothing);
    });
  });
}
