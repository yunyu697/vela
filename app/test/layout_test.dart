/// 响应式布局回归测试。
///
/// 覆盖三类诉求：
///  1. 窗口尺寸变化时元素重排，不出现溢出 / 错位 / 遮挡
///  2. 横竖屏自动识别并切换布局
///  3. 最小安全尺寸（880×600）下内容仍完整
///
/// 同时产出黄金图（`flutter test --update-goldens`）用于人工核对视觉效果。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/ir/profile.dart';
import 'package:vela/core/storage/kv_store.dart';
import 'package:vela/core/storage/profile_store.dart';
import 'package:vela/features/profiles/profiles_page.dart';
import 'package:vela/features/run/run_page.dart';
import 'package:vela/features/wizard/wizard_controller.dart';
import 'package:vela/features/wizard/wizard_page.dart';
import 'package:vela/ui/adaptive.dart';
import 'package:vela/ui/app_shell.dart';
import 'package:vela/ui/vela_theme.dart';

/// 待测尺寸：覆盖手机竖屏 / 手机横屏 / 平板 / 桌面 / 超宽 / 最小安全尺寸。
const _sizes = <String, Size>{
  'phone_portrait': Size(390, 844),
  'phone_landscape': Size(844, 390),
  'tablet': Size(834, 1112),
  'laptop': Size(1280, 800),
  'desktop_wide': Size(1680, 1050),
  'min_safe': Size(880, 600),
};

Future<void> _pumpAt(
  WidgetTester tester,
  Widget child,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(child);
  await _settleAsyncIO(tester);
  // 分多次 pump 让入场动画走完：不能用 pumpAndSettle，
  // 因为状态呼吸灯是无限循环动画，会让它永不 settle。
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// 让页面内部的**真实**异步 IO（读取本地配置）跑完。
///
/// widget 测试默认跑在 fake-async 时钟里：`dart:io` 的文件读写由真实
/// 事件循环投递完成，回调却挂在 fake zone 的微任务队列上——只 `pump()`
/// 永远不会 flush（实测：仅 `pump(duration)` 循环时页面永远停在「加载中」）。
///
/// 正确姿势是两者交替：
///  - `runAsync` —— 切到真实 zone，让真实事件循环转起来，I/O 完成并入队；
///  - `pump(带 duration)` —— 推进 fake 时钟，顺带 flush 微任务队列，
///    驱动 await 链往下走一步（建目录 → exists → read → setState）。
Future<void> _settleAsyncIO(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump(const Duration(milliseconds: 1));
  }
}

/// 黄金图用真实字体渲染（默认测试字体是方块，无法肉眼核对排版）。
///
/// 加载 macOS 自带的 Arial Unicode（含中日韩字形）与 Flutter SDK 里的
/// MaterialIcons，仅测试环境使用。
const _testFontFamily = 'VelaTestFont';
const _testFontPath = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
const _iconFontPath =
    '/Users/tyler/WorkBuddy/2026-10-31-05-44-34/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';

Future<void> _loadRealFont() async {
  final file = File(_testFontPath);
  if (file.existsSync()) {
    final bytes = await file.readAsBytes();
    // 注册为两个族名：'VelaTestFont' 供全局主题使用，'monospace'
    // 供 InfoRow 等显式指定等宽字体的地方使用（否则渲染成黑块）。
    for (final family in [_testFontFamily, 'monospace']) {
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    }
  }
  final iconFile = File(_iconFontPath);
  if (iconFile.existsSync()) {
    final bytes = await iconFile.readAsBytes();
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}

// ------------------------------------------------------------ 样例数据
//
// 空状态只能覆盖「什么都没有」时的排版；真实内容（长名称、大数量节点、
// 多分组多规则）才是布局最容易崩的地方。所以布局测试统一注入样例配置。

Profile _sampleMihomoProfile() => Profile(
      id: 'sample-hk',
      name: '香港 IEPL · 日常使用',
      coreKind: CoreKind.mihomo,
      source: const ProfileSource(
        type: ProfileSourceType.subscription,
        url: 'https://example.com/subscribe?token=vela-demo-token',
      ),
      nodes: const [
        ProxyNode(
          id: 'n-hk-01',
          name: '🇭🇰 香港 IEPL 专线 01',
          protocol: ProxyProtocol.vless,
          server: 'hk01.example.com',
          port: 443,
        ),
        ProxyNode(
          id: 'n-hk-02',
          name: '🇭🇰 香港 IEPL 专线 02',
          protocol: ProxyProtocol.trojan,
          server: 'hk02.example.com',
          port: 443,
        ),
        ProxyNode(
          id: 'n-jp-01',
          name: '🇯🇵 日本东京 中转 01',
          protocol: ProxyProtocol.vmess,
          server: 'jp01.example.com',
          port: 443,
        ),
        ProxyNode(
          id: 'n-sg-01',
          name: '🇸🇬 新加坡 直连 01',
          protocol: ProxyProtocol.ss,
          server: 'sg01.example.com',
          port: 8388,
        ),
      ],
      groups: const [
        ProxyGroup(
          id: 'g-select',
          name: '节点选择',
          type: ProxyGroupType.select,
          members: ['n-hk-01', 'n-hk-02', 'n-jp-01'],
        ),
        ProxyGroup(
          id: 'g-auto',
          name: '自动选择',
          type: ProxyGroupType.urlTest,
          members: ['n-hk-01', 'n-jp-01', 'n-sg-01'],
        ),
        ProxyGroup(
          id: 'g-hk',
          name: '香港节点',
          type: ProxyGroupType.select,
          members: ['n-hk-01', 'n-hk-02'],
        ),
      ],
      rules: const [
        RuleEntry(
          id: 'r-ads',
          action: RuleAction.reject,
          ruleSetIds: {'geosite-ads'},
        ),
        RuleEntry(
          id: 'r-cn',
          action: RuleAction.direct,
          ruleSetIds: {'geosite-cn'},
        ),
        RuleEntry(
          id: 'r-media',
          action: RuleAction.proxy,
          ruleSetIds: {'geosite-netflix'},
          outboundGroupId: 'g-select',
        ),
        RuleEntry(
          id: 'r-custom',
          action: RuleAction.proxy,
          domains: ['vela.dev', 'githubusercontent.com'],
          outboundGroupId: 'g-auto',
        ),
      ],
    );

Profile _sampleSingboxProfile() => Profile(
      id: 'sample-sing',
      name: '全局 · sing-box 精简版',
      coreKind: CoreKind.singbox,
      source: const ProfileSource(type: ProfileSourceType.manual),
      nodes: const [
        ProxyNode(
          id: 'n-us-01',
          name: '🇺🇸 美国洛杉矶 中转 01',
          protocol: ProxyProtocol.hysteria2,
          server: 'us01.example.com',
          port: 8443,
        ),
      ],
      groups: const [
        ProxyGroup(
          id: 'g-all',
          name: '全部节点',
          type: ProxyGroupType.select,
          members: ['n-us-01'],
        ),
      ],
      rules: const [
        RuleEntry(
          id: 'r-dns',
          action: RuleAction.direct,
          ipCidrs: ['geoip:cn'],
        ),
      ],
    );

/// 把样例配置写入临时数据目录（模拟用户已有配置的状态）。
Future<void> _seedSampleProfiles(Directory dir) async {
  final kv = await KvStore.open('${dir.path}/profiles.json');
  final store = ProfileStore(kv);
  await store.saveBase(_sampleMihomoProfile());
  await store.saveBase(_sampleSingboxProfile());
}

void main() {
  late Directory tmp;
  late Directory emptyTmp;

  setUpAll(_loadRealFont);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vela_layout_test');
    emptyTmp = await Directory.systemTemp.createTemp('vela_layout_empty');
    AppPaths.overrideSupportDir = tmp.path;
    // 注入样例配置：让所有布局断言跑在「有内容」的真实形态上
    await _seedSampleProfiles(tmp);
  });

  tearDown(() async {
    AppPaths.overrideSupportDir = null;
    for (final d in [tmp, emptyTmp]) {
      if (d.existsSync()) {
        await d.delete(recursive: true);
      }
    }
  });

  Widget app(Widget home) {
    // 主题整体套用真实字体：按钮 / 输入框等组件主题里自带 textStyle，
    // 只覆盖 textTheme 会让它们回落到测试默认字体（渲染成黑块）。
    final base = buildVelaTheme(
      brightness: Brightness.light,
      fontFamily: _testFontFamily,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: base,
      home: home,
    );
  }

  /// 单页宿主：补上外壳提供的自适应上下文与渐变背景，
  /// 让独立页面的黄金图与真实界面观感一致。
  Widget pageApp(Widget child) => app(
        AdaptiveBuilder(
          builder: (context, scope) => Scaffold(
            backgroundColor: Colors.transparent,
            body: VelaBackdrop(child: child),
          ),
        ),
      );

  group('外壳与概览页', () {
    for (final entry in _sizes.entries) {
      testWidgets('概览 @ ${entry.key}', (tester) async {
        await _pumpAt(tester, app(const VelaShell()), entry.value);
        expect(
          tester.takeException(),
          isNull,
          reason: '概览页在 ${entry.value} 下出现布局异常',
        );
      });

      testWidgets('配置页 @ ${entry.key}', (tester) async {
        await _pumpAt(
          tester,
          pageApp(ProfilesPage(onOpenRun: () {})),
          entry.value,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '配置页在 ${entry.value} 下出现布局异常',
        );
      });

      testWidgets('运行页 @ ${entry.key}', (tester) async {
        await _pumpAt(tester, pageApp(const RunPage()), entry.value);
        expect(
          tester.takeException(),
          isNull,
          reason: '运行页在 ${entry.value} 下出现布局异常',
        );
      });

      testWidgets('向导 @ ${entry.key}', (tester) async {
        await _pumpAt(tester, pageApp(const WizardPage(initialProfileName: '我的配置')), entry.value);
        expect(
          tester.takeException(),
          isNull,
          reason: '向导在 ${entry.value} 下出现布局异常',
        );
      });
    }
  });

  group('向导各步骤', () {
    for (final entry in _sizes.entries) {
      testWidgets('逐步切换 @ ${entry.key}', (tester) async {
        await _pumpAt(tester, pageApp(const WizardPage(initialProfileName: '我的配置')), entry.value);
        expect(tester.takeException(), isNull);

        final state = tester.state<WizardPageState>(find.byType(WizardPage));
        // 走完全部 7 步，每一步都检查是否有溢出
        for (var i = 0; i < WizardStep.values.length; i++) {
          state.controller.next();
          for (var k = 0; k < 6; k++) {
            await tester.pump(const Duration(milliseconds: 120));
          }
          expect(
            tester.takeException(),
            isNull,
            reason: '向导第 ${i + 2} 步在 ${entry.value} 下出现布局异常',
          );
        }
      });
    }
  });

  group('样例数据加载', () {
    // 守卫：fake-async 下真实 IO 不会自动完成，若这里挂了说明
    // 页面读到的是空状态，黄金图就失去了覆盖真实内容的作用。
    testWidgets('配置页读到已保存的配置', (tester) async {
      await _pumpAt(
        tester,
        pageApp(ProfilesPage(onOpenRun: () {})),
        const Size(1440, 900),
      );
      expect(find.text('香港 IEPL · 日常使用'), findsOneWidget);
      expect(find.text('全局 · sing-box 精简版'), findsOneWidget);
      expect(find.text('节点'), findsNWidgets(2));
    });

    testWidgets('运行页读到已保存的配置', (tester) async {
      await _pumpAt(tester, pageApp(const RunPage()), const Size(1440, 900));
      expect(find.text('控制台'), findsOneWidget);
      expect(find.text('香港 IEPL · 日常使用'), findsWidgets);
      expect(find.text('实时仪表盘'), findsOneWidget);
    });

    // 回归：列宽若按「带内边距前的宽度」计算，宽屏会提前换行、
    // 右半屏整片空置。这里直接断言两张卡片是并排的。
    testWidgets('宽屏配置卡两列并排', (tester) async {
      await _pumpAt(
        tester,
        pageApp(ProfilesPage(onOpenRun: () {})),
        const Size(1440, 900),
      );
      final a = tester.getTopLeft(find.text('香港 IEPL · 日常使用'));
      final b = tester.getTopLeft(find.text('全局 · sing-box 精简版'));
      expect(
        b.dx,
        greaterThan(a.dx),
        reason: '宽屏下两张配置卡应横向并排，而不是各自占满一行',
      );
    });
  });

  group('横竖屏识别', () {
    testWidgets('竖屏与横屏使用不同的导航形态', (tester) async {
      await _pumpAt(tester, app(const VelaShell()), const Size(390, 844));
      // 窄屏：底部导航
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);

      await _pumpAt(tester, app(const VelaShell()), const Size(1280, 800));
      // 宽屏：侧边导航
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(NavigationRail), findsNothing);
      // 宽屏使用自定义侧栏（Vela 自绘，非 Material NavigationRail）
      expect(find.text('概览'), findsWidgets);
    });
  });

  group('黄金图', () {
    for (final entry in _sizes.entries) {
      testWidgets('概览 ${entry.key}', (tester) async {
        await _pumpAt(tester, app(const VelaShell()), entry.value);
        await expectLater(
          find.byType(VelaShell),
          matchesGoldenFile('goldens/home_${entry.key}.png'),
        );
      });
    }

    testWidgets('向导 桌面', (tester) async {
      await _pumpAt(tester, pageApp(const WizardPage(initialProfileName: '我的配置')), const Size(1440, 900));
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_desktop.png'),
      );
    });

    testWidgets('向导 手机', (tester) async {
      await _pumpAt(tester, pageApp(const WizardPage(initialProfileName: '我的配置')), const Size(390, 844));
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_phone.png'),
      );
    });

    testWidgets('运行页 桌面', (tester) async {
      await _pumpAt(tester, pageApp(const RunPage()), const Size(1440, 900));
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/run_desktop.png'),
      );
    });

    testWidgets('运行页 手机', (tester) async {
      await _pumpAt(tester, pageApp(const RunPage()), const Size(390, 844));
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/run_phone.png'),
      );
    });

    testWidgets('配置页 桌面', (tester) async {
      await _pumpAt(
        tester,
        pageApp(ProfilesPage(onOpenRun: () {})),
        const Size(1440, 900),
      );
      await expectLater(
        find.byType(ProfilesPage),
        matchesGoldenFile('goldens/profiles_desktop.png'),
      );
    });

    testWidgets('配置页 手机', (tester) async {
      await _pumpAt(
        tester,
        pageApp(ProfilesPage(onOpenRun: () {})),
        const Size(390, 844),
      );
      await expectLater(
        find.byType(ProfilesPage),
        matchesGoldenFile('goldens/profiles_phone.png'),
      );
    });

    testWidgets('运行页 空状态', (tester) async {
      // 切到一个空数据目录，覆盖「还没有任何配置」的首屏
      AppPaths.overrideSupportDir = emptyTmp.path;
      await _pumpAt(tester, pageApp(const RunPage()), const Size(1440, 900));
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/run_empty_desktop.png'),
      );
    });
  });
}
