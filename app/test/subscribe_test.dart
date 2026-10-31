import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:vela/core/compiler/mihomo_compiler.dart';
import 'package:vela/core/compiler/singbox_compiler.dart';
import 'package:vela/core/ir/profile.dart';
import 'package:vela/core/subscribe/share_link_parser.dart';
import 'package:vela/core/subscribe/subscription_fetcher.dart';

Profile _profileWith(ProxyNode node) => Profile(
      id: 't',
      name: 't',
      coreKind: CoreKind.mihomo,
      source: const ProfileSource(type: ProfileSourceType.manual),
      nodes: [node],
      groups: const [
        ProxyGroup(
          id: 'g',
          name: '手动选择',
          type: ProxyGroupType.select,
          members: [],
        ),
      ],
      rules: const [
        RuleEntry(id: 'r', action: RuleAction.proxy, outboundGroupId: 'g'),
      ],
    );

void main() {
  group('分享链接解析', () {
    test('ss（SIP002，userinfo base64）', () {
      final cred = base64.encode(utf8.encode('aes-256-gcm:password123'));
      final node = ShareLinkParser.parse(
          'ss://$cred@hk.example.com:8388#${Uri.encodeComponent('香港-01')}');
      expect(node, isNotNull);
      expect(node!.protocol, ProxyProtocol.ss);
      expect(node.server, 'hk.example.com');
      expect(node.port, 8388);
      expect(node.name, '香港-01');
      expect(node.params['cipher'], 'aes-256-gcm');
      expect(node.params['password'], 'password123');
    });

    test('ss（旧式整体 base64）', () {
      final blob = base64.encode(utf8.encode('chacha20-ietf-poly1305:pw@1.2.3.4:443'));
      final node = ShareLinkParser.parse('ss://$blob#US');
      expect(node, isNotNull);
      expect(node!.server, '1.2.3.4');
      expect(node.port, 443);
      expect(node.params['cipher'], 'chacha20-ietf-poly1305');
    });

    test('vmess（v2rayN base64 JSON）', () {
      final payload = base64.encode(utf8.encode(jsonEncode({
        'v': '2',
        'ps': 'JP-WS',
        'add': 'jp.example.com',
        'port': '443',
        'id': 'b831381d-6324-4d53-ad4f-8cda48b30811',
        'aid': '0',
        'scy': 'auto',
        'net': 'ws',
        'host': 'cdn.example.com',
        'path': '/ws',
        'tls': 'tls',
        'sni': 'jp.example.com',
      })));
      final node = ShareLinkParser.parse('vmess://$payload');
      expect(node, isNotNull);
      expect(node!.protocol, ProxyProtocol.vmess);
      expect(node.params['uuid'], 'b831381d-6324-4d53-ad4f-8cda48b30811');
      expect(node.params['network'], 'ws');
      expect(node.params['tls'], true);
      expect(node.params['wsHost'], 'cdn.example.com');
      expect(node.params['path'], '/ws');
    });

    test('vless（reality + tcp）', () {
      final node = ShareLinkParser.parse(
        'vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.1.1.1:443'
        '?encryption=none&security=reality&sni=www.apple.com&fp=chrome'
        '&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=6ba85179&type=tcp'
        '&flow=xtls-rprx-vision#Reality%E8%8A%82%E7%82%B9',
      );
      expect(node, isNotNull);
      expect(node!.protocol, ProxyProtocol.vless);
      expect(node.params['reality'], true);
      expect(node.params['tls'], true);
      expect(node.params['publicKey'], 'SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc');
      expect(node.params['shortId'], '6ba85179');
      expect(node.params['flow'], 'xtls-rprx-vision');
      expect(node.params['fingerprint'], 'chrome');
    });

    test('trojan + hysteria2 + tuic', () {
      final trojan = ShareLinkParser.parse(
          'trojan://pass%40word@tj.example.com:443?sni=tj.example.com#TJ');
      expect(trojan!.params['password'], 'pass@word');
      expect(trojan.params['sni'], 'tj.example.com');

      final hy2 = ShareLinkParser.parse(
          'hy2://pw@hy.example.com:8443?sni=hy.example.com&obfs=salamander&obfs-password=ob&insecure=1#HY2');
      expect(hy2!.protocol, ProxyProtocol.hysteria2);
      expect(hy2.params['obfs'], 'salamander');
      expect(hy2.params['obfsPassword'], 'ob');
      expect(hy2.params['insecure'], true);

      final tuic = ShareLinkParser.parse(
          'tuic://b831381d-6324-4d53-ad4f-8cda48b30811:tuicpw@tu.example.com:443?congestion_control=bbr&alpn=h3&uuid=x#TU');
      expect(tuic!.params['uuid'], 'b831381d-6324-4d53-ad4f-8cda48b30811');
      expect(tuic.params['password'], 'tuicpw');
      expect(tuic.params['congestionControl'], 'bbr');
      expect(tuic.params['alpn'], 'h3');
    });

    test('ssr（整体 base64 + 内层 base64 参数）', () {
      final inner = base64.encode(utf8.encode('origin'));
      final pass = base64.encode(utf8.encode('ssrpass'));
      final remarks = base64.encode(utf8.encode('SSR节点'));
      final body = base64.encode(utf8.encode(
          'ssr.example.com:8388:$inner:aes-256-cfb:tls1.2_ticket_auth:$pass'
          '/?remarks=$remarks&protoparam=&obfsparam='));
      final node = ShareLinkParser.parse('ssr://$body');
      expect(node, isNotNull);
      expect(node!.protocol, ProxyProtocol.ssr);
      expect(node.server, 'ssr.example.com');
      expect(node.params['password'], 'ssrpass');
      expect(node.params['cipher'], 'aes-256-cfb');
      expect(node.name, 'SSR节点');
    });

    test('批量解析跳过无效行', () {
      final cred = base64.encode(utf8.encode('aes-128-gcm:pw'));
      final nodes = ShareLinkParser.parseAll([
        '垃圾行',
        '',
        'ss://$cred@a.com:1#A',
        'https://example.com/not-a-proxy',
      ].join('\n'));
      expect(nodes, hasLength(1));
      expect(nodes.first.name, 'A');
    });
  });

  group('订阅解析', () {
    test('base64 整体编码的链接列表', () {
      final cred = base64.encode(utf8.encode('aes-128-gcm:pw'));
      final links = [
        'ss://$cred@a.example.com:1#A',
        'ss://$cred@b.example.com:2#B',
      ].join('\n');
      final result = SubscriptionFetcher.parseBody(
        base64.encode(utf8.encode(links)),
        info: SubscriptionFetcher.parseUserInfoHeader(
            'upload=1073741824; download=2147483648; total=10737418240; expire=1798761600'),
      );
      expect(result.format, 'links');
      expect(result.nodes, hasLength(2));
      expect(result.info!.usedRatio, closeTo(0.3, 0.01));
    });

    test('Clash YAML proxies 段（vless + reality + ws）', () {
      const yamlBody = '''
port: 7890
proxies:
  - name: "HK-01"
    type: vless
    server: hk.example.com
    port: 443
    uuid: b831381d-6324-4d53-ad4f-8cda48b30811
    tls: true
    servername: www.apple.com
    client-fingerprint: chrome
    network: ws
    ws-opts:
      path: /path
      headers:
        Host: hk.example.com
    reality-opts:
      public-key: pbk_value
      short-id: "0123abcd"
  - name: "US-01"
    type: trojan
    server: us.example.com
    port: 443
    password: tp
    skip-cert-verify: true
''';
      final result = SubscriptionFetcher.parseBody(yamlBody);
      expect(result.format, 'clash-yaml');
      expect(result.nodes, hasLength(2));
      final hk = result.nodes.first;
      expect(hk.protocol, ProxyProtocol.vless);
      expect(hk.params['reality'], true);
      expect(hk.params['publicKey'], 'pbk_value');
      expect(hk.params['wsHost'], 'hk.example.com');
      final us = result.nodes[1];
      expect(us.protocol, ProxyProtocol.trojan);
      expect(us.params['insecure'], true);
    });

    test('sing-box JSON outbounds 段', () {
      final body = jsonEncode({
        'log': {'level': 'info'},
        'outbounds': [
          {
            'type': 'selector',
            'tag': '手动选择',
            'outbounds': ['v1'],
          },
          {
            'type': 'vless',
            'tag': 'V1',
            'server': 'v.example.com',
            'server_port': 443,
            'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
            'flow': 'xtls-rprx-vision',
            'tls': {
              'enabled': true,
              'server_name': 'www.apple.com',
              'utls': {'enabled': true, 'fingerprint': 'chrome'},
              'reality': {
                'enabled': true,
                'public_key': 'pbk',
                'short_id': '0123abcd',
              },
            },
          },
        ],
      });
      final result = SubscriptionFetcher.parseBody(body);
      expect(result.format, 'singbox-json');
      expect(result.nodes, hasLength(1));
      final node = result.nodes.first;
      expect(node.name, 'V1');
      expect(node.params['flow'], 'xtls-rprx-vision');
      expect(node.params['fingerprint'], 'chrome');
    });
  });

  group('编译器参数规范化', () {
    test('mihomo：vless reality → reality-opts + ws-opts', () {
      final node = ShareLinkParser.parse(
        'vless://uuid-1@hk.example.com:443?security=reality&sni=www.apple.com'
        '&pbk=pbk_value&sid=0123abcd&type=ws&path=%2Fwspath&host=cdn.example.com#R',
      )!;
      final yaml = const MihomoCompiler().compileToString(_profileWith(node));
      expect(yaml, contains('reality-opts:'));
      expect(yaml, contains('public-key: pbk_value'));
      expect(yaml, contains('short-id: 0123abcd'));
      expect(yaml, contains('ws-opts:'));
      expect(yaml, contains('path: /wspath'));
    });

    test('sing-box：vless reality → tls.reality + transport', () {
      final node = ShareLinkParser.parse(
        'vless://uuid-1@hk.example.com:443?security=reality&fp=chrome'
        '&sni=www.apple.com&pbk=pbk_value&sid=0123abcd&type=tcp&flow=xtls-rprx-vision#R',
      )!;
      final json = const SingboxCompiler()
          .compile(_profileWith(node).copyWith(coreKind: CoreKind.singbox));
      final outbound = (json['outbounds'] as List<Object?>)
          .map((o) => o as Map<Object?, Object?>)
          .firstWhere((o) => o['tag'] == 'R');
      final tls = outbound['tls'] as Map<Object?, Object?>;
      expect(tls['server_name'], 'www.apple.com');
      final reality = tls['reality'] as Map<Object?, Object?>;
      expect(reality['public_key'], 'pbk_value');
      expect(reality['short_id'], '0123abcd');
      final utls = tls['utls'] as Map<Object?, Object?>;
      expect(utls['fingerprint'], 'chrome');
      expect(outbound['flow'], 'xtls-rprx-vision');
    });

    test('sing-box：vmess ws → transport + alter_id', () {
      final node = ShareLinkParser.parse(
        'vless://uuid-1@jp.example.com:443?type=ws&path=%2Fws&host=cdn.example.com&security=tls&sni=jp.example.com#VM',
      )!.copyWith(name: 'VM');
      final json = const SingboxCompiler()
          .compile(_profileWith(node).copyWith(coreKind: CoreKind.singbox));
      final outbound = (json['outbounds'] as List<Object?>)
          .map((o) => o as Map<Object?, Object?>)
          .firstWhere((o) => o['tag'] == 'VM');
      final transport = outbound['transport'] as Map<Object?, Object?>;
      expect(transport['type'], 'ws');
      expect(transport['path'], '/ws');
      expect((transport['headers'] as Map)['Host'], 'cdn.example.com');
      expect(((outbound['tls'] as Map)['server_name']), 'jp.example.com');
    });
  });
}
