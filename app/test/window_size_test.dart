/// 桌面端窗口档位钳制回归测试。
///
/// 背景：用户实测「侧栏有时消失」。桌面最小窗口宽度 880，compact 档
/// （<640，底部导航替代侧栏）本不该出现；但窗口动画/全屏过渡/Stage
/// Manager 可能短暂上报小尺寸。桌面端必须钳制为 medium 保证侧栏常在。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vela/ui/adaptive.dart';

void main() {
  group('windowSizeFor 桌面钳制', () {
    testWidgets('macOS 上任何宽度都不落入 compact', (tester) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

        expect(windowSizeFor(880), WindowSize.medium);
        // 瞬态小尺寸：不允许掉进 compact（底部导航替代侧栏）
        expect(windowSizeFor(300), WindowSize.medium);
        expect(windowSizeFor(0), WindowSize.medium);
        expect(windowSizeFor(-40), WindowSize.medium);
        expect(windowSizeFor(1000), WindowSize.expanded);
        expect(windowSizeFor(1400), WindowSize.wide);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('移动端保留 compact 档（手机竖屏需要底部导航）', (tester) async {
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        expect(windowSizeFor(360), WindowSize.compact);
        expect(windowSizeFor(640), WindowSize.medium);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
