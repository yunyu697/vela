/// SystemProxy 命令构建测试（注入 fake 执行器，不真正改系统设置）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/platform/system_proxy.dart';

void main() {
  // 本测试在 macOS 宿主上运行：Platform.isMacOS 为真，走 macOS 分支。
  // Linux/Windows 分支在对应平台上由 CI 覆盖（当前 CI 为 ubuntu）。
  test('enable：对每个网络服务设置 web/secure/socks 代理与绕过域', () async {
    final calls = <(String, List<String>)>[];
    SystemProxy.instance.runCmd = (exe, args) async {
      calls.add((exe, args));
      if (args.first == '-listallnetworkservices') {
        return ProcessResult(0, 0, 'An asterisk (*) denotes '
            'that a network service is disabled.\nWi-Fi\n*Disabled VPN\n'
            'Ethernet\n', '');
      }
      return ProcessResult(0, 0, '', '');
    };

    await SystemProxy.instance.enable(port: 7890);

    final services =
        calls.where((c) => c.$2.contains('Wi-Fi')).map((c) => c.$2.first);
    expect(services, containsAll(['-setwebproxy', '-setsecurewebproxy']));
    // 禁用的服务（* 前缀）不应被触碰
    final argsAll = calls.expand((c) => c.$2);
    expect(argsAll.contains('*Disabled VPN'), isFalse);
    // 端口正确
    expect(
      calls.any((c) => c.$2.contains('7890')),
      isTrue,
    );
    expect(SystemProxy.instance.isEnabled, isTrue);
  });

  test('disable：对每个网络服务关闭三类代理', () async {
    final calls = <(String, List<String>)>[];
    SystemProxy.instance.runCmd = (exe, args) async {
      calls.add((exe, args));
      if (args.first == '-listallnetworkservices') {
        return ProcessResult(0, 0, 'header\nWi-Fi\n', '');
      }
      return ProcessResult(0, 0, '', '');
    };

    await SystemProxy.instance.disable();

    expect(
      calls.any((c) => c.$2.first == '-setwebproxy' && c.$2.last == 'off'),
      isTrue,
    );
    expect(
      calls.any((c) => c.$2.first == '-setsocksfirewallproxy' && c.$2.last == 'off'),
      isTrue,
    );
    expect(SystemProxy.instance.isEnabled, isFalse);
  });

  test('失败时 enable 返回 false 且状态不翻转', () async {
    SystemProxy.instance.runCmd = (exe, args) async {
      if (args.first == '-listallnetworkservices') {
        return ProcessResult(0, 0, 'header\nWi-Fi\n', '');
      }
      return ProcessResult(0, 1, '', 'mock failure');
    };

    await SystemProxy.instance.enable(port: 7890);
    // macOS 下部分失败 → allOk false → 状态不翻转
    // （v1 语义：仅全部成功才标记 enabled）
    expect(SystemProxy.instance.isEnabled, isFalse);
  });
}
