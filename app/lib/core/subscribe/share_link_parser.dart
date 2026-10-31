/// 分享链接解析器：ss / ssr / vmess / vless / trojan / hysteria2 / tuic。
///
/// 解析结果存入 IR 的 [ProxyNode.params]，键名约定（双编译器的
/// 参数规范化都以此为输入）：
/// - uuid / password / cipher / alterId / encryption / flow
/// - tls(bool) / sni / alpn(逗号分隔) / insecure(bool) / fingerprint
/// - publicKey / shortId（reality）
/// - network(tcp/ws/grpc/h2) / path / wsHost / serviceName
/// - obfs / obfsPassword（hysteria2）
/// - protocol / protocolParam / obfsParam（ssr）
/// - congestionControl（tuic）
library;

import 'dart:convert';

import '../ir/profile.dart';

class ShareLinkParser {
  ShareLinkParser._();

  /// 解析单条分享链接；不支持的格式返回 null。
  static ProxyNode? parse(String link) {
    final trimmed = link.trim();
    if (!trimmed.contains('://')) return null;
    final scheme =
        trimmed.substring(0, trimmed.indexOf('://')).toLowerCase();
    switch (scheme) {
      case 'ss':
        return _parseSs(trimmed);
      case 'ssr':
        return _parseSsr(trimmed);
      case 'vmess':
        return _parseVmess(trimmed);
      case 'vless':
        return _parseVless(trimmed);
      case 'trojan':
        return _parseTrojan(trimmed);
      case 'hysteria2':
      case 'hy2':
        return _parseHysteria2(trimmed);
      case 'tuic':
        return _parseTuic(trimmed);
      default:
        return null;
    }
  }

  /// 批量解析（按行切分，自动跳过空行与不认识的行）。
  static List<ProxyNode> parseAll(String text) {
    final nodes = <ProxyNode>[];
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final node = parse(line);
      if (node != null) nodes.add(node);
    }
    return nodes;
  }

  /// 尝试把字符串当作 base64（标准或 URL-safe，自动补齐 padding）解码。
  /// 失败返回 null；非 UTF-8 字节用替换字符容错。
  static String? decodePossiblyBase64(String s) {
    var normalized = s.trim().replaceAll('-', '+').replaceAll('_', '/');
    // 去掉多余的 padding 后重补
    normalized = normalized.replaceAll('=', '');
    final rem = normalized.length % 4;
    if (rem == 1) return null;
    normalized += '=' * ((4 - rem) % 4);
    try {
      return utf8.decode(base64.decode(normalized), allowMalformed: true);
    } on FormatException {
      return null;
    }
  }

  // -----------------------------------------------------------------
  // ss
  // -----------------------------------------------------------------

  /// SIP002：ss://base64(method:password)@host:port#name
  /// 兼容旧式整体 base64：ss://base64(method:password@host:port)#name
  static ProxyNode? _parseSs(String link) {
    var body = link.substring('ss://'.length);
    String? name;
    final hashIdx = body.indexOf('#');
    if (hashIdx >= 0) {
      name = Uri.decodeComponent(body.substring(hashIdx + 1));
      body = body.substring(0, hashIdx);
    }
    var query = const <String, String>{};
    final qIdx = body.indexOf('?');
    if (qIdx >= 0) {
      query = Uri.splitQueryString(body.substring(qIdx + 1));
      body = body.substring(0, qIdx);
    }

    String method;
    String password;
    String server;
    int port;

    if (body.contains('@')) {
      final at = body.lastIndexOf('@');
      final credential =
          decodePossiblyBase64(body.substring(0, at)) ??
              Uri.decodeComponent(body.substring(0, at));
      final idx = credential.indexOf(':');
      if (idx < 0) return null;
      method = credential.substring(0, idx);
      password = credential.substring(idx + 1);
      final hp = _parseHostPort(body.substring(at + 1));
      if (hp == null) return null;
      (server, port) = hp;
    } else {
      final decoded = decodePossiblyBase64(body);
      if (decoded == null || !decoded.contains('@')) return null;
      final at = decoded.lastIndexOf('@');
      final credential = decoded.substring(0, at);
      final idx = credential.indexOf(':');
      if (idx < 0) return null;
      method = credential.substring(0, idx);
      password = credential.substring(idx + 1);
      final hp = _parseHostPort(decoded.substring(at + 1));
      if (hp == null) return null;
      (server, port) = hp;
    }

    return ProxyNode(
      id: _nodeId(ProxyProtocol.ss, server, port, name),
      name: (name == null || name.isEmpty) ? '$server:$port' : name,
      protocol: ProxyProtocol.ss,
      server: server,
      port: port,
      params: {
        'cipher': method,
        'password': password,
        if (query['plugin'] != null) 'plugin': query['plugin']!,
      },
    );
  }

  // -----------------------------------------------------------------
  // ssr
  // -----------------------------------------------------------------

  /// ssr://base64(host:port:protocol:method:obfs:base64pass/?params)
  static ProxyNode? _parseSsr(String link) {
    final decoded = decodePossiblyBase64(link.substring('ssr://'.length));
    if (decoded == null) return null;
    final mainEnd = decoded.indexOf('/?');
    final main = mainEnd >= 0 ? decoded.substring(0, mainEnd) : decoded;
    final parts = main.split(':');
    if (parts.length < 6) return null;
    // IPv6 主机自身含冒号：协议/方法/混淆/密码固定占最后 4 段
    final port = int.tryParse(parts[parts.length - 5]);
    if (port == null) return null;
    final host = parts.sublist(0, parts.length - 5).join(':');
    final protocol = parts[parts.length - 4];
    final method = parts[parts.length - 3];
    final obfs = parts[parts.length - 2];
    final password =
        decodePossiblyBase64(parts.last) ?? parts.last;

    var query = <String, String>{};
    if (mainEnd >= 0) {
      for (final kv in decoded.substring(mainEnd + 2).split('&')) {
        final eq = kv.indexOf('=');
        if (eq <= 0) continue;
        final key = kv.substring(0, eq);
        final rawValue = kv.substring(eq + 1);
        final b64 = decodePossiblyBase64(rawValue);
        if (b64 != null) {
          query[key] = b64;
        } else {
          // 非 base64 时尝试 URL 解码（SSR 参数可能直接是明文）
          try {
            query[key] = Uri.decodeComponent(rawValue);
          } on ArgumentError {
            query[key] = rawValue;
          }
        }
      }
    }

    final name = query['remarks'];
    return ProxyNode(
      id: _nodeId(ProxyProtocol.ssr, host, port, name),
      name: (name == null || name.isEmpty) ? '$host:$port' : name,
      protocol: ProxyProtocol.ssr,
      server: host,
      port: port,
      params: {
        'cipher': method,
        'password': password,
        'protocol': protocol,
        'obfs': obfs,
        if (query['protoparam']?.isNotEmpty ?? false)
          'protocolParam': query['protoparam']!,
        if (query['obfsparam']?.isNotEmpty ?? false)
          'obfsParam': query['obfsparam']!,
      },
    );
  }

  // -----------------------------------------------------------------
  // vmess（v2rayN 格式：base64(JSON)）
  // -----------------------------------------------------------------

  static ProxyNode? _parseVmess(String link) {
    final decoded = decodePossiblyBase64(link.substring('vmess://'.length));
    if (decoded == null) return null;
    Object? jsonRaw;
    try {
      jsonRaw = jsonDecode(decoded);
    } on FormatException {
      return null;
    }
    if (jsonRaw is! Map) return null;
    final json = jsonRaw;
    String str(String key) => (json[key] ?? '').toString();

    final server = str('add');
    final port = int.tryParse(str('port'));
    if (server.isEmpty || port == null) return null;
    final ps = str('ps');
    final net = str('net');

    return ProxyNode(
      id: _nodeId(ProxyProtocol.vmess, server, port, ps),
      name: ps.isEmpty ? '$server:$port' : ps,
      protocol: ProxyProtocol.vmess,
      server: server,
      port: port,
      params: {
        'uuid': str('id'),
        'alterId': int.tryParse(str('aid')) ?? 0,
        'cipher': str('scy').isEmpty ? 'auto' : str('scy'),
        'network': net.isEmpty ? 'tcp' : net,
        'tls': str('tls') == 'tls',
        if (str('sni').isNotEmpty) 'sni': str('sni'),
        if (str('host').isNotEmpty) 'wsHost': str('host'),
        if (str('path').isNotEmpty) 'path': str('path'),
        if (str('alpn').isNotEmpty) 'alpn': str('alpn'),
        if (str('fp').isNotEmpty) 'fingerprint': str('fp'),
      },
    );
  }

  // -----------------------------------------------------------------
  // vless
  // -----------------------------------------------------------------

  static ProxyNode? _parseVless(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final q = uri.queryParameters;
    final name = _fragmentName(uri);
    final security = q['security'] ?? 'none';
    return ProxyNode(
      id: _nodeId(ProxyProtocol.vless, uri.host, uri.port, name),
      name: name.isEmpty ? '${uri.host}:${_portOr(uri, 443)}' : name,
      protocol: ProxyProtocol.vless,
      server: uri.host,
      port: _portOr(uri, 443),
      params: {
        'uuid': uri.userInfo,
        'encryption': q['encryption'] ?? 'none',
        'network': q['type'] ?? 'tcp',
        'tls': security == 'tls' || security == 'reality',
        if (security == 'reality') 'reality': true,
        if (q['flow']?.isNotEmpty ?? false) 'flow': q['flow']!,
        if (q['sni']?.isNotEmpty ?? false) 'sni': q['sni']!,
        if (q['fp']?.isNotEmpty ?? false) 'fingerprint': q['fp']!,
        if (q['pbk']?.isNotEmpty ?? false) 'publicKey': q['pbk']!,
        if (q['sid']?.isNotEmpty ?? false) 'shortId': q['sid']!,
        if (q['path']?.isNotEmpty ?? false) 'path': q['path']!,
        if (q['host']?.isNotEmpty ?? false) 'wsHost': q['host']!,
        if (q['serviceName']?.isNotEmpty ?? false)
          'serviceName': q['serviceName']!,
        if (q['alpn']?.isNotEmpty ?? false) 'alpn': q['alpn']!,
      },
    );
  }

  // -----------------------------------------------------------------
  // trojan
  // -----------------------------------------------------------------

  static ProxyNode? _parseTrojan(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isEmpty) return null;
    final q = uri.queryParameters;
    final name = _fragmentName(uri);
    final security = q['security'] ?? 'tls';
    return ProxyNode(
      id: _nodeId(ProxyProtocol.trojan, uri.host, uri.port, name),
      name: name.isEmpty ? '${uri.host}:${_portOr(uri, 443)}' : name,
      protocol: ProxyProtocol.trojan,
      server: uri.host,
      port: _portOr(uri, 443),
      params: {
        'password': Uri.decodeComponent(uri.userInfo),
        'network': q['type'] ?? 'tcp',
        'tls': security != 'none',
        if (q['sni']?.isNotEmpty ?? false) 'sni': q['sni']!,
        if (q['fp']?.isNotEmpty ?? false) 'fingerprint': q['fp']!,
        if (q['path']?.isNotEmpty ?? false) 'path': q['path']!,
        if (q['host']?.isNotEmpty ?? false) 'wsHost': q['host']!,
        if (q['serviceName']?.isNotEmpty ?? false)
          'serviceName': q['serviceName']!,
        if (q['alpn']?.isNotEmpty ?? false) 'alpn': q['alpn']!,
        if ((q['allowInsecure'] ?? q['insecure']) == '1')
          'insecure': true,
      },
    );
  }

  // -----------------------------------------------------------------
  // hysteria2
  // -----------------------------------------------------------------

  static ProxyNode? _parseHysteria2(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isEmpty) return null;
    final q = uri.queryParameters;
    final name = _fragmentName(uri);
    return ProxyNode(
      id: _nodeId(ProxyProtocol.hysteria2, uri.host, uri.port, name),
      name: name.isEmpty ? '${uri.host}:${_portOr(uri, 443)}' : name,
      protocol: ProxyProtocol.hysteria2,
      server: uri.host,
      port: _portOr(uri, 443),
      params: {
        'password': Uri.decodeComponent(uri.userInfo),
        'tls': true,
        if (q['sni']?.isNotEmpty ?? false) 'sni': q['sni']!,
        if (q['alpn']?.isNotEmpty ?? false) 'alpn': q['alpn']!,
        if (q['obfs']?.isNotEmpty ?? false) 'obfs': q['obfs']!,
        if (q['obfs-password']?.isNotEmpty ?? false)
          'obfsPassword': q['obfs-password']!,
        if (q['insecure'] == '1') 'insecure': true,
      },
    );
  }

  // -----------------------------------------------------------------
  // tuic
  // -----------------------------------------------------------------

  static ProxyNode? _parseTuic(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isEmpty) return null;
    final q = uri.queryParameters;
    final name = _fragmentName(uri);
    final userInfo = Uri.decodeComponent(uri.userInfo);
    final sep = userInfo.indexOf(':');
    final uuid = sep > 0 ? userInfo.substring(0, sep) : userInfo;
    final password =
        sep > 0 ? userInfo.substring(sep + 1) : '';
    return ProxyNode(
      id: _nodeId(ProxyProtocol.tuic, uri.host, uri.port, name),
      name: name.isEmpty ? '${uri.host}:${_portOr(uri, 443)}' : name,
      protocol: ProxyProtocol.tuic,
      server: uri.host,
      port: _portOr(uri, 443),
      params: {
        'uuid': uuid,
        'password': password,
        'tls': true,
        if (q['sni']?.isNotEmpty ?? false) 'sni': q['sni']!,
        if (q['alpn']?.isNotEmpty ?? false) 'alpn': q['alpn']!,
        if (q['congestion_control']?.isNotEmpty ?? false)
          'congestionControl': q['congestion_control']!,
        if ((q['insecure'] ?? q['allow_insecure']) == '1')
          'insecure': true,
      },
    );
  }

  // -----------------------------------------------------------------
  // 工具
  // -----------------------------------------------------------------

  static String _fragmentName(Uri uri) {
    if (uri.fragment.isEmpty) return '';
    return Uri.decodeComponent(uri.fragment);
  }

  static int _portOr(Uri uri, int fallback) =>
      uri.port > 0 ? uri.port : fallback;

  /// (host, port)，支持 IPv6 [::1]:443。
  static (String, int)? _parseHostPort(String s) {
    s = s.trim();
    if (s.startsWith('[')) {
      final close = s.indexOf(']');
      if (close < 0) return null;
      final host = s.substring(1, close);
      final rest = s.substring(close + 1);
      if (!rest.startsWith(':')) return null;
      final port = int.tryParse(rest.substring(1));
      if (port == null) return null;
      return (host, port);
    }
    final colon = s.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(s.substring(colon + 1));
    if (port == null) return null;
    return (s.substring(0, colon), port);
  }

  static String _nodeId(ProxyProtocol p, String server, int port, String? name) =>
      '${p.name}://$server:$port/${name ?? ''}';
}
