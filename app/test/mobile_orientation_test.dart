/// 移动端横竖屏自适应测试。
///
/// 用真实手机尺寸验证三种导航形态的切换：
///  - 竖屏手机 390×844（iPhone 14）：compact → 底部导航栏
///  - 横屏手机 844×390：宽 844 ∈ [640, 1000) → medium → 图标侧栏
///  - 平板横屏 1194×834（iPad Air）：expanded → 带文字侧栏
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vela/ui/adaptive.dart';

Widget _app() => const MaterialApp(
      home: AdaptiveBuilder(
        builder: _buildScaffold,
      ),
    );

Widget _buildScaffold(BuildContext context, AdaptiveScope scope) =>
    const AdaptiveScaffold(
      destinations: [
        AdaptiveDestination(label: '概览', icon: Icons.dashboard_outlined),
        AdaptiveDestination(label: '配置', icon: Icons.tune_outlined),
        AdaptiveDestination(
            label: '运行', icon: Icons.play_circle_outline_rounded),
      ],
      body: SizedBox.expand(),
    );

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('竖屏手机：底部导航栏，无侧栏', (tester) async {
    await _pump(tester, const Size(390, 844));
    expect(find.byKey(const ValueKey('vela-bottom-nav')), findsOneWidget,
        reason: '竖屏手机应显示底部导航栏');
    expect(find.byKey(const ValueKey('vela-side-nav')), findsNothing);
  });

  testWidgets('横屏手机：图标侧栏，无底部导航栏', (tester) async {
    await _pump(tester, const Size(844, 390));
    expect(find.byKey(const ValueKey('vela-side-nav')), findsOneWidget,
        reason: '横屏手机（宽 844）应显示侧栏');
    expect(find.byKey(const ValueKey('vela-bottom-nav')), findsNothing);
  });

  testWidgets('平板横屏：带文字侧栏', (tester) async {
    await _pump(tester, const Size(1194, 834));
    expect(find.byKey(const ValueKey('vela-side-nav')), findsOneWidget);
    expect(find.byKey(const ValueKey('vela-bottom-nav')), findsNothing);
    expect(find.text('概览'), findsOneWidget,
        reason: 'expanded 档侧栏应带文字标签');
  });

  testWidgets('旋转（尺寸变化）后导航形态跟随切换', (tester) async {
    await _pump(tester, const Size(390, 844));
    expect(find.byKey(const ValueKey('vela-bottom-nav')), findsOneWidget);

    // 模拟旋转到横屏
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vela-side-nav')), findsOneWidget,
        reason: '旋转后应立即切换为侧栏');
    expect(find.byKey(const ValueKey('vela-bottom-nav')), findsNothing);
  });
}
