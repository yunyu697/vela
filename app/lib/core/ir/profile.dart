/// 统一配置 IR（Intermediate Representation）。
///
/// 所有功能（向导 / 规则编辑器 / 订阅解析）只操作这一层模型；
/// 编译器负责把 IR 翻译成 sing-box JSON 或 mihomo YAML。
/// 切换内核 = 换一个编译器，Profile 本身不变。
library;

/// 代理内核。
enum CoreKind { singbox, mihomo }

/// 代理协议。
enum ProxyProtocol {
  ss,
  ssr,
  vmess,
  vless,
  trojan,
  hysteria,
  hysteria2,
  tuic,
  wireguard,
  anytls,
  ssh,
  http,
  socks;

  /// 兼容性矩阵：该协议在指定内核上是否受支持。
  /// Lint 引擎据此把不支持的节点标红，编译器也会拒绝生成。
  bool supportedOn(CoreKind core) => switch (core) {
        CoreKind.mihomo => true,
        // sing-box 不支持 SSR；hysteria v1 已在 sing-box 废弃移除
        CoreKind.singbox =>
          this != ProxyProtocol.ssr && this != ProxyProtocol.hysteria,
      };
}

/// 单个代理节点。
class ProxyNode {
  const ProxyNode({
    required this.id,
    required this.name,
    required this.protocol,
    required this.server,
    required this.port,
    this.params = const {},
  });

  final String id;
  final String name;
  final ProxyProtocol protocol;
  final String server;
  final int port;

  /// 协议私有参数（uuid / password / 加密方式 / sni / alpn 等），
  /// 由各编译器按协议要求取用并转换字段名。
  final Map<String, Object?> params;

  ProxyNode copyWith({String? name, Map<String, Object?>? params}) =>
      ProxyNode(
        id: id,
        name: name ?? this.name,
        protocol: protocol,
        server: server,
        port: port,
        params: params ?? this.params,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol.name,
        'server': server,
        'port': port,
        'params': params,
      };

  factory ProxyNode.fromJson(Map<Object?, Object?> json) => ProxyNode(
        id: json['id'] as String,
        name: json['name'] as String,
        protocol: ProxyProtocol.values.byName(json['protocol'] as String),
        server: json['server'] as String,
        port: json['port'] as int,
        params:
            (json['params'] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
                const {},
      );
}

enum ProxyGroupType { select, urlTest, fallback, loadBalance }

/// 代理分组。成员可以是节点 id、其他分组 id，或 `region:<关键词>` 过滤器
/// （编译期展开为名字匹配该关键词的节点，用于自动地区分组）。
class ProxyGroup {
  const ProxyGroup({
    required this.id,
    required this.name,
    required this.type,
    required this.members,
    this.url = 'https://www.gstatic.com/generate_204',
    this.intervalSeconds = 300,
  });

  final String id;
  final String name;
  final ProxyGroupType type;
  final List<String> members;
  final String url;
  final int intervalSeconds;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'members': members,
        'url': url,
        'intervalSeconds': intervalSeconds,
      };

  factory ProxyGroup.fromJson(Map<Object?, Object?> json) => ProxyGroup(
        id: json['id'] as String,
        name: json['name'] as String,
        type: ProxyGroupType.values.byName(json['type'] as String),
        members: (json['members'] as List<Object?>).cast<String>(),
        url: json['url'] as String? ??
            'https://www.gstatic.com/generate_204',
        intervalSeconds: json['intervalSeconds'] as int? ?? 300,
      );
}

enum RuleAction { proxy, direct, reject }

/// 一条分流规则。
class RuleEntry {
  const RuleEntry({
    required this.id,
    required this.action,
    this.ruleSetIds = const {},
    this.domains = const [],
    this.ipCidrs = const [],
    this.outboundGroupId,
    this.enabled = true,
  });

  final String id;
  final RuleAction action;

  /// 引用的规则集 id（内置注册表 id 或自定义规则集 id）。
  final Set<String> ruleSetIds;

  /// 自定义域名（后缀匹配）。
  final List<String> domains;

  /// 自定义 IP CIDR。
  final List<String> ipCidrs;

  /// action == proxy 时的目标分组 id；为空则用首个分组。
  final String? outboundGroupId;

  final bool enabled;

  Map<String, Object?> toJson() => {
        'id': id,
        'action': action.name,
        'ruleSetIds': ruleSetIds.toList(),
        'domains': domains,
        'ipCidrs': ipCidrs,
        'outboundGroupId': outboundGroupId,
        'enabled': enabled,
      };

  factory RuleEntry.fromJson(Map<Object?, Object?> json) => RuleEntry(
        id: json['id'] as String,
        action: RuleAction.values.byName(json['action'] as String),
        ruleSetIds:
            ((json['ruleSetIds'] as List<Object?>?) ?? const []).cast<String>().toSet(),
        domains: ((json['domains'] as List<Object?>?) ?? const []).cast<String>(),
        ipCidrs: ((json['ipCidrs'] as List<Object?>?) ?? const []).cast<String>(),
        outboundGroupId: json['outboundGroupId'] as String?,
        enabled: json['enabled'] as bool? ?? true,
      );
}

enum DnsMode { fakeIp, redirHost, plain }

class DnsConfig {
  const DnsConfig({
    this.mode = DnsMode.fakeIp,
    this.domesticServers = const [
      'https://223.5.5.5/dns-query',
      'https://doh.pub/dns-query',
    ],
    this.foreignServers = const [
      'https://1.1.1.1/dns-query',
      'https://8.8.8.8/dns-query',
    ],
    this.bootstrap = const ['223.5.5.5', '119.29.29.29'],
    this.fakeIpRange = '198.18.0.1/16',
    this.fakeIpFilter = const [],
    this.followRules = true,
  });

  final DnsMode mode;
  final List<String> domesticServers;
  final List<String> foreignServers;

  /// 用于解析 DoH 域名的明文引导 DNS。
  final List<String> bootstrap;

  final String fakeIpRange;

  /// fake-ip 白名单：路由器管理页、NTP、本地服务等不走 fake-ip。
  final List<String> fakeIpFilter;

  /// DNS 解析是否按分流规则选择国内外服务器（关闭则全部走 foreign，
  /// Lint 会告警泄露 / 变慢）。
  final bool followRules;

  DnsConfig copyWith({
    DnsMode? mode,
    List<String>? fakeIpFilter,
    bool? followRules,
  }) =>
      DnsConfig(
        mode: mode ?? this.mode,
        domesticServers: domesticServers,
        foreignServers: foreignServers,
        bootstrap: bootstrap,
        fakeIpRange: fakeIpRange,
        fakeIpFilter: fakeIpFilter ?? this.fakeIpFilter,
        followRules: followRules ?? this.followRules,
      );

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'domesticServers': domesticServers,
        'foreignServers': foreignServers,
        'bootstrap': bootstrap,
        'fakeIpRange': fakeIpRange,
        'fakeIpFilter': fakeIpFilter,
        'followRules': followRules,
      };

  factory DnsConfig.fromJson(Map<Object?, Object?> json) => DnsConfig(
        mode: DnsMode.values.byName(json['mode'] as String? ?? 'fakeIp'),
        domesticServers:
            ((json['domesticServers'] as List<Object?>?) ?? const []).cast<String>(),
        foreignServers:
            ((json['foreignServers'] as List<Object?>?) ?? const []).cast<String>(),
        bootstrap: ((json['bootstrap'] as List<Object?>?) ?? const []).cast<String>(),
        fakeIpRange: json['fakeIpRange'] as String? ?? '198.18.0.1/16',
        fakeIpFilter:
            ((json['fakeIpFilter'] as List<Object?>?) ?? const []).cast<String>(),
        followRules: json['followRules'] as bool? ?? true,
      );
}

enum AccessMode { tun, systemProxy, mixed }

class InboundConfig {
  const InboundConfig({
    this.mode = AccessMode.mixed,
    this.tunStack = 'mixed',
    this.allowLan = false,
    this.mixedPort = 7890,
  });

  final AccessMode mode;

  /// sing-box / mihomo 通用：gvisor | system | mixed
  final String tunStack;
  final bool allowLan;
  final int mixedPort;

  /// 切换内核时复用同一入站端口，减少断网瞬间。
  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'tunStack': tunStack,
        'allowLan': allowLan,
        'mixedPort': mixedPort,
      };

  factory InboundConfig.fromJson(Map<Object?, Object?> json) => InboundConfig(
        mode: AccessMode.values.byName(json['mode'] as String? ?? 'mixed'),
        tunStack: json['tunStack'] as String? ?? 'mixed',
        allowLan: json['allowLan'] as bool? ?? false,
        mixedPort: json['mixedPort'] as int? ?? 7890,
      );
}

enum ProfileSourceType { subscription, links, manual, file }

class ProfileSource {
  const ProfileSource({required this.type, this.url});
  final ProfileSourceType type;
  final String? url;

  Map<String, Object?> toJson() => {'type': type.name, 'url': url};

  factory ProfileSource.fromJson(Map<Object?, Object?> json) => ProfileSource(
        type: ProfileSourceType.values.byName(json['type'] as String),
        url: json['url'] as String?,
      );
}

/// 顶层 Profile。
class Profile {
  Profile({
    required this.id,
    required this.name,
    required this.coreKind,
    required this.source,
    this.isNativeConfig = false,
    List<ProxyNode>? nodes,
    List<ProxyGroup>? groups,
    List<RuleEntry>? rules,
    DnsConfig? dns,
    InboundConfig? inbound,
    this.logLevel = 'info',
  })  : nodes = nodes ?? [],
        groups = groups ?? [],
        rules = rules ?? [],
        dns = dns ?? const DnsConfig(),
        inbound = inbound ?? const InboundConfig();

  final String id;
  final String name;
  final CoreKind coreKind;
  final ProfileSource source;

  /// 原生配置模式（用户直接维护最终 JSON/YAML，不可跨内核切换）。
  final bool isNativeConfig;

  final List<ProxyNode> nodes;
  final List<ProxyGroup> groups;
  final List<RuleEntry> rules;
  final DnsConfig dns;
  final InboundConfig inbound;
  final String logLevel;

  /// action == proxy 时规则默认指向的分组。
  String get defaultProxyGroupId => groups.firstOrNull?.id ?? '';

  String? outboundGroupNameOf(String? groupId) {
    final id = groupId ?? groups.firstOrNull?.id;
    if (id == null) return null;
    return groups.where((g) => g.id == id).firstOrNull?.name;
  }

  Profile copyWith({
    String? id,
    CoreKind? coreKind,
    List<ProxyNode>? nodes,
    List<ProxyGroup>? groups,
    List<RuleEntry>? rules,
    DnsConfig? dns,
    InboundConfig? inbound,
    String? name,
    String? logLevel,
    ProfileSource? source,
  }) =>
      Profile(
        id: id ?? this.id,
        name: name ?? this.name,
        coreKind: coreKind ?? this.coreKind,
        source: source ?? this.source,
        isNativeConfig: isNativeConfig,
        nodes: nodes ?? this.nodes,
        groups: groups ?? this.groups,
        rules: rules ?? this.rules,
        dns: dns ?? this.dns,
        inbound: inbound ?? this.inbound,
        logLevel: logLevel ?? this.logLevel,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'coreKind': coreKind.name,
        'source': source.toJson(),
        'isNativeConfig': isNativeConfig,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'groups': groups.map((g) => g.toJson()).toList(),
        'rules': rules.map((r) => r.toJson()).toList(),
        'dns': dns.toJson(),
        'inbound': inbound.toJson(),
        'logLevel': logLevel,
      };

  factory Profile.fromJson(Map<Object?, Object?> json) => Profile(
        id: json['id'] as String,
        name: json['name'] as String,
        coreKind: CoreKind.values.byName(json['coreKind'] as String),
        source: ProfileSource.fromJson(
            json['source'] as Map<Object?, Object?>),
        isNativeConfig: json['isNativeConfig'] as bool? ?? false,
        nodes: ((json['nodes'] as List<Object?>?) ?? const [])
            .map((n) => ProxyNode.fromJson(n as Map<Object?, Object?>))
            .toList(),
        groups: ((json['groups'] as List<Object?>?) ?? const [])
            .map((g) => ProxyGroup.fromJson(g as Map<Object?, Object?>))
            .toList(),
        rules: ((json['rules'] as List<Object?>?) ?? const [])
            .map((r) => RuleEntry.fromJson(r as Map<Object?, Object?>))
            .toList(),
        dns: DnsConfig.fromJson(json['dns'] as Map<Object?, Object?>? ?? {}),
        inbound:
            InboundConfig.fromJson(json['inbound'] as Map<Object?, Object?>? ?? {}),
        logLevel: json['logLevel'] as String? ?? 'info',
      );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
