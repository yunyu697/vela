/// SystemProxy 命令构建测试（注入 fake 执行器，不真正改系统设置）。
///
/// 按宿主平台走各自分支：macOS 验证 networksetup 序列，
/// Linux（CI ubuntu）验证 gsettings 序列。Windows 分支在 Windows
/// 环境下由同样逻辑覆盖（此处仅结构上保持）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vela/core/platform/system_proxy.dart';

void main() {
  test('enable：命令序列与端口正确', () async {
    final calls = <(String, List<String>)>[];
    SystemProxy.instance.runCmd = (exe, args) async {
      calls.add((exe, args));
      if (Platform.isMacOS && args.first == '-listallnetworkservices') {
        return ProcessResult(0, 0, 'An asterisk (*) denotes '
            'that a network service is disabled.\nWi-Fi\n*Disabled VPN\n'
            'Ethernet\n', '');
      }
      return ProcessResult(0, 0, '', '');
    };

    await SystemProxy.instance.enable(port: 7890);

    if (Platform.isMacOS) {
      final services = calls
          .where((c) => c.$2.contains('Wi-Fi'))
          .map((c) => c.$2.first);
      expect(services, containsAll(['-setwebproxy', '-setsecurewebproxy']));
      // 禁用的服务（* 前缀）不应被触碰
      expect(
        calls.expand((c) => c.$2).contains('*Disabled VPN'),
        isFalse,
      );
    } else if (Platform.isLinux) {
      expect(calls.map((c) => c.$1), everyElement('gsettings'));
      // gsettings 参数是 ['set', schema, key, value]
      final keys = calls.map((c) => c.$2[2]).toSet();
      expect(keys, containsAll(['mode', 'host', 'port']));
    } else if (Platform.isWindows) {
      expect(calls.map((c) => c.$1), everyElement('reg'));
    }
    expect(
      calls.any((c) => c.$2.contains('7890')),
      isTrue,
      reason: '任一平台的命令都应包含端口',
    );
    expect(SystemProxy.instance.isEnabled, isTrue);
  });

  test('disable：关闭命令正确', () async {
    final calls = <(String, List<String>)>[];
    SystemProxy.instance.runCmd = (exe, args) async {
      calls.add((exe, args));
      if (Platform.isMacOS && args.first == '-listallnetworkservices') {
        return ProcessResult(0, 0, 'header\nWi-Fi\n', '');
      }
      return ProcessResult(0, 0, '', '');
    };

    await SystemProxy.instance.disable();

    if (Platform.isMacOS) {
      expect(
        calls.any((c) => c.$2.first == '-setwebproxy' && c.$2.last == 'off'),
        isTrue,
      );
      expect(
        calls.any((c) =>
            c.$2.first == '-setsocksfirewallproxy' && c.$2.last == 'off'),
        isTrue,
      );
    } else if (Platform.isLinux) {
      // mode 设回 'none'
      expect(
        calls.any((c) =>
            c.$2.length > 3 &&
            c.$2[2] == 'mode' &&
            c.$2[3].contains('none')),
        isTrue,
      );
    }
    expect(SystemProxy.instance.isEnabled, isFalse);
  });

  test('失败时 enable 状态不翻转', () async {
    SystemProxy.instance.runCmd = (exe, args) async {
      if (Platform.isMacOS && args.first == '-listallnetworkservices') {
        return ProcessResult(0, 0, 'header\nWi-Fi\n', '');
      }
      return ProcessResult(0, 1, '', 'mock failure');
    };

    await SystemProxy.instance.enable(port: 7890);
    // v1 语义：仅全部成功才标记 enabled
    expect(SystemProxy.instance.isEnabled, isFalse);
  });
}
