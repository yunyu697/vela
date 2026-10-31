/// IR → sing-box JSON 编译器（sing-box 1.11+ rule-set 格式）。
///
/// 产出的 Map 由调用方 jsonEncode 后写入配置文件，再交给
/// SingboxAdapter（libbox）启动。
library;

import 'dart:convert';

import '../ir/profile.dart';
import '../ir/rule_set_registry.dart';

class UnsupportedProtocolException implements Exception {
  UnsupportedProtocolException(this.protocol);
  final ProxyProtocol protocol;
  @override
  String toString() =>
      'sing-box 不支持协议 ${protocol.name}，请先通过 Lint 检查剔除相关节点';
}

class SingboxCompiler {
  const SingboxCompiler();

  String compileToString(Profile p) => const JsonEncoder.withIndent('  ')
      .convert(compile(p));

  Map<String, Object?> compile(Profile p) {
    if (p.isNativeConfig) {
      throw StateError('原生配置 Profile 不参与 IR 编译');
    }
    return {
      'log': {'level': p.logLevel, 'timestamp': true},
      'dns': _dns(p),
      'inbounds': _inbounds(p),
      'outbounds': _outbounds(p),
      'route': _route(p),
      'experimental': {
        // 生产上由适配器改为 external_controller_unix（unix socket），不暴露 TCP。
        'clash_api': {'external_controller': '127.0.0.1:9090'},
        'cache_file': {'enabled': true},
      },
    };
  }

  Map<String, Object?> _dns(Profile p) {
    final servers = <Object?>[];
    for (var i = 0; i < p.dns.domesticServers.length; i++) {
      servers.add({
        'tag': 'domestic-$i',
        'type': 'https',
        'server': Uri.parse(p.dns.domesticServers[i]).host,
        'domain_resolver': {'server': 'bootstrap-0'},
      });
    }
    for (var j = 0; j < p.dns.foreignServers.length; j++) {
      servers.add({
        'tag': 'foreign-$j',
        'type': 'https',
        'server': Uri.parse(p.dns.foreignServers[j]).host,
        'detour': p.outboundGroupNameOf(null),
      });
    }
    servers.add({
      'tag': 'bootstrap-0',
      'type': 'udp',
      'server': p.dns.bootstrap.firstOrNull ?? '223.5.5.5',
    });
    if (p.dns.mode == DnsMode.fakeIp) {
      servers.add({
        'tag': 'fakeip',
        'type': 'fakeip',
        'range': p.dns.fakeIpRange,
      });
    }

    final dnsRules = <Object?>[];
    if (p.dns.followRules) {
      final cnSets = p.rules
          .expand((r) => r.ruleSetIds)
          .where((id) => RuleSetRegistry.byId(id)?.suggestedAction == RuleAction.direct)
          .toList();
      if (cnSets.isNotEmpty) {
        dnsRules.add({'rule_set': cnSets, 'server': 'domestic-0'});
      }
    }
    if (p.dns.mode == DnsMode.fakeIp) {
      // 仅对 A/AAAA 走 fake-ip，避免影响 HTTPS(SVCB) 等查询。
      dnsRules.add({
        'query_type': ['A', 'AAAA'],
        'server': 'fakeip',
      });
    }

    // final 指向必须真实存在的 server tag：
    // 分流时用最后一个国内 DNS（无国内 DNS 则退回国外），不分流用国外
    final hasDomestic = p.dns.domesticServers.isNotEmpty;
    final finalServer = p.dns.followRules && hasDomestic
        ? 'domestic-${p.dns.domesticServers.length - 1}'
        : 'foreign-0';
    return {
      'servers': servers,
      'rules': dnsRules,
      'final': finalServer,
      'strategy': 'prefer_ipv4',
      'independent_cache': true,
    };
  }

  List<Object?> _inbounds(Profile p) {
    final inbounds = <Object?>[];
    switch (p.inbound.mode) {
      // TUN 仅在用户显式选择 TUN 入站时启用（mixed = 纯混合端口，
      // 无特权环境下尝试开 TUN 只会产生噪音错误）
      case AccessMode.tun:
        inbounds.add({
          'type': 'tun',
          'tag': 'tun-in',
          'interface_name': 'boxhub0',
          'address': ['172.19.0.1/30'],
          'mtu': 9000,
          'auto_route': true,
          'strict_route': true,
          'stack': p.inbound.tunStack,
          // 劫持 TUN 上的 DNS 流量进内核 DNS 模块（Android VpnService
          // 的 DNS 服务器指向 TUN 网关，必须靠劫持才能进分流逻辑）
          'dns_mode': 'hijack',
          'route_exclude_address_set': [],
        });
      case AccessMode.mixed:
      case AccessMode.systemProxy:
        inbounds.add(_mixed(p));
    }
    return inbounds;
  }

  Object? _mixed(Profile p) => {
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': p.inbound.allowLan ? '0.0.0.0' : '127.0.0.1',
        'listen_port': p.inbound.mixedPort,
      };

  List<Object?> _outbounds(Profile p) {
    final outbounds = <Object?>[];
    for (final node in p.nodes) {
      if (!node.protocol.supportedOn(CoreKind.singbox)) continue;
      outbounds.add(_nodeToOutbound(node, p));
    }
    for (final g in p.groups) {
      final members = _resolveGroupMembers(g, p);
      switch (g.type) {
        case ProxyGroupType.select:
          outbounds.add({
            'type': 'selector',
            'tag': g.name,
            'outbounds': members,
            'interrupt_exist_connections': true,
          });
        case ProxyGroupType.urlTest:
        case ProxyGroupType.fallback:
        case ProxyGroupType.loadBalance:
          outbounds.add({
            'type': 'urltest',
            'tag': g.name,
            'outbounds': members,
            'url': g.url,
            'interval': '${g.intervalSeconds}s',
          });
      }
    }
    outbounds.add(const {'type': 'direct', 'tag': 'direct'});
    return outbounds;
  }

  /// IR 参数键 → sing-box outbound 字段（含 tls / reality / transport 组装）。
  Map<String, Object?> _nodeToOutbound(ProxyNode node, Profile p) {
    final type = switch (node.protocol) {
      ProxyProtocol.ss => 'shadowsocks',
      ProxyProtocol.ssr => throw UnsupportedProtocolException(ProxyProtocol.ssr),
      ProxyProtocol.hysteria =>
        throw UnsupportedProtocolException(ProxyProtocol.hysteria),
      ProxyProtocol.hysteria2 => 'hysteria2',
      ProxyProtocol.vmess => 'vmess',
      ProxyProtocol.vless => 'vless',
      ProxyProtocol.trojan => 'trojan',
      ProxyProtocol.tuic => 'tuic',
      ProxyProtocol.wireguard => 'wireguard',
      ProxyProtocol.anytls => 'anytls',
      ProxyProtocol.ssh => 'ssh',
      ProxyProtocol.http => 'http',
      ProxyProtocol.socks => 'socks',
    };
    final pr = node.params;
    String str(String key) => (pr[key] ?? '').toString();
    final base = <String, Object?>{
      'type': type,
      'tag': node.name,
      'server': node.server,
      'server_port': node.port,
    };

    switch (node.protocol) {
      case ProxyProtocol.ss:
        return base
          ..addAll({
            'method': str('cipher').isEmpty ? 'aes-128-gcm' : str('cipher'),
            'password': str('password'),
          });
      case ProxyProtocol.vmess:
        return base
          ..addAll({
            'uuid': str('uuid'),
            'security': str('cipher').isEmpty ? 'auto' : str('cipher'),
            'alter_id': (pr['alterId'] as num?)?.toInt() ?? 0,
            if (_tls(pr) != null) 'tls': _tls(pr),
            if (_transport(pr) != null) 'transport': _transport(pr),
          });
      case ProxyProtocol.vless:
        return base
          ..addAll({
            'uuid': str('uuid'),
            if (str('flow').isNotEmpty) 'flow': str('flow'),
            if (_tls(pr) != null) 'tls': _tls(pr),
            if (_transport(pr) != null) 'transport': _transport(pr),
          });
      case ProxyProtocol.trojan:
        return base
          ..addAll({
            'password': str('password'),
            'tls': _tls(pr, required: true),
            if (_transport(pr) != null) 'transport': _transport(pr),
          });
      case ProxyProtocol.hysteria2:
        return base
          ..addAll({
            'password': str('password'),
            if (str('obfs').isNotEmpty)
              'obfs': {
                'type': str('obfs'),
                'password': str('obfsPassword'),
              },
            'tls': _tls(pr, required: true),
          });
      case ProxyProtocol.tuic:
        return base
          ..addAll({
            'uuid': str('uuid'),
            'password': str('password'),
            if (str('congestionControl').isNotEmpty)
              'congestion_control': str('congestionControl'),
            'tls': _tls(pr, required: true),
          });
      case ProxyProtocol.anytls:
        return base
          ..addAll({
            'password': str('password'),
            'tls': _tls(pr, required: true),
          });
      case ProxyProtocol.http:
      case ProxyProtocol.socks:
        return base
          ..addAll({
            if (str('username').isNotEmpty) 'username': str('username'),
            if (str('password').isNotEmpty) 'password': str('password'),
            if (node.protocol == ProxyProtocol.http && _tls(pr) != null)
              'tls': _tls(pr),
          });
      default:
        // wireguard / hysteria / ssh 等低频协议：M2 补全
        return base..addAll(pr);
    }
  }

  /// 组装 sing-box tls 块；无 TLS 信息且非必需时返回 null。
  Map<String, Object?>? _tls(Map<String, Object?> pr,
      {bool required = false}) {
    final hasInfo = pr['tls'] == true ||
        pr['reality'] == true ||
        (pr['sni'] ?? '').toString().isNotEmpty ||
        (pr['publicKey'] ?? '').toString().isNotEmpty;
    if (!required && !hasInfo) return null;
    final sni = (pr['sni'] ?? '').toString();
    final fingerprint = (pr['fingerprint'] ?? '').toString();
    final alpnRaw = (pr['alpn'] ?? '').toString();
    return {
      'enabled': true,
      if (sni.isNotEmpty) 'server_name': sni,
      if (pr['insecure'] == true) 'insecure': true,
      if (alpnRaw.isNotEmpty)
        'alpn': alpnRaw.split(',').where((s) => s.isNotEmpty).toList(),
      if ((pr['publicKey'] ?? '').toString().isNotEmpty)
        'reality': {
          'enabled': true,
          'public_key': (pr['publicKey'] ?? '').toString(),
          'short_id': (pr['shortId'] ?? '').toString(),
        },
      if (fingerprint.isNotEmpty)
        'utls': {'enabled': true, 'fingerprint': fingerprint},
    };
  }

  /// 组装 sing-box transport 块；tcp 返回 null。
  Map<String, Object?>? _transport(Map<String, Object?> pr) {
    final network = (pr['network'] ?? '').toString();
    final path = (pr['path'] ?? '').toString();
    final wsHost = (pr['wsHost'] ?? '').toString();
    final serviceName = (pr['serviceName'] ?? '').toString();
    switch (network) {
      case 'ws':
        return {
          'type': 'ws',
          'path': path.isEmpty ? '/' : path,
          if (wsHost.isNotEmpty) 'headers': {'Host': wsHost},
        };
      case 'grpc':
        return {
          'type': 'grpc',
          'service_name': serviceName,
        };
      case 'h2':
      case 'http':
        return {
          'type': 'http',
          'path': path.isEmpty ? '/' : path,
          if (wsHost.isNotEmpty) 'host': [wsHost],
        };
      default:
        return null;
    }
  }

  List<String> _resolveGroupMembers(ProxyGroup g, Profile p) {
    final tags = <String>[];
    for (final m in g.members) {
      if (m.startsWith('region:')) {
        final kw = m.substring('region:'.length);
        tags.addAll(
          p.nodes.where((n) => n.name.contains(kw)).map((n) => n.name),
        );
      } else {
        final isNode = p.nodes.any((n) => n.id == m);
        if (isNode) {
          tags.add(p.nodes.firstWhere((n) => n.id == m).name);
        } else {
          // 分组嵌套：引用分组名
          final group = p.groups.where((g2) => g2.id == m).firstOrNull;
          if (group != null) tags.add(group.name);
        }
      }
    }
    return tags;
  }

  Map<String, Object?> _route(Profile p) {
    final usedSetIds = p.rules
        .expand((r) => r.enabled ? r.ruleSetIds : const <String>{})
        .toSet();
    final ruleSets = <Object?>[];
    for (final id in usedSetIds) {
      final rs = RuleSetRegistry.byId(id);
      if (rs == null) continue;
      ruleSets.add({
        'type': 'remote',
        'tag': id,
        'format': 'binary',
        'url': rs.singboxUrl,
        'download_detour': 'direct',
      });
    }

    final rules = <Object?>[];
    for (final r in p.rules.where((r) => r.enabled)) {
      final entry = <String, Object?>{};
      final setIds = r.ruleSetIds
          .where((id) => usedSetIds.contains(id) && RuleSetRegistry.byId(id) != null)
          .toList();
      if (setIds.isNotEmpty) entry['rule_set'] = setIds;
      if (r.domains.isNotEmpty) {
        entry['domain_suffix'] = List<String>.from(r.domains);
      }
      if (r.ipCidrs.isNotEmpty) entry['ip_cidr'] = List<String>.from(r.ipCidrs);
      if (entry.isEmpty) continue;
      if (r.action == RuleAction.reject) {
        // sing-box 1.11+ 用规则动作而非独立 reject outbound
        entry['action'] = 'reject';
      } else {
        entry['outbound'] = r.action == RuleAction.direct
            ? 'direct'
            : p.outboundGroupNameOf(r.outboundGroupId) ?? 'direct';
      }
      rules.add(entry);
    }

    return {
      'rule_set': ruleSets,
      'rules': rules,
      'final': p.outboundGroupNameOf(null),
      'auto_detect_interface': true,
    };
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
