import 'package:flutter_test/flutter_test.dart';

import 'package:vela/core/compiler/mihomo_compiler.dart';
import 'package:vela/core/compiler/singbox_compiler.dart';
import 'package:vela/core/ir/profile.dart';
import 'package:vela/core/ir/rule_set_registry.dart';
import 'package:vela/core/lint/lint_engine.dart';
import 'package:vela/core/storage/profile_store.dart';

Profile _demoProfile({CoreKind core = CoreKind.mihomo}) {
  return Profile(
    id: 'test',
    name: '测试配置',
    coreKind: core,
    source: const ProfileSource(type: ProfileSourceType.manual),
    nodes: [
      const ProxyNode(
        id: 'n1',
        name: '香港-01',
        protocol: ProxyProtocol.vless,
        server: 'hk.example.com',
        port: 443,
        params: {'uuid': 'uuid-1'},
      ),
      const ProxyNode(
        id: 'n2',
        name: '美国-01',
        protocol: ProxyProtocol.hysteria2,
        server: 'us.example.com',
        port: 443,
        params: {'password': 'pw'},
      ),
      // 故意放一个 sing-box 不支持的节点
      const ProxyNode(
        id: 'n3',
        name: 'SSR-旧节点',
        protocol: ProxyProtocol.ssr,
        server: 'old.example.com',
        port: 8388,
      ),
    ],
    groups: const [
      ProxyGroup(
        id: 'g-select',
        name: '手动选择',
        type: ProxyGroupType.select,
        members: ['n1', 'n2'],
      ),
    ],
    rules: [
      const RuleEntry(
        id: 'r-direct',
        action: RuleAction.direct,
        ruleSetIds: {'geosite-cn'},
        domains: ['example.cn'],
      ),
      const RuleEntry(
        id: 'r-proxy',
        action: RuleAction.proxy,
        ruleSetIds: {'telegram'},
        outboundGroupId: 'g-select',
      ),
    ],
    dns: const DnsConfig(
      mode: DnsMode.fakeIp,
      fakeIpFilter: ['*.lan'],
      followRules: true,
    ),
    inbound: const InboundConfig(mode: AccessMode.mixed),
  );
}

void main() {
  test('mihomo 编译器产出合法骨架', () {
    final yaml = const MihomoCompiler().compileToString(_demoProfile());
    expect(yaml, contains('mixed-port: 7890'));
    expect(yaml, contains('fake-ip'));
    expect(yaml, contains('RULE-SET,geosite-cn,DIRECT'));
    expect(yaml, contains('MATCH,手动选择'));
    expect(yaml, contains('rule-providers:'));
    expect(yaml, contains('geosite/cn.mrs'));
  });

  test('sing-box 编译器产出 rule-set 格式', () {
    final json = const SingboxCompiler().compile(_demoProfile(core: CoreKind.singbox));
    expect(json['route'], isA<Map>());
    final route = json['route'] as Map<Object?, Object?>;
    final ruleSets = route['rule_set'] as List<Object?>;
    expect(ruleSets, isNotEmpty);
    expect((ruleSets.first as Map<Object?, Object?>)['format'], 'binary');
    // SSR 节点应被跳过（supportedOn 检查在编译器内）
    final outbounds = json['outbounds'] as List<Object?>;
    expect(
      outbounds.any((o) => (o as Map<Object?, Object?>)['tag'] == 'SSR-旧节点'),
      isFalse,
    );
  });

  test('sing-box 编译器跳过不支持的节点（兜底防线，UX 层由 Lint 报 E001）', () {
    // 即使节点未被上游过滤，编译器也不应把不支持协议写入配置
    final json = const SingboxCompiler()
        .compile(_demoProfile(core: CoreKind.singbox).copyWith(nodes: [
      const ProxyNode(
        id: 'n9',
        name: 'ssr',
        protocol: ProxyProtocol.ssr,
        server: 'x',
        port: 1,
      ),
    ]));
    final outbounds = json['outbounds'] as List<Object?>;
    expect(
      outbounds.any((o) => (o as Map<Object?, Object?>)['tag'] == 'ssr'),
      isFalse,
    );
  });

  test('Lint：SSR 节点在 sing-box 下报 error，在 mihomo 下不报', () {
    const engine = LintEngine();
    final issuesSb = engine.run(_demoProfile(core: CoreKind.singbox));
    expect(issuesSb.any((i) => i.code == 'E001'), isTrue);

    final issuesMh = engine.run(_demoProfile(core: CoreKind.mihomo));
    expect(issuesMh.any((i) => i.code == 'E001'), isFalse);
  });

  test('Lint：fake-ip 无过滤器告警且可自动修复', () {
    const engine = LintEngine();
    var p = _demoProfile();
    p = p.copyWith(
      dns: const DnsConfig(mode: DnsMode.fakeIp, fakeIpFilter: []),
    );
    final issues = engine.run(p);
    final w101 = issues.where((i) => i.code == 'W101').toList();
    expect(w101, hasLength(1));
    expect(w101.first.autoFixable, isTrue);
  });

  test('Override 补丁层：禁用规则集 + 自定义规则生效', () {
    const patch = UserPatch(
      ruleSetToggles: {'telegram': false},
      addedRules: [
        RuleEntry(id: 'custom-1', action: RuleAction.direct, domains: ['my.company.cn']),
      ],
    );
    final effective = patch.applyTo(_demoProfile());
    final proxyRule = effective.rules.firstWhere((r) => r.id == 'r-proxy');
    expect(proxyRule.enabled, isFalse); // telegram 被补丁关闭 → 整条规则禁用
    expect(effective.rules.any((r) => r.id == 'custom-1'), isTrue);
  });

  test('规则集注册表：所有内置条目双格式 URL 齐全', () {
    for (final rs in RuleSetRegistry.builtin) {
      expect(rs.singboxUrl.endsWith('.srs'), isTrue, reason: rs.id);
      expect(rs.mihomoUrl.endsWith('.mrs'), isTrue, reason: rs.id);
      expect(RuleSetRegistry.byId(rs.id), isNotNull);
    }
  });
}
