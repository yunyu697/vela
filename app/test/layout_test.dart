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
import 'package:vela/core/settings/app_settings.dart';
import 'package:vela/core/storage/kv_store.dart';
import 'package:vela/core/storage/profile_store.dart';
import 'package:vela/features/profiles/profile_detail_page.dart';
import 'package:vela/features/profiles/profiles_page.dart';
import 'package:vela/features/run/run_page.dart';
import 'package:vela/features/settings/settings_page.dart';
import 'package:vela/features/wizard/wizard_controller.dart';
import 'package:vela/features/wizard/wizard_page.dart';
import 'package:vela/ui/adaptive.dart';
import 'package:vela/ui/app_shell.dart';
import 'package:vela/ui/vela_theme.dart';
import 'package:vela/ui/widgets.dart';

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

/// 「内核运行中」的完整快照：有状态、有实时流量、有连接。
final _runningDebug = RunPageDebug(
  status: const CoreStatus(CoreStatusKind.running),
  stats: const StatsSnapshot(
    upBps: 212 * 1024,
    downBps: 6 * 1024 * 1024,
    totalUp: 48 * 1024 * 1024,
    totalDown: 1024 * 1024 * 1024,
  ),
  connections: _sampleConnections,
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

  setUpAll(() async {
    await _loadRealFont();
    // 状态胶囊的脉冲点按帧相位渲染，不冻结会让含「运行中」的黄金图
    // 偶发不一致（实测在整套跑时命中过一次）。
    StatusPill.freezePulseAnimation = true;
  });

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

    // 检查面板此前只截过「未发现问题」。没有节点时是阻断态：右侧面板要列
    // 出 error 条目、主区域要显示「存在阻断级问题」，这两块的排版从没验证。
    testWidgets('向导 检查步骤 阻断态 桌面', (tester) async {
      await wizardAt(tester, WizardStep.review, const Size(1440, 900));
      // 阻断时摘要卡仍要在：曾经主区域只剩一句红字，桌面端大半屏空白，
      // 用户看不到自己到底配了什么，而修问题恰恰需要这份上下文。
      expect(find.text('配置名'), findsOneWidget, reason: '阻断态丢了配置摘要');
      expect(find.text('入站'), findsOneWidget);
      // 但既然生成被拦下，就没有配置可预览。
      expect(find.text('配置预览'), findsNothing, reason: '阻断态不该出现配置预览');
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_review_blocked_desktop.png'),
      );
    });

    testWidgets('向导 检查步骤 阻断态 手机', (tester) async {
      await wizardAt(tester, WizardStep.review, const Size(390, 844));
      expect(find.text('配置名'), findsOneWidget, reason: '阻断态丢了配置摘要');
      await expectLater(
        find.byType(WizardPage),
        matchesGoldenFile('goldens/wizard_review_blocked_phone.png'),
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

    // 连接表 / 流量 / 内核状态都来自 CoreManager 单例，测试里没有真实内核，
    // 页面永远停在「已停止 + 空连接 + 三个破折号」。用 RunPageDebug 把
    // 运行时数据钉住，才能截到运行中、异常这些状态下的排版。
    testWidgets('运行页 连接列表 桌面', (tester) async {
      await _pumpAt(
        tester,
        pageApp(RunPage(debug: RunPageDebug(connections: _sampleConnections))),
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
        pageApp(RunPage(debug: RunPageDebug(connections: _sampleConnections))),
        const Size(390, 844),
      );
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/run_connections_phone.png'),
      );
    });

    testWidgets('运行页 运行中 桌面', (tester) async {
      await _pumpAt(
        tester,
        pageApp(RunPage(debug: _runningDebug)),
        const Size(1440, 900),
      );
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/run_running_desktop.png'),
      );
    });

    testWidgets('运行页 运行中 手机', (tester) async {
      await _pumpAt(
        tester,
        pageApp(RunPage(debug: _runningDebug)),
        const Size(390, 844),
      );
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/run_running_phone.png'),
      );
    });

    testWidgets('运行页 启动失败 手机', (tester) async {
      await _pumpAt(
        tester,
        pageApp(
          RunPage(
            debug: const RunPageDebug(
              status: CoreStatus(CoreStatusKind.error),
              startError:
                  '内核进程退出，code=1: parse config: proxy 3 "HK-IEPL-01": '
                  'cipher "aes-256-gcm" is not supported by current build',
            ),
          ),
        ),
        const Size(390, 844),
      );
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/run_error_phone.png'),
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

    // 多选模式的顶部是「标题 + 导出 + 删除 + 关闭」四段，390dp 下留给
    // 标题的只剩一百来像素；此前从未截过，副标题会不会被挤没、按钮组
    // 会不会溢出都没有证据。
    Future<void> openSelectMode(WidgetTester tester, Size size) async {
      await _pumpAt(
        tester,
        pageApp(ProfilesPage(onOpenRun: () {})),
        size,
      );
      await tester.tap(find.byTooltip('多选'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
      // 选中第一张卡：副标题变成「已选中 1 项」，导出/删除从禁用转可用。
      final firstCard = find.text('香港 IEPL · 日常使用').first;
      await tester.tap(firstCard);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 120));
      }
    }

    testWidgets('配置页 多选模式 手机', (tester) async {
      await openSelectMode(tester, const Size(390, 844));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(ProfilesPage),
        matchesGoldenFile('goldens/profiles_select_phone.png'),
      );
    });

    testWidgets('配置页 多选模式 桌面', (tester) async {
      await openSelectMode(tester, const Size(1440, 900));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(ProfilesPage),
        matchesGoldenFile('goldens/profiles_select_desktop.png'),
      );
    });

    // ⋮ 菜单是 PopupMenuButton，弹层挂在 Overlay 上，截图要截整棵
    // MaterialApp 而不是 ProfilesPage——否则只拍到卡片、菜单是空的。
    // 窄屏下弹层贴着屏幕右边缘，最容易出「被裁掉一半」的问题。
    Future<void> openCardMenu(WidgetTester tester, Size size) async {
      await _pumpAt(
        tester,
        pageApp(ProfilesPage(onOpenRun: () {})),
        size,
      );
      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets('配置页 卡片菜单 手机', (tester) async {
      await openCardMenu(tester, const Size(390, 844));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/profiles_menu_phone.png'),
      );
    });

    testWidgets('配置页 卡片菜单 桌面', (tester) async {
      await openCardMenu(tester, const Size(1440, 900));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/profiles_menu_desktop.png'),
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

    // 设置页此前不存在：托盘能改的开关（系统代理 / 开机自启）在界面里
    // 完全不可达，移动端更是连托盘都没有。
    //
    // 数据目录用固定串钉住：真实路径带随机临时目录名，不钉的话这张
    // 黄金图每次跑都不一样。
    const pinnedDir = '~/Library/Application Support/dev.boxhub.boxhub';

    testWidgets('设置页 桌面', (tester) async {
      await _pumpAt(
        tester,
        pageApp(const SettingsPage(debugDataDir: pinnedDir)),
        const Size(1440, 900),
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(SettingsPage),
        matchesGoldenFile('goldens/settings_desktop.png'),
      );
    });

    testWidgets('设置页 手机', (tester) async {
      await _pumpAt(
        tester,
        pageApp(const SettingsPage(debugDataDir: pinnedDir)),
        const Size(390, 844),
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(SettingsPage),
        matchesGoldenFile('goldens/settings_phone.png'),
      );
    });

    testWidgets('设置页 主题切换立即生效', (tester) async {
      final settings = AppSettings.instance;
      final original = settings.themeMode;
      addTearDown(() => settings.setThemeMode(original));

      await _pumpAt(
        tester,
        pageApp(const SettingsPage(debugDataDir: pinnedDir)),
        const Size(390, 844),
      );
      await tester.tap(find.text('暗色'));
      await tester.pump();
      expect(settings.themeMode, ThemeMode.dark);
      // 页面上「当前：」那行要跟着变，否则用户不知道点没点上
      expect(find.text('当前：暗色'), findsOneWidget);
    });

    testWidgets('设置页 自动启动开关落盘', (tester) async {
      final settings = AppSettings.instance;
      addTearDown(() => settings.setAutoStartLastProfile(false));

      await _pumpAt(
        tester,
        pageApp(const SettingsPage(debugDataDir: pinnedDir)),
        const Size(390, 844),
      );
      expect(find.text('启动时自动启动上次配置'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(settings.autoStartLastProfile, isTrue);
    });

    // 详情页此前不存在：配置卡只有「4 节点 / 3 分组」四个数字，用户既
    // 看不到节点清单，也判断不出哪个节点是通的。
    Widget detail({ProfileDetailDebug? debug}) => pageApp(
          ProfileDetailPage(profileId: 'sample-hk', debug: debug),
        );

    testWidgets('详情页 桌面', (tester) async {
      await _pumpAt(tester, detail(), const Size(1440, 900));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(ProfileDetailPage),
        matchesGoldenFile('goldens/profile_detail_desktop.png'),
      );
    });

    testWidgets('详情页 手机', (tester) async {
      await _pumpAt(tester, detail(), const Size(390, 844));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(ProfileDetailPage),
        matchesGoldenFile('goldens/profile_detail_phone.png'),
      );
    });

    testWidgets('详情页 运行中（延迟与出口）', (tester) async {
      // 延迟分三档 + 一个超时 + 一个没测，四种徽标一次看全
      await _pumpAt(
        tester,
        detail(
          debug: const ProfileDetailDebug(
            runningProfileId: 'sample-hk',
            delays: {
              'n-hk-01': 45,
              'n-hk-02': 183,
              'n-jp-01': 612,
              'n-sg-01': null,
            },
            selection: {'g-select': '🇭🇰 香港 IEPL 专线 01'},
          ),
        ),
        const Size(1440, 900),
      );
      expect(find.text('45 ms'), findsOneWidget);
      expect(find.text('超时'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(ProfileDetailPage),
        matchesGoldenFile('goldens/profile_detail_running_desktop.png'),
      );
    });

    testWidgets('未运行时不能测速', (tester) async {
      await _pumpAt(tester, detail(), const Size(390, 844));
      final btn = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('测速'),
          matching: find.byType(TextButton),
        ),
      );
      expect(btn.onPressed, isNull, reason: '内核没跑，测速按钮不该可点');
      expect(find.textContaining('启动这份配置后才能测速'), findsOneWidget);
    });

    testWidgets('分组出口弹层列出成员且标出当前项', (tester) async {
      await _pumpAt(
        tester,
        detail(
          debug: const ProfileDetailDebug(
            runningProfileId: 'sample-hk',
            selection: {'g-select': '🇭🇰 香港 IEPL 专线 01'},
          ),
        ),
        const Size(1440, 900),
      );
      // 「节点选择」是手动分组，右侧显示当前出口并可点
      await tester.tap(find.text('🇭🇰 香港 IEPL 专线 01').last);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.text('切换出口'), findsOneWidget);
      expect(find.text('节点选择 · 3 个可选'), findsOneWidget);
      // 当前项打勾
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('从配置卡菜单进入详情', (tester) async {
      await _pumpAt(
        tester,
        pageApp(ProfilesPage(onOpenRun: () {})),
        const Size(1440, 900),
      );
      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.tap(find.text('详情'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.byType(ProfileDetailPage), findsOneWidget);
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

      testWidgets('设置页（暗色）@ $name', (tester) async {
        await _pumpAt(
          tester,
          pageApp(
            const SettingsPage(debugDataDir: '~/Library/Application Support/dev.boxhub.boxhub'),
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

    // 连接表在暗色下是一整片深色行 + 右侧小字，最容易出现「字和背景糊在
    // 一起」；浅色版已经截过，暗色一直是空白。
    testWidgets('暗色黄金图 连接列表 桌面', (tester) async {
      await _pumpAt(
        tester,
        pageApp(RunPage(debug: _runningDebug), brightness: Brightness.dark),
        const Size(1440, 900),
      );
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/dark_run_connections_desktop.png'),
      );
    });

    testWidgets('暗色黄金图 连接列表 手机', (tester) async {
      await _pumpAt(
        tester,
        pageApp(RunPage(debug: _runningDebug), brightness: Brightness.dark),
        const Size(390, 844),
      );
      await expectLater(
        find.byType(RunPage),
        matchesGoldenFile('goldens/dark_run_connections_phone.png'),
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

    // 设置页全是开关与分段控件，暗色下最容易出现「轨道和背景同色，
    // 看不出开还是关」。
    testWidgets('暗色黄金图 设置页 桌面', (tester) async {
      await _pumpAt(
        tester,
        pageApp(
          const SettingsPage(
            debugDataDir: '~/Library/Application Support/dev.boxhub.boxhub',
          ),
          brightness: Brightness.dark,
        ),
        const Size(1440, 900),
      );
      await expectLater(
        find.byType(SettingsPage),
        matchesGoldenFile('goldens/dark_settings_desktop.png'),
      );
    });

    // 详情页在暗色下最值得看的是延迟分档色（绿 / 琥珀 / 红）：
    // 浅色下够用的饱和度，压在深色卡片上常常偏暗或糊成一片。
    testWidgets('暗色黄金图 详情页 桌面', (tester) async {
      await _pumpAt(
        tester,
        pageApp(
          const ProfileDetailPage(
            profileId: 'sample-hk',
            debug: ProfileDetailDebug(
              runningProfileId: 'sample-hk',
              delays: {
                'n-hk-01': 45,
                'n-hk-02': 183,
                'n-jp-01': 612,
                'n-sg-01': null,
              },
              selection: {'g-select': '🇭🇰 香港 IEPL 专线 01'},
            ),
          ),
          brightness: Brightness.dark,
        ),
        const Size(1440, 900),
      );
      await expectLater(
        find.byType(ProfileDetailPage),
        matchesGoldenFile('goldens/dark_profile_detail_desktop.png'),
      );
    });
  });
}
