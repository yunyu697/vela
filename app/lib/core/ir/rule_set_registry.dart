/// 内置规则集注册表。
///
/// 每条规则集同时声明 sing-box 的远程 .srs（二进制 rule-set，
/// 体积小、适合 iOS NetworkExtension 内存受限场景）和 mihomo
/// rule-providers 的 .mrs。编译器按所选内核自动取对应 URL。
///
/// 注册表支持通过远程清单（JSON）刷新，不随 App 发版更新。
library;

import 'profile.dart';

class BuiltinRuleSet {
  const BuiltinRuleSet({
    required this.id,
    required this.name,
    required this.description,
    required this.behavior,
    required this.singboxUrl,
    required this.mihomoUrl,
    required this.suggestedAction,
  });

  final String id;
  final String name;
  final String description;

  /// domain | ip — 决定 mihomo rule-provider 的 behavior 与
  /// sing-box rule-set 的 type。
  final String behavior;

  final String singboxUrl;
  final String mihomoUrl;
  final RuleAction suggestedAction;
}

class RuleSetRegistry {
  RuleSetRegistry._();

  // meta 分支提供 .mrs（mihomo rule-providers），sing 分支提供 .srs
  // （sing-box rule-set）。注意文件名不带 geosite-/geoip- 前缀。
  static const _mihomoBase =
      'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo';
  static const _singboxBase =
      'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo';

  /// 内置规则集。向导里以卡片（芯片）形式呈现，点选即用。
  static final List<BuiltinRuleSet> builtin = [
    const BuiltinRuleSet(
      id: 'geosite-cn',
      name: '国内域名直连',
      description: 'geosite-cn 大陆常见域名，直连以保证速度',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/cn.srs',
      mihomoUrl: '$_mihomoBase/geosite/cn.mrs',
      suggestedAction: RuleAction.direct,
    ),
    const BuiltinRuleSet(
      id: 'geoip-cn',
      name: '国内 IP 直连',
      description: 'geoip-cn 大陆 IP 段，直连',
      behavior: 'ip',
      singboxUrl: '$_singboxBase/geoip/cn.srs',
      mihomoUrl: '$_mihomoBase/geoip/cn.mrs',
      suggestedAction: RuleAction.direct,
    ),
    const BuiltinRuleSet(
      id: 'ads-all',
      name: '去广告',
      description: 'category-ads-all 广告与追踪域名拦截',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/category-ads-all.srs',
      mihomoUrl: '$_mihomoBase/geosite/category-ads-all.mrs',
      suggestedAction: RuleAction.reject,
    ),
    const BuiltinRuleSet(
      id: 'telegram',
      name: 'Telegram',
      description: 'Telegram 域名与 IP 段',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/telegram.srs',
      mihomoUrl: '$_mihomoBase/geosite/telegram.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'youtube',
      name: 'YouTube',
      description: 'YouTube 全套域名',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/youtube.srs',
      mihomoUrl: '$_mihomoBase/geosite/youtube.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'netflix',
      name: 'Netflix',
      description: 'Netflix 域名与 IP（建议选解锁节点）',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/netflix.srs',
      mihomoUrl: '$_mihomoBase/geosite/netflix.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'disney',
      name: 'Disney+',
      description: 'Disney+ 流媒体',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/disney.srs',
      mihomoUrl: '$_mihomoBase/geosite/disney.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'openai',
      name: 'AI 服务',
      description: 'OpenAI / Claude / Gemini 等 AI 服务',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/openai.srs',
      mihomoUrl: '$_mihomoBase/geosite/openai.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'google',
      name: 'Google',
      description: 'Google 全套服务',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/google.srs',
      mihomoUrl: '$_mihomoBase/geosite/google.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'github',
      name: 'GitHub',
      description: 'GitHub 与 GitLab',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/github.srs',
      mihomoUrl: '$_mihomoBase/geosite/github.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'apple-cn',
      name: 'Apple 中国',
      description: 'Apple 在华服务直连，改善 App Store / iCloud 速度',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/apple-cn.srs',
      mihomoUrl: '$_mihomoBase/geosite/apple-cn.mrs',
      suggestedAction: RuleAction.direct,
    ),
    const BuiltinRuleSet(
      id: 'games-cn',
      name: '游戏（国内）',
      description: '国内游戏平台与联机服务直连',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/category-games@cn.srs',
      mihomoUrl: '$_mihomoBase/geosite/category-games@cn.mrs',
      suggestedAction: RuleAction.direct,
    ),
    const BuiltinRuleSet(
      id: 'games-global',
      name: '游戏（全球）',
      description: 'Steam / Epic / 主机联机等国际游戏平台',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/category-games.srs',
      mihomoUrl: '$_mihomoBase/geosite/category-games.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'steam',
      name: 'Steam',
      description: 'Steam 商店与社区（创意工坊加速常用）',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/steam.srs',
      mihomoUrl: '$_mihomoBase/geosite/steam.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'spotify',
      name: 'Spotify',
      description: 'Spotify 流媒体音乐',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/spotify.srs',
      mihomoUrl: '$_mihomoBase/geosite/spotify.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'tiktok',
      name: 'TikTok / 抖音国际',
      description: 'TikTok 与字节海外服务',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/tiktok.srs',
      mihomoUrl: '$_mihomoBase/geosite/tiktok.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'bilibili',
      name: '哔哩哔哩',
      description: 'B 站主站与 API，直连保证清晰度与速度',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/bilibili.srs',
      mihomoUrl: '$_mihomoBase/geosite/bilibili.mrs',
      suggestedAction: RuleAction.direct,
    ),
    const BuiltinRuleSet(
      id: 'microsoft',
      name: 'Microsoft',
      description: '微软全家桶（Office / Windows 更新等，国内可直连）',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/microsoft.srs',
      mihomoUrl: '$_mihomoBase/geosite/microsoft.mrs',
      suggestedAction: RuleAction.direct,
    ),
    const BuiltinRuleSet(
      id: 'cloudflare',
      name: 'Cloudflare',
      description: 'Cloudflare 与 1.1.1.1 相关服务',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/cloudflare.srs',
      mihomoUrl: '$_mihomoBase/geosite/cloudflare.mrs',
      suggestedAction: RuleAction.proxy,
    ),
    const BuiltinRuleSet(
      id: 'speedtest',
      name: 'Speedtest 测速',
      description: 'Ookla Speedtest 及各运营商测速点，直连测真实带宽',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/category-speedtest.srs',
      mihomoUrl: '$_mihomoBase/geosite/category-speedtest.mrs',
      suggestedAction: RuleAction.direct,
    ),
    const BuiltinRuleSet(
      id: 'apple',
      name: 'Apple（国际）',
      description: 'Apple 国际服务（TestFlight / Maps 等）',
      behavior: 'domain',
      singboxUrl: '$_singboxBase/geosite/apple.srs',
      mihomoUrl: '$_mihomoBase/geosite/apple.mrs',
      suggestedAction: RuleAction.proxy,
    ),
  ];

  static final Map<String, BuiltinRuleSet> _byId = {
    for (final rs in builtin) rs.id: rs,
  };

  static BuiltinRuleSet? byId(String id) => _byId[id];

  /// 应用启动时可用远程清单刷新（保留给 M1 后的在线更新）。
  static void applyRemoteManifest(List<BuiltinRuleSet> remote) {
    builtin
      ..clear()
      ..addAll(remote);
    _byId
      ..clear()
      ..addAll({for (final rs in remote) rs.id: rs});
  }
}

/// 常用场景预设：一键勾选一组规则集。
///
/// 场景只是「起点」——应用后用户仍可在规则步骤里自由增删；
/// 当前勾选恰好等于某场景集合时，该场景卡片显示为选中态。
class RuleScenario {
  const RuleScenario({
    required this.id,
    required this.name,
    required this.description,
    required this.ruleSetIds,
  });

  final String id;
  final String name;
  final String description;

  /// 应用该场景时应勾选的规则集（须都存在于 [RuleSetRegistry.builtin]）。
  final List<String> ruleSetIds;
}

class RuleScenarios {
  RuleScenarios._();

  /// 内置场景。第一个是向导默认。
  static final List<RuleScenario> builtin = [
    const RuleScenario(
      id: 'balanced',
      name: '日常均衡',
      description: '国内直连 + 常用服务代理 + 去广告，适合大多数人',
      ruleSetIds: [
        'geosite-cn', 'geoip-cn', 'ads-all', 'apple-cn',
        'google', 'github', 'telegram',
      ],
    ),
    const RuleScenario(
      id: 'streaming',
      name: '流媒体影音',
      description: 'YouTube / Netflix / Disney+ / Spotify / TikTok 全解锁',
      ruleSetIds: [
        'geosite-cn', 'geoip-cn', 'ads-all', 'bilibili',
        'youtube', 'netflix', 'disney', 'spotify', 'tiktok',
      ],
    ),
    const RuleScenario(
      id: 'ai-dev',
      name: 'AI 与开发者',
      description: 'AI 服务 + Google / GitHub / Cloudflare 稳定代理',
      ruleSetIds: [
        'geosite-cn', 'geoip-cn', 'openai', 'google',
        'github', 'cloudflare', 'microsoft',
      ],
    ),
    const RuleScenario(
      id: 'gaming',
      name: '游戏加速',
      description: '国内游戏直连，国际平台与 Steam 走代理',
      ruleSetIds: [
        'geosite-cn', 'geoip-cn', 'games-cn',
        'games-global', 'steam', 'speedtest',
      ],
    ),
    const RuleScenario(
      id: 'global',
      name: '全局代理',
      description: '仅国内域名/IP 与测速直连，其余全部走代理',
      ruleSetIds: ['geosite-cn', 'geoip-cn', 'speedtest'],
    ),
    const RuleScenario(
      id: 'minimal',
      name: '极简直连',
      description: '只保证国内直连与基础去广告，规则最少、内存占用最小',
      ruleSetIds: ['geosite-cn', 'geoip-cn', 'ads-all'],
    ),
  ];

  static final Map<String, RuleScenario> _byId = {
    for (final s in builtin) s.id: s,
  };

  static RuleScenario? byId(String id) => _byId[id];

  /// 当前勾选集合恰好等于某个场景时返回该场景（用于卡片选中态）。
  static RuleScenario? matching(Set<String> selectedIds) {
    for (final s in builtin) {
      if (s.ruleSetIds.length == selectedIds.length &&
          selectedIds.containsAll(s.ruleSetIds)) {
        return s;
      }
    }
    return null;
  }
}
