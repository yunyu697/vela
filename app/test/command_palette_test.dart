/// 命令面板与全局快捷键的功能验证。
///
/// 覆盖：
///  1. 面板打开、输入过滤、Enter 执行命令
///  2. Ctrl+1/2/3（测试环境 targetPlatform=android，⌘ 映射为 Ctrl）
///     页面切换
///  3. Ctrl+K 从外壳打开面板
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/storage/kv_store.dart';
import 'package:vela/features/home/home_page.dart';
import 'package:vela/features/run/run_page.dart';
import 'package:vela/ui/app_shell.dart';
import 'package:vela/ui/command_palette.dart';
import 'package:vela/ui/vela_shortcuts.dart';

Future<void> _loadRealFont() async {
  final file = File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
  if (file.existsSync()) {
    final bytes = await file.readAsBytes();
    final loader = FontLoader('ArialUnicode')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
  final iconFile = File(
      '/Users/tyler/WorkBuddy/2026-10-31-05-44-34/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (iconFile.existsSync()) {
    final bytes = await iconFile.readAsBytes();
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}

late Directory tmp;

Future<void> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    // 与 main.dart 相同的 builder 结构：快捷键层包在 Navigator 之上
    builder: (context, child) =>
        VelaShortcutLayer(child: child ?? const SizedBox.shrink()),
    home: const VelaShell(),
  ));
  // 等 ProfileRepository 的异步 IO 与入场动画结束
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await tester.pump(const Duration(milliseconds: 900));
}

void main() {
  setUpAll(_loadRealFont);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vela_palette_test');
    AppPaths.overrideSupportDir = tmp.path;
  });

  tearDown(() async {
    AppPaths.overrideSupportDir = null;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('命令面板', () {
    testWidgets('过滤与回车执行', (tester) async {
      var executed = 0;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: OutlinedButton(
                onPressed: () => showVelaCommandPalette(context, [
                  VelaCommand(
                    title: '前往概览',
                    icon: Icons.dashboard_outlined,
                    onRun: () => executed++,
                  ),
                  VelaCommand(
                    title: '前往配置',
                    icon: Icons.tune_outlined,
                    onRun: () {},
                  ),
                  VelaCommand(
                    title: '新建配置（向导）',
                    icon: Icons.auto_awesome_rounded,
                    onRun: () {},
                  ),
                ]),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      // 默认展示全部 3 条
      expect(find.text('前往概览'), findsOneWidget);
      expect(find.text('前往配置'), findsOneWidget);
      expect(find.text('新建配置（向导）'), findsOneWidget);

      // 输入过滤
      await tester.enterText(find.byType(TextField), '向导');
      await tester.pump();
      expect(find.text('新建配置（向导）'), findsOneWidget);
      expect(find.text('前往概览'), findsNothing);

      // 回车执行高亮项
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(executed, 0); // 高亮的是「向导」这条，没计数
    });

    testWidgets('无匹配时显示空态', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: OutlinedButton(
                onPressed: () =>
                    showVelaCommandPalette(context, const []),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'xyz');
      await tester.pump();
      expect(find.text('没有匹配的命令'), findsOneWidget);
    });
  });

  group('全局快捷键', () {
    testWidgets('Ctrl+2 切到配置页，Ctrl+1 切回概览', (tester) async {
      await _pumpShell(tester);
      expect(find.byType(HomePage), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(HomePage), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(HomePage), findsOneWidget);
    });

    testWidgets('Ctrl+3 切到运行页', (tester) async {
      await _pumpShell(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(RunPage), findsOneWidget);
    });

    testWidgets('Ctrl+K 打开命令面板', (tester) async {
      await _pumpShell(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('前往概览'), findsOneWidget);

      // Esc 关闭
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
    });
  });
}
