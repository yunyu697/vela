/// 配置向导状态机。
///
/// 七步流程：选内核 → 来源 → 节点分组 → 规则 → DNS → 入站 → 检查生成。
/// 每步进入前可校验；最后一步运行 Lint，error 阻断生成。
library;

import 'package:flutter/foundation.dart';

import '../../core/compiler/mihomo_compiler.dart';
import '../../core/compiler/singbox_compiler.dart';
import '../../core/ir/profile.dart';
import '../../core/ir/rule_set_registry.dart';
import '../../core/lint/lint_engine.dart';
import '../../core/subscribe/share_link_parser.dart';
import '../../core/subscribe/subscription_fetcher.dart';

enum WizardStep {
  core('选择内核'),
  source('配置来源'),
  nodes('节点与分组'),
  rules('分流规则'),
  dns('DNS 设置'),
  inbound('入站模式'),
  review('检查与生成');

  const WizardStep(this.label);
  final String label;
}

/// DNS 预设：向导里一键套用，套用后仍可微调。
enum DnsPreset {
  recommended(
    label: '推荐（fake-ip）',
    description: '延迟最低，兼容绝大多数场景；自动加入本地服务白名单',
    mode: DnsMode.fakeIp,
    followRules: true,
    withDefaultFilter: true,
  ),
  compatible(
    label: '兼容（redir-host）',
    description: '对老设备 / 特殊 App 兼容性最好，解析稍慢',
    mode: DnsMode.redirHost,
    followRules: true,
    withDefaultFilter: false,
  ),
  simple(
    label: '简单（系统 DNS）',
    description: '不做 DNS 接管，可能泄露；仅用于系统代理模式',
    mode: DnsMode.plain,
    followRules: false,
    withDefaultFilter: false,
  );

  const DnsPreset({
    required this.label,
    required this.description,
    required this.mode,
    required this.followRules,
    required this.withDefaultFilter,
  });
  final String label;
  final String description;
  final DnsMode mode;
  final bool followRules;
  final bool withDefaultFilter;
}

enum SourceKind { subscription, links, manual, file }

class WizardController extends ChangeNotifier {
  WizardController({String? initialName})
      : _profileName = initialName ?? WizardController.suggestName();

  static const _defaultFakeIpFilter = [
    '*.lan',
    '*.local',
    '+.stun.*.*',
    'time.*.com',
    'ntp.*.com',
    '+.market.xiaomi.com',
  ];

  int _stepIndex = 0;
  CoreKind _coreKind = CoreKind.mihomo;
  SourceKind _sourceKind = SourceKind.subscription;
  String _sourceUrl = '';
  String _profileName = WizardController.suggestName();
  final List<ProxyNode> _importedNodes = [];
  final Set<String> _selectedRuleSetIds = {
    for (final id in RuleScenarios.builtin.first.ruleSetIds) id,
  };
  DnsPreset _dnsPreset = DnsPreset.recommended;
  DnsConfig _dns = const DnsConfig();
  AccessMode _accessMode = AccessMode.mixed;
  List<LintIssue> _lastLint = [];
  bool _fetching = false;
  String? _fetchError;
  SubscriptionUserInfo? _subscriptionInfo;

  int get stepIndex => _stepIndex;
  WizardStep get step => WizardStep.values[_stepIndex];
  CoreKind get coreKind => _coreKind;
  SourceKind get sourceKind => _sourceKind;
  String get sourceUrl => _sourceUrl;
  String get profileName => _profileName;
  List<ProxyNode> get importedNodes => List.unmodifiable(_importedNodes);
  Set<String> get selectedRuleSetIds => Set.unmodifiable(_selectedRuleSetIds);
  DnsPreset get dnsPreset => _dnsPreset;
  DnsConfig get dns => _dns;
  AccessMode get accessMode => _accessMode;
  List<LintIssue> get lastLint => List.unmodifiable(_lastLint);
  bool get fetching => _fetching;
  String? get fetchError => _fetchError;
  SubscriptionUserInfo? get subscriptionInfo => _subscriptionInfo;

  /// 生成一个默认不重复的配置名（带日期时间，如「我的配置 10-31 14:04:08」）。
  ///
  /// 每次向导打开都不同（精确到秒），避免连续生成时互相覆盖的困惑；
  /// 用户可在向导全程改名（[setProfileName]），保存时另有同名加序号兜底。
  static String suggestName() {
    final now = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '我的配置 '
        '${p2(now.month)}-${p2(now.day)} '
        '${p2(now.hour)}:${p2(now.minute)}:${p2(now.second)}';
  }

  void setProfileName(String name) {
    _profileName = name;
    notifyListeners();
  }

  List<LintIssue> get currentLint {
    final issues = const LintEngine().run(_buildDraft());
    _lastLint = issues;
    return issues;
  }

  bool get canAdvance {
    switch (step) {
      case WizardStep.source:
        return _sourceKind == SourceKind.subscription
            ? _sourceUrl.startsWith('http')
            : true;
      case WizardStep.nodes:
        return _importedNodes.isNotEmpty;
      case WizardStep.rules:
        return _selectedRuleSetIds.isNotEmpty;
      case WizardStep.review:
        return false;
      default:
        return true;
    }
  }

  void next() {
    if (_stepIndex < WizardStep.values.length - 1) {
      _stepIndex++;
      notifyListeners();
    }
  }

  void back() {
    if (_stepIndex > 0) {
      _stepIndex--;
      notifyListeners();
    }
  }

  void setCoreKind(CoreKind kind) {
    _coreKind = kind;
    notifyListeners();
  }

  void setSource(SourceKind kind, String url) {
    _sourceKind = kind;
    _sourceUrl = url;
    notifyListeners();
  }

  /// 拉取订阅：按内核发送 UA，自动识别 base64 链接 / Clash YAML /
  /// sing-box JSON 三种格式，并解析流量信息。
  Future<void> fetchNodes() async {
    if (_fetching || _sourceUrl.isEmpty) return;
    _fetching = true;
    _fetchError = null;
    notifyListeners();
    try {
      final result =
          await SubscriptionFetcher().fetch(_sourceUrl, forCore: _coreKind);
      _importedNodes
        ..clear()
        ..addAll(result.nodes);
      _subscriptionInfo = result.info;
    } catch (e) {
      _fetchError = e.toString();
    } finally {
      _fetching = false;
      notifyListeners();
    }
  }

  /// 分享链接批量导入（links 来源模式）。
  void importLinksText(String text) {
    final nodes = ShareLinkParser.parseAll(text);
    _importedNodes
      ..clear()
      ..addAll(nodes);
    _subscriptionInfo = null;
    notifyListeners();
  }

  void toggleRuleSet(String id) {
    _selectedRuleSetIds.contains(id)
        ? _selectedRuleSetIds.remove(id)
        : _selectedRuleSetIds.add(id);
    notifyListeners();
  }

  /// 应用常用场景：整体替换勾选集合（应用后仍可自由增删）。
  void applyScenario(String scenarioId) {
    final scenario = RuleScenarios.byId(scenarioId);
    if (scenario == null) return;
    _selectedRuleSetIds
      ..clear()
      ..addAll(scenario.ruleSetIds);
    notifyListeners();
  }

  void applyDnsPreset(DnsPreset preset) {
    _dnsPreset = preset;
    _dns = _dns.copyWith(
      mode: preset.mode,
      followRules: preset.followRules,
      fakeIpFilter:
          preset.withDefaultFilter ? List.from(_defaultFakeIpFilter) : [],
    );
    notifyListeners();
  }

  void setAccessMode(AccessMode mode) {
    _accessMode = mode;
    notifyListeners();
  }

  Profile _buildDraft() {
    final groups = _autoGroups();
    return Profile(
      id: 'wizard-${DateTime.now().millisecondsSinceEpoch}',
      name: _profileName.trim().isEmpty
          ? WizardController.suggestName()
          : _profileName.trim(),
      coreKind: _coreKind,
      source: ProfileSource(
        type: switch (_sourceKind) {
          SourceKind.subscription => ProfileSourceType.subscription,
          SourceKind.links => ProfileSourceType.links,
          SourceKind.manual => ProfileSourceType.manual,
          SourceKind.file => ProfileSourceType.file,
        },
        url: _sourceKind == SourceKind.subscription ? _sourceUrl : null,
      ),
      nodes: _importedNodes,
      groups: groups,
      rules: [
        RuleEntry(
          id: 'rule-main',
          action: RuleAction.reject,
          ruleSetIds: _selectedRuleSetIds
              .where((id) => RuleSetRegistry.byId(id)?.suggestedAction == RuleAction.reject)
              .toSet(),
        ),
        RuleEntry(
          id: 'rule-direct',
          action: RuleAction.direct,
          ruleSetIds: _selectedRuleSetIds
              .where((id) => RuleSetRegistry.byId(id)?.suggestedAction == RuleAction.direct)
              .toSet(),
        ),
        RuleEntry(
          id: 'rule-proxy',
          action: RuleAction.proxy,
          ruleSetIds: _selectedRuleSetIds
              .where((id) => RuleSetRegistry.byId(id)?.suggestedAction == RuleAction.proxy)
              .toSet(),
          outboundGroupId: groups.firstOrNull?.id,
        ),
      ],
      dns: _dns,
      inbound: InboundConfig(mode: _accessMode),
    );
  }

  /// 向导默认三件套的简化版：手动选择 + 自动选择（url-test）。
  /// 「自动选择」按地区关键词展开为若干 region 过滤器；识别不出地区时
  /// 直接包含全部节点。
  List<ProxyGroup> _autoGroups() {
    const regionKeywords = ['香港', '台湾', '日本', '美国', '新加坡', '韩国'];
    final regions = <String>[];
    for (final n in _importedNodes) {
      for (final kw in regionKeywords) {
        if (n.name.contains(kw) && !regions.contains(kw)) regions.add(kw);
      }
    }
    final autoMembers = regions.isNotEmpty
        ? [for (final r in regions) 'region:$r']
        : [for (final n in _importedNodes) n.id];
    final auto = ProxyGroup(
      id: 'g-auto',
      name: '自动选择',
      type: ProxyGroupType.urlTest,
      members: autoMembers,
    );
    return [
      ProxyGroup(
        id: 'g-select',
        name: '手动选择',
        type: ProxyGroupType.select,
        members: ['g-auto', ...autoMembers],
      ),
      auto,
    ];
  }

  /// 生成最终 Profile 并编译到所选内核。存在 error 级 Lint 时抛出。
  ProfileResult build() {
    final draft = _buildDraft();
    final issues = const LintEngine().run(draft);
    _lastLint = issues;
    if (const LintEngine().hasBlockingErrors(issues)) {
      return ProfileResult.failed(draft, issues);
    }
    final configText = switch (draft.coreKind) {
      CoreKind.singbox => const SingboxCompiler().compileToString(draft),
      CoreKind.mihomo => const MihomoCompiler().compileToString(draft),
    };
    return ProfileResult.ok(draft, configText, issues);
  }
}

class ProfileResult {
  ProfileResult._(this.profile, this.configText, this.issues);
  factory ProfileResult.ok(Profile p, String config, List<LintIssue> issues) =>
      ProfileResult._(p, config, issues);
  factory ProfileResult.failed(Profile p, List<LintIssue> issues) =>
      ProfileResult._(p, null, issues);

  final Profile profile;
  final String? configText;
  final List<LintIssue> issues;
  bool get success => configText != null;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
