/// 订阅拉取与解析。
///
/// 支持三种订阅格式（自动识别）：
/// - 分享链接列表（明文或整体 base64）
/// - Clash / mihomo YAML（proxies 段）
/// - sing-box JSON（outbounds 段）
///
/// UA 按内核发送（mihomo → clash.meta，sing-box → sing-box），
/// 并解析 subscription-userinfo 头获取流量/到期信息。
library;

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../ir/profile.dart';
import 'share_link_parser.dart';

class SubscriptionUserInfo {
  const SubscriptionUserInfo({
    required this.upload,
    required this.download,
    required this.total,
    this.expire,
  });

  final int upload;
  final int download;
  final int total;
  final DateTime? expire;

  int get used => upload + download;

  /// 0.0 ~ 1.0；total 未知时为 null。
  double? get usedRatio => total > 0 ? used / total : null;
}

class SubscriptionFetchResult {
  const SubscriptionFetchResult({
    required this.nodes,
    required this.format,
    this.info,
  });

  final List<ProxyNode> nodes;

  /// 'links' | 'clash-yaml' | 'singbox-json'
  final String format;
  final SubscriptionUserInfo? info;
}

class SubscriptionFetcher {
  SubscriptionFetcher();

  /// 拉取订阅。
  Future<SubscriptionFetchResult> fetch(
    String url, {
    CoreKind forCore = CoreKind.mihomo,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        forCore == CoreKind.mihomo ? 'clash.meta/1.19.0' : 'sing-box/1.11.0',
      );
      final response =
          await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        throw HttpException('订阅服务器返回 HTTP ${response.statusCode}');
      }
      final info = parseUserInfoHeader(
        response.headers.value('subscription-userinfo'),
      );
      final body = await utf8.decoder.bind(response).join();
      return parseBody(body, info: info);
    } finally {
      client.close();
    }
  }

  /// 解析 subscription-userinfo 头：
  /// `upload=123; download=456; total=789; expire=1758988800`
  static SubscriptionUserInfo? parseUserInfoHeader(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    int? num(String key) {
      for (final part in raw.split(';')) {
        final kv = part.trim().split('=');
        if (kv.length == 2 && kv[0] == key) {
          return int.tryParse(kv[1].trim());
        }
      }
      return null;
    }

    final upload = num('upload');
    final download = num('download');
    final total = num('total');
    final expire = num('expire');
    if (upload == null && download == null && total == null) return null;
    return SubscriptionUserInfo(
      upload: upload ?? 0,
      download: download ?? 0,
      total: total ?? 0,
      expire: expire == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expire * 1000),
    );
  }

  /// 解析订阅正文（自动识别格式）。
  static SubscriptionFetchResult parseBody(
    String body, {
    SubscriptionUserInfo? info,
  }) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) throw const FormatException('订阅内容为空');

    // 1) sing-box JSON
    if (trimmed.startsWith('{')) {
      final nodes = _nodesFromSingboxJson(trimmed);
      if (nodes.isNotEmpty) {
        return SubscriptionFetchResult(
            nodes: nodes, format: 'singbox-json', info: info);
      }
    }

    // 2) Clash / mihomo YAML
    if (RegExp(r'^\s*proxies\s*:', multiLine: true).hasMatch(trimmed)) {
      final nodes = _nodesFromClashYaml(trimmed);
      if (nodes.isNotEmpty) {
        return SubscriptionFetchResult(
            nodes: nodes, format: 'clash-yaml', info: info);
      }
    }

    // 3) 分享链接列表（明文或整体 base64）
    var linkText = trimmed;
    if (!linkText.contains('://')) {
      final decoded = ShareLinkParser.decodePossiblyBase64(linkText);
      if (decoded == null || !decoded.contains('://')) {
        throw const FormatException('无法识别的订阅格式');
      }
      linkText = decoded;
    }
    final nodes = ShareLinkParser.parseAll(linkText);
    if (nodes.isEmpty) throw const FormatException('订阅中没有可识别的节点');
    return SubscriptionFetchResult(nodes: nodes, format: 'links', info: info);
  }

  // -----------------------------------------------------------------
  // Clash / mihomo YAML
  // -----------------------------------------------------------------

  static List<ProxyNode> _nodesFromClashYaml(String body) {
    Object? doc;
    try {
      doc = loadYaml(body);
    } on YamlException {
      return const [];
    }
    final proxies = (doc as Map)['proxies'];
    if (proxies is! YamlList) return const [];
    final nodes = <ProxyNode>[];
    for (final entry in proxies) {
      if (entry is! Map) continue;
      final node = _nodeFromClashProxy(
        Map<String, Object?>.from(entry.cast<Object?, Object?>()),
      );
      if (node != null) nodes.add(node);
    }
    return nodes;
  }

  static ProxyNode? _nodeFromClashProxy(Map<String, Object?> p) {
    final type = (p['type'] ?? '').toString();
    final protocol = switch (type) {
      'ss' => ProxyProtocol.ss,
      'ssr' => ProxyProtocol.ssr,
      'vmess' => ProxyProtocol.vmess,
      'vless' => ProxyProtocol.vless,
      'trojan' => ProxyProtocol.trojan,
      'hysteria' => ProxyProtocol.hysteria,
      'hysteria2' => ProxyProtocol.hysteria2,
      'tuic' => ProxyProtocol.tuic,
      'wireguard' => ProxyProtocol.wireguard,
      'anytls' => ProxyProtocol.anytls,
      'http' => ProxyProtocol.http,
      'socks5' => ProxyProtocol.socks,
      _ => null,
    };
    if (protocol == null) return null;
    final server = (p['server'] ?? '').toString();
    final port = (p['port'] as num?)?.toInt() ??
        int.tryParse((p['port'] ?? '').toString());
    if (server.isEmpty || port == null) return null;
    final name = (p['name'] ?? '$server:$port').toString();

    return ProxyNode(
      id: _nodeId(protocol, server, port, name),
      name: name,
      protocol: protocol,
      server: server,
      port: port,
      params: _paramsFromClashProxy(p),
    );
  }

  /// Clash 字段 → IR 参数键。
  static Map<String, Object?> _paramsFromClashProxy(Map<String, Object?> p) {
    Object? v(String key) => p[key];
    String str(String key) => (p[key] ?? '').toString();
    final wsOpts = p['ws-opts'];
    final grpcOpts = p['grpc-opts'];
    final reality = p['reality-opts'];
    final alpnRaw = v('alpn');
    return {
      if (v('uuid') != null) 'uuid': str('uuid'),
      if (v('password') != null) 'password': str('password'),
      if (v('cipher') != null) 'cipher': str('cipher'),
      if (v('method') != null) 'cipher': str('method'),
      if (v('alterId') != null) 'alterId': (v('alterId') as num?)?.toInt() ?? 0,
      if (v('protocol') != null) 'protocol': str('protocol'),
      if (v('protocol-param') != null) 'protocolParam': str('protocol-param'),
      if (v('obfs') != null) 'obfs': str('obfs'),
      if (v('obfs-param') != null) 'obfsParam': str('obfs-param'),
      if (v('obfs-password') != null) 'obfsPassword': str('obfs-password'),
      'tls': v('tls') == true || str('servername').isNotEmpty,
      if ((reality is Map) ||
          (p['reality-opts'] is Map)) 'reality': true,
      if (str('servername').isNotEmpty) 'sni': str('servername'),
      if (str('sni').isNotEmpty) 'sni': str('sni'),
      if (str('network').isNotEmpty) 'network': str('network'),
      if (str('flow').isNotEmpty) 'flow': str('flow'),
      if (str('client-fingerprint').isNotEmpty)
        'fingerprint': str('client-fingerprint'),
      if (reality is Map) ...{
        if (reality['public-key'] != null)
          'publicKey': reality['public-key'].toString(),
        if (reality['short-id'] != null)
          'shortId': reality['short-id'].toString(),
      },
      if (str('path').isNotEmpty) 'path': str('path'),
      if (wsOpts is Map) ...{
        if (wsOpts['path'] != null) 'path': wsOpts['path'].toString(),
        if ((wsOpts['headers'] as Map?)?['Host'] != null)
          'wsHost': (wsOpts['headers'] as Map)['Host'].toString(),
      },
      if (grpcOpts is Map && grpcOpts['grpc-service-name'] != null)
        'serviceName': grpcOpts['grpc-service-name'].toString(),
      if (alpnRaw is YamlList)
        'alpn': alpnRaw.map((e) => e.toString()).join(','),
      if (alpnRaw is String && alpnRaw.isNotEmpty) 'alpn': alpnRaw,
      if (v('skip-cert-verify') == true) 'insecure': true,
      if (str('congestion-controller').isNotEmpty)
        'congestionControl': str('congestion-controller'),
      if (str('username').isNotEmpty) 'username': str('username'),
    };
  }

  // -----------------------------------------------------------------
  // sing-box JSON
  // -----------------------------------------------------------------

  static const _singboxNonNodeOutboundTypes = {
    'selector', 'urltest', 'direct', 'block', 'dns', 'reject', 'host',
  };

  static List<ProxyNode> _nodesFromSingboxJson(String body) {
    Object? jsonRaw;
    try {
      jsonRaw = jsonDecode(body);
    } on FormatException {
      return const [];
    }
    if (jsonRaw is! Map || jsonRaw['outbounds'] is! List) return const [];
    final nodes = <ProxyNode>[];
    for (final o in jsonRaw['outbounds'] as List<Object?>) {
      if (o is! Map) continue;
      final type = (o['type'] ?? '').toString();
      if (_singboxNonNodeOutboundTypes.contains(type)) continue;
      final protocol = switch (type) {
        'shadowsocks' => ProxyProtocol.ss,
        'vmess' => ProxyProtocol.vmess,
        'vless' => ProxyProtocol.vless,
        'trojan' => ProxyProtocol.trojan,
        'hysteria2' => ProxyProtocol.hysteria2,
        'tuic' => ProxyProtocol.tuic,
        'wireguard' => ProxyProtocol.wireguard,
        'anytls' => ProxyProtocol.anytls,
        'http' => ProxyProtocol.http,
        'socks' => ProxyProtocol.socks,
        _ => null,
      };
      if (protocol == null) continue;
      final server = (o['server'] ?? '').toString();
      final port = (o['server_port'] as num?)?.toInt();
      if (server.isEmpty || port == null) continue;
      final tag = (o['tag'] ?? '$server:$port').toString();
      nodes.add(ProxyNode(
        id: _nodeId(protocol, server, port, tag),
        name: tag,
        protocol: protocol,
        server: server,
        port: port,
        params: _paramsFromSingboxOutbound(o),
      ));
    }
    return nodes;
  }

  static Map<String, Object?> _paramsFromSingboxOutbound(Map<Object?, Object?> o) {
    String str(String key) => (o[key] ?? '').toString();
    final params = <String, Object?>{
      if (o['uuid'] != null) 'uuid': str('uuid'),
      if (o['password'] != null) 'password': str('password'),
      if (o['security'] != null) 'cipher': str('security'),
      if (o['method'] != null) 'cipher': str('method'),
      if (o['alter_id'] != null)
        'alterId': (o['alter_id'] as num?)?.toInt() ?? 0,
      if (o['flow'] != null) 'flow': str('flow'),
      if (o['congestion_control'] != null)
        'congestionControl': str('congestion_control'),
      if (o['obfs'] is Map)
        ...{
          'obfs': ((o['obfs'] as Map)['type'] ?? 'salamander').toString(),
          if ((o['obfs'] as Map)['password'] != null)
            'obfsPassword': (o['obfs'] as Map)['password'].toString(),
        },
    };
    if (o['tls'] is Map) {
      final tls = o['tls'] as Map;
      params['tls'] = tls['enabled'] == true;
      if (tls['server_name'] != null) params['sni'] = tls['server_name'].toString();
      if (tls['insecure'] == true) params['insecure'] = true;
      if (tls['utls'] is Map && (tls['utls'] as Map)['fingerprint'] != null) {
        params['fingerprint'] = (tls['utls'] as Map)['fingerprint'].toString();
      }
      if (tls['reality'] is Map) {
        final reality = tls['reality'] as Map;
        if (reality['enabled'] == true) params['reality'] = true;
        if (reality['public_key'] != null) {
          params['publicKey'] = reality['public_key'].toString();
        }
        if (reality['short_id'] != null) {
          params['shortId'] = reality['short_id'].toString();
        }
      }
    }
    if (o['transport'] is Map) {
      final transport = o['transport'] as Map;
      params['network'] = (transport['type'] ?? 'tcp').toString();
      if (transport['path'] != null) params['path'] = transport['path'].toString();
      if (transport['service_name'] != null) {
        params['serviceName'] = transport['service_name'].toString();
      }
      if (transport['headers'] is Map &&
          (transport['headers'] as Map)['Host'] != null) {
        params['wsHost'] = (transport['headers'] as Map)['Host'].toString();
      }
    }
    return params;
  }

  static String _nodeId(ProxyProtocol p, String server, int port, String name) =>
      '${p.name}://$server:$port/$name';
}
