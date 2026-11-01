/// 响应式布局回归测试。
///
/// 覆盖三类诉求：
///  1. 窗口尺寸变化时元素重排，不出现溢出 / 错位 / 遮挡
///  2. 横竖屏自动识别并切换布局
///  3. 最小安全尺寸（880×600）下内容仍完整
///
/// 同时产出黄金图（`flutter test --update-goldens`）用于人工核对视觉效果。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/cores/core_adapter.dart';
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
  // 轮数按最坏链路估算：仓库 init 现在含 vault 打开 + 加密读写 +
  // chmod 子进程（每轮只推进一个 await 台阶，子进程一次就要占掉数轮）。
  // 80 轮覆盖「冷启动首个测试」的完整链路；40 轮在首测会偶发读不到数据。
  for (var i = 0; i < 80; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 15));
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

/// 生成一条 ss 分享链接（SIP002）。用于让向导进入「有节点」的真实状态。
String _ssLink(String name, String host, int port) {
  final cred = base64.encode(utf8.encode('aes-256-gcm:vela-demo'));
  return 'ss://$cred@$host:$port#${Uri.encodeComponent(name)}';
}

/// 一组典型连接：长域名、多跳出口链、UDP、零流量条目各一。
///
/// 故意不用 emoji 节点名——测试字体没有 emoji，会渲染成豆腐块，
/// 反而看不清真实的排版。规则名取真实形态（规则集 / 匹配器），
/// 不要用 'Proxy'，否则会和链路首项重复、看不出这是两段信息。
final _sampleConnections = <ConnectionInfo>[
  ConnectionInfo(
    id: 'c1',
    network: 'tcp',
    source: '127.0.0.1:52131',
    destination: 'rr1---sn-npoe7nsl.googlevideo.com:443',
    rule: 'GlobalMedia',
    chain: const ['Proxy', 'HK-IEPL-01'],
    upload: 128 * 1024,
    download: 4 * 1024 * 1024,
    start: DateTime(2026, 11, 1, 19, 20),
  ),
  ConnectionInfo(
    id: 'c2',
    network: 'tcp',
    source: '127.0.0.1:52144',
    destination: 'api.github.com:443',
    rule: 'Private',
    chain: const ['DIRECT'],
    upload: 3 * 1024,
    download: 42 * 1024,
    start: DateTime(2026, 11, 1, 19, 21),
  ),
  ConnectionInfo(
    id: 'c3',
    network: 'udp',
    source: '127.0.0.1:52150',
    destination: '8.8.8.8:53',
    rule: 'DNS',
    chain: const ['Proxy', 'JP-Tokyo-Relay', 'HK-IEPL-01'],
    upload: 1024,
    download: 2048,
    start: DateTime(2026, 11, 1, 19, 22),
  ),
  ConnectionInfo(
    id: 'c4',
    network: 'tcp',
    source: '127.0.0.1:52160',
    destination: 'cdn.jsdelivr.net:443',
    rule: 'Apple',
    chain: const ['Proxy', 'SG-Direct-01'],
    upload: 0,
    download: 0,
    start: DateTime(2026, 11, 1, 19, 23),
  ),
];

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

  Widget app(Widget home, {Brightness brightness = Brightness.light}) {
    // 主题整体套用真实字体：按钮 / 输入框等组件主题里自带 textStyle，
    // 只覆盖 textTheme 会让它们回落到测试默认字体（渲染成黑块）。
    final base = buildVelaTheme(
      brightness: brightness,
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
  Widget pageApp(Widget child, {Brightness brightness = Brightness.light}) =>
      app(
        AdaptiveBuilder(
          builder: (context, scope) => Scaffold(
            backgroundColor: Colors.transparent,
            body: VelaBackdrop(child: child),
          ),
        ),
        brightness: brightness,
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

    // 窄屏没有左侧步骤栏，只有一条横向 chip 条；七个 chip 在 390dp 下
    // 排不进一屏，切步后若不跟随，用户看不到自己在第几步。
    testWidgets('窄屏步骤条跟随当前步', (tester) async {
      await _pumpAt(
        tester,
        pageApp(const WizardPage(initialProfileName: '我的配置')),
        const Size(390, 844),
      );
      final state = tester.state<WizardPageState>(find.byType(WizardPage));

      for (var i = 0; i < WizardStep.dns.index; i++) {
        state.controller.next();
        for (var k = 0; k < 6; k++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
      }
      expect(state.controller.step, WizardStep.dns);

      final chip = tester.getRect(find.text(WizardStep.dns.label));
      expect(chip.left, greaterThanOrEqualTo(0),
          reason: '当前步骤 chip 被滚出了左边界');
      expect(chip.right, lessThanOrEqualTo(390),
          reason: '当前步骤 chip 被滚出了右边界');
    });
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

    // 向导只截第 1 步的话，「四段来源选择器在手机宽度下是否折行」
    // 「规则列表的选中条纹」「检查页的七行摘要 + 配置预览」
    // 这三类最容易崩的排版都覆盖不到，所以按步骤各补一张。
    Future<void> wizardAt(WidgetTester tester, WizardStep step, Size size,
        {bool withNodes = false}) async {
      await _pumpAt(
        tester,
        pageApp(const WizardPage(initialProfileName: '我的配置')),
        size,
      );
      final state = tester.state<WizardPageState>(find.byType(WizardPage));
      if (withNodes) {
        state.controller.importLinksText([
          _ssLink('🇭🇰 香港 IEPL 01', 'hk01.example.com', 443),
          _ssLink('🇯🇵 东京 中转 01', 'jp01.example.com', 8443),
          _ssLink('🇸🇬 新加坡 直连 01', 'sg01.example.com', 8388),
        ].join('\n'));
      }
      for (var i = 0; i < step.index; i++) {
        state.controller.next();
        for (var k = 0; k < 6; k++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
      }
    }

    testWidgets('向导 来源步骤 桌面', (tester) async {
      await wizardAt(tester, WizardStep.source, const Size(1440, 900));
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_source_desktop.png'),
      );
    });

    testWidgets('向导 来源步骤 手机', (tester) async {
      await wizardAt(tester, WizardStep.source, const Size(390, 844));
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_source_phone.png'),
      );
    });

    testWidgets('向导 规则步骤 桌面', (tester) async {
      await wizardAt(tester, WizardStep.rules, const Size(1440, 900));
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_rules_desktop.png'),
      );
    });

    testWidgets('向导 节点步骤 桌面', (tester) async {
      await wizardAt(
        tester,
        WizardStep.nodes,
        const Size(1440, 900),
        withNodes: true,
      );
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_nodes_desktop.png'),
      );
    });

    testWidgets('向导 DNS 步骤 桌面', (tester) async {
      await wizardAt(tester, WizardStep.dns, const Size(1440, 900));
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_dns_desktop.png'),
      );
    });

    testWidgets('向导 DNS 步骤 手机', (tester) async {
      await wizardAt(tester, WizardStep.dns, const Size(390, 844));
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_dns_phone.png'),
      );
    });

    testWidgets('向导 入站步骤 桌面', (tester) async {
      await wizardAt(tester, WizardStep.inbound, const Size(1440, 900));
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_inbound_desktop.png'),
      );
    });

    testWidgets('向导 检查步骤 桌面', (tester) async {
      await wizardAt(
        tester,
        WizardStep.review,
        const Size(1440, 900),
        withNodes: true,
      );
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_review_desktop.png'),
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

    // 连接表要靠真实内核跑起来才有数据，此前黄金图只能截到空状态。
    // 这里注入一组典型连接（含超长域名、多跳出口链、UDP），
    // 覆盖「窄屏下连接行是否挤成一团 / 域名被截断后还剩什么」。
    testWidgets('运行页 连接列表 桌面', (tester) async {
      await _pumpAt(
        tester,
        pageApp(RunPage(debugConnections: _sampleConnections)),
        const Size(1440, 900),
      );
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/run_connections_desktop.png'),
      );
    });

    testWidgets('运行页 连接列表 手机', (tester) async {
      await _pumpAt(
        tester,
        pageApp(RunPage(debugConnections: _sampleConnections)),
        const Size(390, 844),
      );
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/run_connections_phone.png'),
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

  // ------------------------------------------------------------ 暗色模式
  //
  // 暗色曾经是半成品（近黑画布 + 未打磨的对比度），当时把 ThemeMode
  // 硬编码成 light 规避「UI 变黑」。现在暗色是用户可配置项，必须有
  // 自己的守卫：布局断言防溢出，黄金图防对比度/配色回退。
  group('暗色模式', () {
    const darkSizes = ['phone_portrait', 'laptop', 'min_safe'];

    for (final name in darkSizes) {
      final size = _sizes[name]!;

      testWidgets('概览（暗色）@ $name', (tester) async {
        await _pumpAt(
          tester,
          app(const VelaShell(), brightness: Brightness.dark),
          size,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('配置页（暗色）@ $name', (tester) async {
        await _pumpAt(
          tester,
          pageApp(ProfilesPage(onOpenRun: () {}), brightness: Brightness.dark),
          size,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('运行页（暗色）@ $name', (tester) async {
        await _pumpAt(
          tester,
          pageApp(const RunPage(), brightness: Brightness.dark),
          size,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('向导（暗色）@ $name', (tester) async {
        await _pumpAt(
          tester,
          pageApp(
            const WizardPage(initialProfileName: '我的配置'),
            brightness: Brightness.dark,
          ),
          size,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('暗色黄金图 概览 桌面', (tester) async {
      await _pumpAt(
        tester,
        app(const VelaShell(), brightness: Brightness.dark),
        const Size(1280, 800),
      );
      await expectLater(
        find.byType(VelaShell),
        matchesGoldenFile('goldens/dark_home_laptop.png'),
      );
    });

    testWidgets('暗色黄金图 概览 手机', (tester) async {
      await _pumpAt(
        tester,
        app(const VelaShell(), brightness: Brightness.dark),
        const Size(390, 844),
      );
      await expectLater(
        find.byType(VelaShell),
        matchesGoldenFile('goldens/dark_home_phone.png'),
      );
    });

    testWidgets('暗色黄金图 配置页 桌面', (tester) async {
      await _pumpAt(
        tester,
        pageApp(ProfilesPage(onOpenRun: () {}), brightness: Brightness.dark),
        const Size(1440, 900),
      );
      await expectLater(
        find.byType(ProfilesPage),
        matchesGoldenFile('goldens/dark_profiles_desktop.png'),
      );
    });

    testWidgets('暗色黄金图 运行页 桌面', (tester) async {
      await _pumpAt(
        tester,
        pageApp(const RunPage(), brightness: Brightness.dark),
        const Size(1440, 900),
      );
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/dark_run_desktop.png'),
      );
    });

    testWidgets('暗色黄金图 向导 桌面', (tester) async {
      await _pumpAt(
        tester,
        pageApp(
          const WizardPage(initialProfileName: '我的配置'),
          brightness: Brightness.dark,
        ),
        const Size(1440, 900),
      );
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/dark_wizard_desktop.png'),
      );
    });
  });
}
