/// 性能基线测试。
///
/// 目的：为「操作卡顿」建立**可量化、可回归**的基线。
///
/// 测什么：
///  1. 首帧构建耗时（build + layout）
///  2. 数据刷新时的增量构建耗时（模拟运行页每秒推送流量统计）
///  3. 页面切换的转场耗时
///  4. 溢出异常检测（性能问题常伴随布局退化）
///
/// 阈值设置得比较宽松，只用于捕捉「数量级级别的劣化」，
/// 不适合当作微基准。真正的优化收益看打印出的绝对数值。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/storage/kv_store.dart';
import 'package:vela/features/home/home_page.dart';
import 'package:vela/features/profiles/profiles_page.dart';
import 'package:vela/features/run/run_page.dart';
import 'package:vela/features/wizard/wizard_page.dart';
import 'package:vela/ui/vela_theme.dart';

const _testFontPath =
    '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
const _iconFontPath =
    '/Users/tyler/WorkBuddy/2026-10-31-05-44-34/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';

Future<void> _loadRealFont() async {
  final file = File(_testFontPath);
  if (file.existsSync()) {
    final bytes = await file.readAsBytes();
    final loader = FontLoader('ArialUnicode')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
  final iconFile = File(_iconFontPath);
  if (iconFile.existsSync()) {
    final bytes = await iconFile.readAsBytes();
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}

/// 单页构建耗时（毫秒）。只统计 build+layout，不含 raster。
///
/// 抗噪处理：连测 [rounds] 轮取**中位数**。开发机上常有其它进程抢 CPU，
/// 单次采样噪声极大（同一份代码两次跑能差 40%），中位数才能反映真实水平。
Future<int> _measureBuild(
  WidgetTester tester,
  Widget Function() build, {
  required Size size,
  int rounds = 5,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // 预热：让字体、主题、IconData 的缓存先建立起来。
  await tester.pumpWidget(build());

  final samples = <int>[];
  for (var i = 0; i < rounds; i++) {
    final sw = Stopwatch()..start();
    await tester.pumpWidget(build());
    sw.stop();
    samples.add(sw.elapsedMilliseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

/// 连续 [frames] 帧的单帧耗时中位数（毫秒）。
///
/// 逐帧测量而非「总耗时 / 帧数」——后者会被个别被系统抢占的长帧拉偏。
Future<double> _measureFrameMedian(
  WidgetTester tester, {
  required int frames,
  int warmup = 6,
}) async {
  for (var i = 0; i < warmup; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  final samples = <double>[];
  for (var i = 0; i < frames; i++) {
    final sw = Stopwatch()..start();
    await tester.pump(const Duration(milliseconds: 16));
    sw.stop();
    samples.add(sw.elapsedMicroseconds / 1000);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

/// 让页面内部的真实异步 IO 跑完（与 layout_test 同一套手法）。
Future<void> _settleAsyncIO(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pump();
  }
}

void main() {
  late Directory tmp;

  setUpAll(_loadRealFont);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vela_perf_test');
    AppPaths.overrideSupportDir = tmp.path;
  });

  tearDown(() async {
    AppPaths.overrideSupportDir = null;
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  Widget app(Widget home) {
    final base = buildVelaTheme(brightness: Brightness.light);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        textTheme: base.textTheme.apply(fontFamily: 'ArialUnicode'),
        primaryTextTheme:
            base.primaryTextTheme.apply(fontFamily: 'ArialUnicode'),
      ),
      home: home,
    );
  }

  group('首帧构建耗时', () {
    testWidgets('概览页', (tester) async {
      final ms = await _measureBuild(
        tester,
        () => app(HomePage(onOpenProfiles: () {}, onOpenRun: () {})),
        size: const Size(1280, 800),
      );
      debugPrint('[PERF] 首帧 概览页: ${ms}ms (中位数)');
      expect(ms, lessThan(1500), reason: '概览页首帧构建过慢：${ms}ms');
    });

    testWidgets('配置页', (tester) async {
      final ms = await _measureBuild(
        tester,
        () => app(ProfilesPage(onOpenRun: () {})),
        size: const Size(1280, 800),
      );
      debugPrint('[PERF] 首帧 配置页: ${ms}ms (中位数)');
      expect(ms, lessThan(1500), reason: '配置页首帧构建过慢：${ms}ms');
    });

    testWidgets('运行页', (tester) async {
      final ms = await _measureBuild(
        tester,
        () => app(const RunPage()),
        size: const Size(1280, 800),
      );
      debugPrint('[PERF] 首帧 运行页: ${ms}ms (中位数)');
      expect(ms, lessThan(1500), reason: '运行页首帧构建过慢：${ms}ms');
    });

    testWidgets('向导页', (tester) async {
      final ms = await _measureBuild(
        tester,
        () => app(const WizardPage()),
        size: const Size(1280, 800),
      );
      debugPrint('[PERF] 首帧 向导页: ${ms}ms (中位数)');
      expect(ms, lessThan(1500), reason: '向导页首帧构建过慢：${ms}ms');
    });
  });

  group('增量刷新耗时', () {
    testWidgets('运行页 20 次数据刷新', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(const RunPage()));
      await _settleAsyncIO(tester);

      // 模拟每秒一次的流量推送：连续 pump 20 帧
      final perFrame = await _measureFrameMedian(tester, frames: 20);
      debugPrint('[PERF] 增量刷新 运行页: 单帧中位 ${perFrame.toStringAsFixed(1)}ms');
      expect(
        perFrame,
        lessThan(60.0),
        reason: '运行页单帧增量刷新过慢：${perFrame.toStringAsFixed(1)}ms',
      );
    });

    testWidgets('概览页 20 次动画帧', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        app(HomePage(onOpenProfiles: () {}, onOpenRun: () {})),
      );
      await _settleAsyncIO(tester);

      final perFrame = await _measureFrameMedian(tester, frames: 20);
      debugPrint('[PERF] 增量刷新 概览页: 单帧中位 ${perFrame.toStringAsFixed(1)}ms');
      // 概览页空闲期有呼吸灯动画，每帧都要重绘动画层，天然比运行页贵。
      // 阈值放宽到 100ms：全量测试并行跑时机器负载会推高中位数
      // （单独跑实测 ~17ms）。真正的回归守卫是 profile_test 的
      // 「空闲期 0 重建」断言，这里只拦截数量级劣化。
      expect(
        perFrame,
        lessThan(100.0),
        reason: '概览页单帧过慢：${perFrame.toStringAsFixed(1)}ms',
      );
    });
  });

  group('无障碍与溢出', () {
    testWidgets('各页面在最小安全尺寸下无溢出', (tester) async {
      tester.view.physicalSize = const Size(880, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final pages = <String, Widget>{
        '概览': HomePage(onOpenProfiles: () {}, onOpenRun: () {}),
        '配置': ProfilesPage(onOpenRun: () {}),
        '运行': const RunPage(),
        '向导': const WizardPage(),
      };
      for (final entry in pages.entries) {
        await tester.pumpWidget(app(entry.value));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.takeException(),
          isNull,
          reason: '${entry.key}页在 880x600 下出现布局异常',
        );
      }
    });
  });
}
