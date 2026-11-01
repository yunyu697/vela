/// 订阅更新的核心逻辑测试。
///
/// 不发真实网络请求：通过 [ProfileRepository.debugFetcher] 注入假的抓取
/// 结果，数据目录指向临时目录（[AppPaths.overrideSupportDir]）。
///
/// 重点不是「能拉到节点」，而是**拉到节点之后配置还能不能用**：
/// 分组成员会引用节点 id，订阅一换节点 id 就变，悬空成员会让分组变成
/// `proxies: []`，内核直接拒绝启动。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/ir/profile.dart';
import 'package:vela/core/storage/kv_store.dart';
import 'package:vela/core/storage/profile_repository.dart';
import 'package:vela/core/subscribe/subscription_fetcher.dart';

/// 与 ShareLinkParser 的 id 规则保持一致：协议://服务器:端口/名称。
ProxyNode _node(String name, {String server = 'hk.example.com'}) => ProxyNode(
      id: 'ss://$server:8388/$name',
      name: name,
      protocol: ProxyProtocol.ss,
      server: server,
      port: 8388,
    );

Profile _subscriptionProfile({
  required List<ProxyNode> nodes,
  required List<ProxyGroup> groups,
  ProfileSource source = const ProfileSource(
    type: ProfileSourceType.subscription,
    url: 'https://sub.example.com/api',
  ),
}) =>
    Profile(
      id: 'p-sub',
      name: '机场订阅',
      coreKind: CoreKind.mihomo,
      source: source,
      nodes: nodes,
      groups: groups,
      rules: const [
        RuleEntry(id: 'r-proxy', action: RuleAction.proxy, outboundGroupId: 'g-select'),
      ],
    );

void main() {
  late Directory tmp;
  final repo = ProfileRepository.instance;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vela-sub-refresh');
    AppPaths.overrideSupportDir = tmp.path;
    repo.resetForTest();
    await repo.init();
  });

  tearDown(() async {
    repo.debugFetcher = null;
    AppPaths.overrideSupportDir = null;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('订阅更新', () {
    test('替换节点并记录同步时间', () async {
      final old = _node('香港-01');
      await repo.saveProfile(_subscriptionProfile(
        nodes: [old],
        groups: [
          ProxyGroup(
            id: 'g-select',
            name: '手动选择',
            type: ProxyGroupType.select,
            members: [old.id],
          ),
        ],
      ));
      expect(repo.metaOf('p-sub').syncedAt, isNull);

      final hk = _node('香港-02');
      final jp = _node('日本-01', server: 'jp.example.com');
      repo.debugFetcher = (url, core) async => SubscriptionFetchResult(
            nodes: [hk, jp],
            format: 'links',
          );

      final r = await repo.refreshSubscription('p-sub');

      expect(r.before, 1);
      expect(r.after, 2);
      expect(r.delta, 1);

      final saved = repo.profiles.single;
      expect(saved.nodes.map((n) => n.name), ['香港-02', '日本-01']);
      expect(repo.metaOf('p-sub').syncedAt, isNotNull);
    });

    test('节点 id 全换时分组退化为全部节点，不留空分组', () async {
      final old = _node('香港-01');
      await repo.saveProfile(_subscriptionProfile(
        nodes: [old],
        groups: [
          ProxyGroup(
            id: 'g-select',
            name: '手动选择',
            type: ProxyGroupType.select,
            members: [old.id],
          ),
        ],
      ));

      // 节点改名 → id 全变，旧成员一个都挂不上
      repo.debugFetcher = (url, core) async => SubscriptionFetchResult(
            nodes: [_node('HK-01'), _node('JP-01', server: 'jp.example.com')],
            format: 'links',
          );
      await repo.refreshSubscription('p-sub');

      final group = repo.profiles.single.groups.single;
      expect(group.members, isNotEmpty, reason: '空分组会让内核拒绝启动');
      expect(group.members, hasLength(2));
    });

    test('region 过滤器与分组引用在更新后保留', () {
      final nodes = [
        _node('香港-01'),
        _node('日本-01', server: 'jp.example.com'),
      ];
      final groups = [
        const ProxyGroup(
          id: 'g-auto',
          name: '自动选择',
          type: ProxyGroupType.urlTest,
          members: ['region:香港', 'g-select'],
        ),
        const ProxyGroup(
          id: 'g-select',
          name: '手动选择',
          type: ProxyGroupType.select,
          members: [],
        ),
      ];

      final rebound = ProfileRepository.rebindGroupMembers(groups, nodes);

      expect(rebound[0].members, ['region:香港', 'g-select']);
      // 一个节点都没剩的组补上全部节点，但不会把 region / 分组引用删掉
      expect(rebound[1].members, [nodes[0].id, nodes[1].id]);
    });

    test('订阅返回空节点时报错，且不改动原配置', () async {
      final old = _node('香港-01');
      await repo.saveProfile(_subscriptionProfile(
        nodes: [old],
        groups: const [],
      ));

      repo.debugFetcher = (url, core) async =>
          const SubscriptionFetchResult(nodes: [], format: 'links');

      await expectLater(
        repo.refreshSubscription('p-sub'),
        throwsA(isA<FormatException>()),
      );
      // 关键：不能「更新成功」但把配置写空
      expect(repo.profiles.single.nodes, hasLength(1));
      expect(repo.metaOf('p-sub').syncedAt, isNull);
    });

    test('非订阅来源直接拒绝，不发请求', () async {
      var called = false;
      await repo.saveProfile(_subscriptionProfile(
        nodes: [_node('香港-01')],
        groups: const [],
        source: const ProfileSource(type: ProfileSourceType.manual),
      ));
      repo.debugFetcher = (url, core) async {
        called = true;
        return const SubscriptionFetchResult(nodes: [], format: 'links');
      };

      await expectLater(
        repo.refreshSubscription('p-sub'),
        throwsA(isA<FormatException>()),
      );
      expect(called, isFalse, reason: '手工配置没有地址，不该发请求');
    });

    test('同步时间能落盘并读回', () async {
      await repo.saveProfile(_subscriptionProfile(
        nodes: [_node('香港-01')],
        groups: const [],
      ));
      repo.debugFetcher = (url, core) async => SubscriptionFetchResult(
            nodes: [_node('香港-01')],
            format: 'links',
          );
      await repo.refreshSubscription('p-sub');
      final at = repo.metaOf('p-sub').syncedAt;
      expect(at, isNotNull);

      // 重新载入（模拟下次启动）
      repo.resetForTest();
      await repo.init();
      final reloaded = repo.metaOf('p-sub').syncedAt;
      expect(reloaded, isNotNull);
      expect(
        reloaded!.difference(at!).inSeconds.abs(),
        lessThan(2),
        reason: '同步时间没有持久化',
      );
    });
  });
}
