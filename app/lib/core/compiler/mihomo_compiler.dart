/// IR → mihomo YAML 编译器。
///
/// 依赖一个轻量 YAML emitter（本文件内实现，避免引入额外依赖），
/// 仅覆盖配置所需的标量 / 列表 / 嵌套映射子集。
library;

import '../ir/profile.dart';
import '../ir/rule_set_registry.dart';

class MihomoCompiler {
  const MihomoCompiler();

  String compileToString(Profile p) => dumpYaml(compile(p));

  Map<String, Object?> compile(Profile p) {
    if (p.isNativeConfig) {
      throw StateError('原生配置 Profile 不参与 IR 编译');
    }
    final rules = <String>[];
    final providers = <String, Object?>{};

    for (final id in p.rules
        .expand((r) => r.enabled ? r.ruleSetIds : const <String>{})
        .toSet()) {
      final rs = RuleSetRegistry.byId(id);
      if (rs == null) continue;
      providers[id] = {
        'type': 'http',
        'behavior': rs.behavior == 'ip' ? 'ipcidr' : 'domain',
        'format': 'mrs',
        'url': rs.mihomoUrl,
        'path': './rule_sets/\$id.mrs',
        'interval': 86400,
      };
    }

    final finalPolicy = p.outboundGroupNameOf(null) ?? 'DIRECT';
    for (final r in p.rules.where((r) => r.enabled)) {
      final policy = switch (r.action) {
        RuleAction.direct => 'DIRECT',
        RuleAction.reject => 'REJECT',
        RuleAction.proxy => p.outboundGroupNameOf(r.outboundGroupId) ?? finalPolicy,
      };
      for (final id in r.ruleSetIds) {
        if (providers.containsKey(id)) rules.add('RULE-SET,$id,$policy');
      }
      for (final d in r.domains) {
        rules.add('DOMAIN-SUFFIX,$d,$policy');
      }
      for (final c in r.ipCidrs) {
        rules.add('IP-CIDR,$c,$policy,no-resolve');
      }
    }
    rules.add('MATCH,$finalPolicy');

    return {
      // external-controller 由适配器覆盖为 unix socket 路径
      'mixed-port': p.inbound.mixedPort,
      'allow-lan': p.inbound.allowLan,
      'mode': 'rule',
      'log-level': p.logLevel,
      'unified-delay': true,
      'tcp-concurrent': true,
      'dns': _dns(p),
      // TUN 仅在用户显式选择 TUN 入站时启用（mixed = HTTP+SOCKS 混合端口，
      // 不含 TUN；无特权时尝试开 TUN 只会产生噪音错误）
      if (p.inbound.mode == AccessMode.tun)
        'tun': {
          'enable': true,
          'stack': p.inbound.tunStack,
          'auto-route': true,
          'auto-detect-interface': true,
          // TUN 必须劫持 DNS，否则存在泄露（Lint W102 检查的是 IR 层配置）
          'dns-hijack': ['any:53'],
        },
      if (providers.isNotEmpty) 'rule-providers': providers,
      'proxies': p.nodes
          .where((n) => n.protocol.supportedOn(CoreKind.mihomo))
          .map(_nodeToProxy)
          .toList(),
      'proxy-groups': p.groups.map((g) => _group(g, p)).toList(),
      'rules': rules,
    };
  }

  Map<String, Object?> _dns(Profile p) => {
        'enable': true,
        'listen': '127.0.0.1:1053',
        'enhanced-mode': switch (p.dns.mode) {
          DnsMode.fakeIp => 'fake-ip',
          DnsMode.redirHost => 'redir-host',
          DnsMode.plain => 'redir-host',
        },
        if (p.dns.mode == DnsMode.fakeIp) ...{
          'fake-ip-range': p.dns.fakeIpRange,
          'fake-ip-filter': p.dns.fakeIpFilter,
        },
        'default-nameserver': p.dns.bootstrap,
        'nameserver': p.dns.domesticServers,
        if (p.dns.followRules) 'fallback': p.dns.foreignServers,
        if (p.dns.followRules)
          'fallback-filter': {
            'geoip': true,
            'geoip-code': 'CN',
          },
      };

  /// IR 参数键 → mihomo 字段（含 tls / reality / transport 展开）。
  Map<String, Object?> _nodeToProxy(ProxyNode node) {
    final p = node.params;
    String str(String key) => (p[key] ?? '').toString();
    final base = <String, Object?>{
      'name': node.name,
      'type': node.protocol.name,
      'server': node.server,
      'port': node.port,
    };
    final alpn = str('alpn').isEmpty
        ? null
        : str('alpn').split(',').where((s) => s.isNotEmpty).toList();
    final insecure = p['insecure'] == true;
    final network = str('network');
    final transport = _transportOpts(p);

    switch (node.protocol) {
      case ProxyProtocol.ss:
        return base
          ..addAll({
            'cipher': str('cipher').isEmpty ? 'aes-128-gcm' : str('cipher'),
            'password': str('password'),
          });
      case ProxyProtocol.ssr:
        return base
          ..addAll({
            'cipher': str('cipher'),
            'password': str('password'),
            'protocol': str('protocol').isEmpty ? 'origin' : str('protocol'),
            'obfs': str('obfs').isEmpty ? 'plain' : str('obfs'),
            if (str('protocolParam').isNotEmpty)
              'protocol-param': str('protocolParam'),
            if (str('obfsParam').isNotEmpty) 'obfs-param': str('obfsParam'),
          });
      case ProxyProtocol.vmess:
        return base
          ..addAll({
            'uuid': str('uuid'),
            'alterId': (p['alterId'] as num?)?.toInt() ?? 0,
            'cipher': str('cipher').isEmpty ? 'auto' : str('cipher'),
            'tls': p['tls'] == true,
            if (str('sni').isNotEmpty) 'servername': str('sni'),
            if (alpn != null) 'alpn': alpn,
            if (network.isNotEmpty && network != 'tcp') 'network': network,
            if (transport != null) ...transport,
          });
      case ProxyProtocol.vless:
        return base
          ..addAll({
            'uuid': str('uuid'),
            if (str('flow').isNotEmpty) 'flow': str('flow'),
            'tls': p['tls'] == true || p['reality'] == true,
            if (str('sni').isNotEmpty) 'servername': str('sni'),
            if (str('fingerprint').isNotEmpty)
              'client-fingerprint': str('fingerprint'),
            if (p['reality'] == true)
              'reality-opts': {
                'public-key': str('publicKey'),
                if (str('shortId').isNotEmpty) 'short-id': str('shortId'),
              },
            if (network.isNotEmpty && network != 'tcp') 'network': network,
            if (transport != null) ...transport,
          });
      case ProxyProtocol.trojan:
        return base
          ..addAll({
            'password': str('password'),
            if (str('sni').isNotEmpty) 'sni': str('sni'),
            if (alpn != null) 'alpn': alpn,
            'skip-cert-verify': insecure,
            if (network.isNotEmpty && network != 'tcp') 'network': network,
            if (transport != null) ...transport,
          });
      case ProxyProtocol.hysteria2:
        return base
          ..addAll({
            'password': str('password'),
            if (str('sni').isNotEmpty) 'sni': str('sni'),
            'skip-cert-verify': insecure,
            if (str('obfs').isNotEmpty) 'obfs': str('obfs'),
            if (str('obfsPassword').isNotEmpty)
              'obfs-password': str('obfsPassword'),
          });
      case ProxyProtocol.tuic:
        return base
          ..addAll({
            'uuid': str('uuid'),
            'password': str('password'),
            if (str('sni').isNotEmpty) 'sni': str('sni'),
            if (alpn != null) 'alpn': alpn,
            if (str('congestionControl').isNotEmpty)
              'congestion-controller': str('congestionControl'),
            'skip-cert-verify': insecure,
          });
      case ProxyProtocol.anytls:
        return base
          ..addAll({
            'password': str('password'),
            if (str('sni').isNotEmpty) 'sni': str('sni'),
            'skip-cert-verify': insecure,
          });
      case ProxyProtocol.http:
      case ProxyProtocol.socks:
        return base
          ..addAll({
            if (str('username').isNotEmpty) 'username': str('username'),
            if (str('password').isNotEmpty) 'password': str('password'),
            'tls': node.protocol == ProxyProtocol.http && p['tls'] == true,
          });
      default:
        // wireguard / hysteria 等低频协议：M2 按协议补全字段映射
        return base..addAll(p);
    }
  }

  /// ws / grpc / h2 传输层展开。
  Map<String, Object?>? _transportOpts(Map<String, Object?> p) {
    final network = (p['network'] ?? '').toString();
    final path = (p['path'] ?? '').toString();
    final wsHost = (p['wsHost'] ?? '').toString();
    final serviceName = (p['serviceName'] ?? '').toString();
    switch (network) {
      case 'ws':
        return {
          'ws-opts': {
            'path': path.isEmpty ? '/' : path,
            if (wsHost.isNotEmpty)
              'headers': {'Host': wsHost},
          },
        };
      case 'grpc':
        return {'grpc-opts': {'grpc-service-name': serviceName}};
      case 'h2':
        return {
          'h2-opts': {
            'path': path.isEmpty ? '/' : path,
            if (wsHost.isNotEmpty) 'host': [wsHost],
          },
        };
      default:
        return null;
    }
  }

  Map<String, Object?> _group(ProxyGroup g, Profile p) {
    final members = <String>[];
    for (final m in g.members) {
      if (m.startsWith('region:')) {
        final kw = m.substring('region:'.length);
        members.addAll(p.nodes
            .where((n) => n.name.contains(kw))
            .map((n) => n.name));
      } else {
        final node = p.nodes.where((n) => n.id == m).firstOrNull;
        if (node != null) {
          members.add(node.name);
        } else {
          final group = p.groups.where((g2) => g2.id == m).firstOrNull;
          if (group != null) members.add(group.name);
        }
      }
    }
    return {
      'name': g.name,
      'type': switch (g.type) {
        ProxyGroupType.select => 'select',
        ProxyGroupType.urlTest => 'url-test',
        ProxyGroupType.fallback => 'fallback',
        ProxyGroupType.loadBalance => 'load-balance',
      },
      'proxies': members,
      'url': g.url,
      'interval': g.intervalSeconds,
    };
  }
}

// ---------------------------------------------------------------------------
// 轻量 YAML emitter
// ---------------------------------------------------------------------------

final RegExp _needsQuoting = RegExp(
    r'^[\s]|[\s]$|[:#\{\}\[\],&\*\?\|>!%@"]|[\x27\n]');

String dumpYaml(Object? node) {
  final sb = StringBuffer();
  _writeNode(node, '', sb, inlineFirstKey: false);
  return sb.toString();
}

void _writeNode(Object? node, String pad, StringBuffer sb,
    {required bool inlineFirstKey}) {
  if (node is Map<Object?, Object?>) {
    _writeMap(Map<String, Object?>.from(node), pad, sb, inlineFirstKey);
  } else if (node is Map<String, Object?>) {
    _writeMap(node, pad, sb, inlineFirstKey);
  } else if (node is List<Object?>) {
    _writeList(node, pad, sb, inlineFirstKey);
  }
}

void _writeMap(Map<String, Object?> map, String pad, StringBuffer sb,
    bool inlineFirstKey) {
  var first = true;
  map.forEach((key, value) {
    final linePad = (first && inlineFirstKey) ? pad : pad;
    first = false;
    if (value is Map<String, Object?> && value.isNotEmpty) {
      sb.writeln('$linePad${_enc(key)}:');
      _writeMap(value, '$pad  ', sb, false);
    } else if (value is List<Object?> && value.isNotEmpty) {
      sb.writeln('$linePad${_enc(key)}:');
      _writeList(value, '$pad  ', sb, false);
    } else {
      sb.writeln('$linePad${_enc(key)}: ${_enc(value)}');
    }
  });
}

void _writeList(List<Object?> list, String pad, StringBuffer sb,
    bool inlineFirstKey) {
  var first = true;
  for (final item in list) {
    final dash = (first && inlineFirstKey) ? '' : '-';
    final itemPad = (first && inlineFirstKey) ? '$pad  ' : '$pad  ';
    first = false;
    if (item is Map<String, Object?>) {
      // 列表内嵌套映射：首键与 - 同行
      final keys = item.keys.toList();
      var i = 0;
      for (final k in keys) {
        final v = item[k];
        final prefix = i == 0 ? '$pad$dash ' : itemPad;
        if (v is Map<String, Object?> && v.isNotEmpty) {
          sb.writeln('$prefix${_enc(k)}:');
          _writeMap(v, '$itemPad  ', sb, false);
        } else if (v is List<Object?> && v.isNotEmpty) {
          sb.writeln('$prefix${_enc(k)}:');
          _writeList(v, '$itemPad  ', sb, false);
        } else {
          sb.writeln('$prefix${_enc(k)}: ${_enc(v)}');
        }
        i++;
      }
    } else {
      sb.writeln('$pad$dash ${_enc(item)}');
    }
  }
}

String _enc(Object? v) {
  if (v == null) return 'null';
  if (v is bool || v is num) return v.toString();
  if (v is List) return '[${v.map(_enc).join(', ')}]';
  if (v is String) return _quoteIfNeeded(v);
  throw ArgumentError('不支持的 YAML 标量类型: ${v.runtimeType}');
}

String _quoteIfNeeded(String s) {
  if (s.isEmpty) return "''";
  if (_needsQuoting.hasMatch(s) ||
      s.contains('\n') ||
      s.toLowerCase() == 'true' ||
      s.toLowerCase() == 'false' ||
      s.toLowerCase() == 'null' ||
      double.tryParse(s) != null) {
    return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }
  return s;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
