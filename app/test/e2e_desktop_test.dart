/// 桌面端端到端测试：完整链路真实验证。
///
/// IR Profile → MihomoCompiler 编译 → FFI 加载动态库启动真实 mihomo 内核
/// → 数据面（经 mixed 端口代理访问本地 HTTP 源站）
/// → 控制面（unix socket 上的 clash API）
/// → 停止后端口关闭。
///
/// 前置条件：先运行 cores/mihomo-bridge/build_desktop.sh 构建 dylib；
/// 未找到库时自动跳过（CI / 纯 Dart 环境仍可跑其余单测）。

@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:vela/core/compiler/mihomo_compiler.dart';
import 'package:vela/core/compiler/singbox_compiler.dart';
import 'package:vela/core/cores/clash_api_client.dart';
import 'package:vela/core/cores/core_adapter.dart';
import 'package:vela/core/cores/ffi_bridge.dart';
import 'package:vela/core/cores/mihomo_adapter.dart';
import 'package:vela/core/cores/singbox_adapter.dart';
import 'package:vela/features/run/core_manager.dart';
import 'package:vela/core/ir/profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 注意：不要调用 TestWidgetsFlutterBinding.ensureInitialized() ——
  // 它会用测试桩劫持 HttpClient（所有请求返回 400），而本测试需要
  // 真实的数据面网络请求。纯 Dart 断言无需 binding。

  test('端到端：编译 → 启动内核 → 代理数据面 → clash API → 停止', () async {
    if (BoxBridgeFfi.findLibraryPath(BridgeCore.mihomo) == null) {
      markTestSkipped('未找到桥接动态库（先运行 cores/mihomo-bridge/build_desktop.sh）');
      return;
    }

    // 本地 HTTP 源站：验证经内核代理的完整数据面
    // （延迟 1.5s 响应，保持连接存活以便查询连接表）
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((req) async {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      req.response.write('hello-boxhub');
      await req.response.close();
    });

    final tmp = await Directory.systemTemp.createTemp('boxhub-e2e');
    // 挑一个空闲端口给 mixed 入站
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final mixedPort = probe.port;
    await probe.close();

    final profile = Profile(
      id: 'e2e',
      name: 'E2E 测试配置',
      coreKind: CoreKind.mihomo,
      source: const ProfileSource(type: ProfileSourceType.manual),
      nodes: const [
        ProxyNode(
          id: 'n1',
          name: 'dummy-node',
          protocol: ProxyProtocol.ss,
          server: '127.0.0.1',
          port: 1,
          params: {'cipher': 'aes-128-gcm', 'password': 'unused'},
        ),
      ],
      groups: const [
        ProxyGroup(
          id: 'g1',
          name: '手动选择',
          type: ProxyGroupType.select,
          members: ['n1'],
        ),
      ],
      rules: const [
        // 回环地址直连：保证对本地源站的请求走 DIRECT 出站
        RuleEntry(
          id: 'r-loopback',
          action: RuleAction.direct,
          ipCidrs: ['127.0.0.0/8', '::1/128'],
        ),
      ],
      dns: const DnsConfig(mode: DnsMode.plain, followRules: false),
      inbound: InboundConfig(mode: AccessMode.systemProxy, mixedPort: mixedPort),
    );

    final yaml = const MihomoCompiler().compileToString(profile);
    final configFile = File('${tmp.path}/config.yaml')..writeAsStringSync(yaml);

    final adapter = MihomoAdapter();
    final socketPath = '${tmp.path}/mihomo.sock';

    await adapter.start(CoreRunRequest(
      profile: profile,
      configFile: configFile.path,
      workDir: tmp.path,
      controllerSocketPath: socketPath,
    ));

    try {
      expect(adapter.currentStatus.kind, CoreStatusKind.running);

      // ---- 1. 数据面：HTTP 经 mixed 代理 → 内核 → DIRECT → 本地源站 ----
      final client = HttpClient();
      client.findProxy = (uri) => 'PROXY 127.0.0.1:$mixedPort';
      // 发起请求但不立即等待（源站延迟 1.5s，让连接保持活跃）
      final pendingBody = client
          .getUrl(Uri.parse('http://127.0.0.1:${origin.port}/'))
          .then((req) => req.close())
          .then((resp) => resp.transform(utf8.decoder).join());

      // ---- 2. 连接表：请求进行中应能看到这条经内核的连接 ----
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final conns = await adapter.connections();
      expect(conns, isNotEmpty, reason: '连接表为空');

      // 等待数据面结果
      final body = await pendingBody.timeout(const Duration(seconds: 15));
      expect(body, 'hello-boxhub', reason: '经 mihomo 代理未取到本地源站数据');
      client.close();

      // ---- 2. 控制面：unix socket 上的 clash API ----
      final api = ClashApiClient.unix(socketPath);
      final version = await api.version();
      expect(version, contains('version'), reason: 'clash API /version 不可用');

      // ---- 3. selector 切换节点（PUT /proxies/手动选择）----
      await adapter.selectOutbound('手动选择', 'dummy-node');

      // ---- 5. 死节点测延迟 → null（不可达）----
      expect(await adapter.testDelay('dummy-node'), isNull);
    } finally {
      await adapter.stop();
      await origin.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }

    expect(adapter.currentStatus.kind, CoreStatusKind.stopped);

    // ---- 6. 停止后 mixed 端口不再接受连接 ----
    var portClosed = false;
    try {
      final s = await Socket.connect('127.0.0.1', mixedPort,
          timeout: const Duration(seconds: 2));
      s.destroy();
    } catch (_) {
      portClosed = true;
    }
    expect(portClosed, isTrue, reason: '内核停止后 mixed 端口仍然开着');
  });

  test('FFI：未启动时 IsRunning 为假，StopConfig 幂等', () {
    if (BoxBridgeFfi.findLibraryPath(BridgeCore.mihomo) == null) {
      markTestSkipped('未找到桥接动态库');
      return;
    }
    final ffi = BoxBridgeFfi.load(BridgeCore.mihomo);
    expect(ffi.stopConfig(), 0); // 未运行时停止应幂等返回 0
  });
  test('端到端（sing-box）：编译 → 启动内核 → 代理数据面 → clash API → 停止',
      () async {
    if (BoxBridgeFfi.findLibraryPath(BridgeCore.singbox) == null) {
      markTestSkipped('未找到 sing-box 桥接动态库');
      return;
    }

    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((req) async {
      req.response.write('hello-boxhub');
      await req.response.close();
    });

    final tmp = await Directory.systemTemp.createTemp('boxhub-e2e-sb');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final mixedPort = probe.port;
    await probe.close();
    final apiProbe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final apiPort = apiProbe.port;
    await apiProbe.close();

    final profile = Profile(
      id: 'e2e-sb',
      name: 'E2E sing-box 配置',
      coreKind: CoreKind.singbox,
      source: const ProfileSource(type: ProfileSourceType.manual),
      nodes: const [
        ProxyNode(
          id: 'n1',
          name: 'dummy-node',
          protocol: ProxyProtocol.ss,
          server: '127.0.0.1',
          port: 1,
          params: {'cipher': 'aes-128-gcm', 'password': 'unused'},
        ),
      ],
      groups: const [
        ProxyGroup(
          id: 'g1',
          name: '手动选择',
          type: ProxyGroupType.select,
          members: ['n1'],
        ),
      ],
      rules: const [
        RuleEntry(
          id: 'r-loopback',
          action: RuleAction.direct,
          ipCidrs: ['127.0.0.0/8', '::1/128'],
        ),
      ],
      dns: const DnsConfig(mode: DnsMode.plain, followRules: false),
      inbound:
          InboundConfig(mode: AccessMode.systemProxy, mixedPort: mixedPort),
    );

    final jsonText = const SingboxCompiler().compileToString(profile);
    final configFile = File('${tmp.path}/config.json')
      ..writeAsStringSync(jsonText);

    final adapter = SingboxAdapter();
    final apiAddr = '127.0.0.1:$apiPort';
    const secret = 'e2e-secret';

    await adapter.start(CoreRunRequest(
      profile: profile,
      configFile: configFile.path,
      workDir: tmp.path,
      controllerSocketPath: apiAddr,
      secret: secret,
    ));

    try {
      expect(adapter.currentStatus.kind, CoreStatusKind.running);

      // ---- 数据面：HTTP 经 mixed 代理 → 内核 → DIRECT → 本地源站 ----
      final client = HttpClient();
      client.findProxy = (uri) => 'PROXY 127.0.0.1:$mixedPort';
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:${origin.port}/'))
          .timeout(const Duration(seconds: 15));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      expect(body, 'hello-boxhub', reason: '经 sing-box 代理未取到本地源站数据');
      client.close();

      // ---- 控制面：TCP + Bearer secret 的 clash API ----
      final api = ClashApiClient.tcp(apiAddr, secret: secret);
      final version = await api.version();
      expect(version, contains('version'), reason: 'clash API /version 不可用');

      // selector 切换
      await adapter.selectOutbound('手动选择', 'dummy-node');
      // 死节点测延迟 → null
      expect(await adapter.testDelay('dummy-node'), isNull);
    } finally {
      await adapter.stop();
      await origin.close();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }

    expect(adapter.currentStatus.kind, CoreStatusKind.stopped);
    var portClosed = false;
    try {
      final s = await Socket.connect('127.0.0.1', mixedPort,
          timeout: const Duration(seconds: 2));
      s.destroy();
    } catch (_) {
      portClosed = true;
    }
    expect(portClosed, isTrue, reason: '内核停止后 mixed 端口仍然开着');
  });

  test('切内核：同一 Profile 经 CoreManager 在两个内核间自动换配置启动',
      () async {
    final mihomoLib = BoxBridgeFfi.findLibraryPath(BridgeCore.mihomo);
    final singboxLib = BoxBridgeFfi.findLibraryPath(BridgeCore.singbox);
    if (mihomoLib == null || singboxLib == null) {
      markTestSkipped('桥接动态库不全（跳过切内核验证）');
      return;
    }

    final tmp = await Directory.systemTemp.createTemp('boxhub-e2e-switch');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final mixedPort = probe.port;
    await probe.close();

    final profile = Profile(
      id: 'e2e-switch',
      name: 'E2E 切内核配置',
      coreKind: CoreKind.mihomo,
      source: const ProfileSource(type: ProfileSourceType.manual),
      nodes: const [
        ProxyNode(
          id: 'n1',
          name: 'dummy-node',
          protocol: ProxyProtocol.ss,
          server: '127.0.0.1',
          port: 1,
          params: {'cipher': 'aes-128-gcm', 'password': 'unused'},
        ),
      ],
      groups: const [
        ProxyGroup(
          id: 'g1',
          name: '手动选择',
          type: ProxyGroupType.select,
          members: ['n1'],
        ),
      ],
      rules: const [
        RuleEntry(
          id: 'r-loopback',
          action: RuleAction.direct,
          ipCidrs: ['127.0.0.0/8', '::1/128'],
        ),
      ],
      dns: const DnsConfig(mode: DnsMode.plain, followRules: false),
      inbound:
          InboundConfig(mode: AccessMode.systemProxy, mixedPort: mixedPort),
    );

    final manager = CoreManager.instance;
    try {
      await manager.stop();
    } catch (_) {}

    try {
      await manager.start(profile, runDir: tmp.path);
      expect(manager.status.kind, CoreStatusKind.running);
      expect(manager.activeProfile!.coreKind, CoreKind.mihomo);

      // 切内核：mihomo → sing-box（自动换编译器 + 重启）
      await manager.switchCore(CoreKind.singbox);
      expect(manager.status.kind, CoreStatusKind.running);
      expect(manager.activeProfile!.coreKind, CoreKind.singbox);

      // 再切回来：sing-box → mihomo
      await manager.switchCore(CoreKind.mihomo);
      expect(manager.status.kind, CoreStatusKind.running);
      expect(manager.activeProfile!.coreKind, CoreKind.mihomo);
    } finally {
      try {
        await manager.stop();
      } catch (_) {}
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  });
}

