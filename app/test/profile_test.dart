/// 性能剖析：统计「每帧重建了哪些 widget」。
///
/// 用 [debugPrintRebuildDirtyWidgets] 让 Flutter 在每次 rebuild 时打印
/// widget 类型名，聚合后即可看出是谁在每帧被重建——这是增量渲染开销的
/// 直接来源。
///
/// 用法：`flutter test test/profile_test.dart` 后看控制台的 [PROF] 输出。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/storage/kv_store.dart';
import 'package:vela/features/home/home_page.dart';
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

/// 收集 rebuild 打印。
class _RebuildCounter {
  final Map<String, int> mounts = {}; // 首次挂载 Building
  final Map<String, int> rebuilds = {}; // 每帧更新 Rebuilding
  late final void Function(String?, {int? wrapWidth}) original;

  void start() {
    original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message == null) return;
      // Flutter 的格式："Building Foo" / "Rebuilding Foo"
      final m = RegExp(r'^(Building|Rebuilding)\s+(.+)$').firstMatch(
        message.trim(),
      );
      if (m != null) {
        final map = m.group(1) == 'Building' ? mounts : rebuilds;
        final name = m.group(2)!.trim();
        map[name] = (map[name] ?? 0) + 1;
      }
    };
  }

  void stop() {
    debugPrint = original;
  }

  static void _dump(String title, Map<String, int> counts) {
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    debugPrint('[PROF] --- $title: 总 ${counts.values.fold<int>(0, (a, b) => a + b)} ---');
    for (final e in sorted.take(12)) {
      debugPrint('[PROF] ${e.value}x  ${e.key}');
    }
  }

  void report(String title) {
    debugPrint('[PROF] ===== $title =====');
    _dump('挂载 Building', mounts);
    _dump('更新 Rebuilding', rebuilds);
  }
}

void main() {
  late Directory tmp;

  setUpAll(_loadRealFont);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vela_profile_test');
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

  testWidgets('概览页 空闲期重建', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(HomePage(onOpenProfiles: () {}, onOpenRun: () {})),
    );
    // 等入场动画结束
    await tester.pump(const Duration(milliseconds: 900));

    final counter = _RebuildCounter();
    counter.start();
    debugPrintRebuildDirtyWidgets = true;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrintRebuildDirtyWidgets = false;
    counter.stop();
    counter.report('概览页 空闲期 20 帧重建统计');
  });

  testWidgets('概览页 入场期重建', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final counter = _RebuildCounter();
    counter.start();
    debugPrintRebuildDirtyWidgets = true;
    await tester.pumpWidget(
      app(HomePage(onOpenProfiles: () {}, onOpenRun: () {})),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrintRebuildDirtyWidgets = false;
    counter.stop();
    counter.report('概览页 入场期 30 帧重建统计');
  });

  testWidgets('运行页 空闲期重建', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const RunPage()));
    await tester.pump(const Duration(milliseconds: 600));

    final counter = _RebuildCounter();
    counter.start();
    debugPrintRebuildDirtyWidgets = true;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrintRebuildDirtyWidgets = false;
    counter.stop();
    counter.report('运行页 空闲期 20 帧重建统计');
  });

  testWidgets('向导页 入场期重建', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final counter = _RebuildCounter();
    counter.start();
    debugPrintRebuildDirtyWidgets = true;
    await tester.pumpWidget(app(const WizardPage()));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrintRebuildDirtyWidgets = false;
    counter.stop();
    counter.report('向导页 入场期 30 帧重建统计');
  });
}
