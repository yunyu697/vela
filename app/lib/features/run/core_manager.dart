/// 内核运行管理（应用级单例）。
///
/// UI（运行页）只与它交互：启动 = 按内核选择编译器编译 Profile → 写配置
/// 文件 → 交给对应 CoreAdapter（mihomo 走 unix socket controller，
/// sing-box 走 127.0.0.1 + secret）。切换内核 = [switchCore]：先停止
/// 当前内核，再用另一套编译器编译同一 Profile 启动——运行层无感。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/compiler/mihomo_compiler.dart';
import '../../core/compiler/singbox_compiler.dart';
import '../../core/cores/core_adapter.dart';
import '../../core/cores/mihomo_adapter.dart';
import '../../core/cores/singbox_adapter.dart';
import '../../core/ir/profile.dart';
import '../../core/platform/permissions.dart';
import '../../core/storage/kv_store.dart';

class CoreManager extends ChangeNotifier {
  CoreManager._();
  static final CoreManager instance = CoreManager._();

  CoreAdapter? _adapter;
  StreamSubscription<CoreStatus>? _statusSub;
  CoreStatus _status = const CoreStatus(CoreStatusKind.stopped);
  Profile? _activeProfile;
  String _lastError = '';
  String? _lastRunDir;

  CoreStatus get status => _status;
  Profile? get activeProfile => _activeProfile;
  String get lastError => _lastError;
  bool get isActive =>
      _status.kind == CoreStatusKind.running ||
      _status.kind == CoreStatusKind.starting;

  /// 实时流量统计流（未运行时为 null）。
  Stream<StatsSnapshot>? get stats => _adapter?.stats;

  CoreAdapter _adapterFor(CoreKind kind) => switch (kind) {
        CoreKind.mihomo => MihomoAdapter(),
        CoreKind.singbox => SingboxAdapter(),
      };

  /// 探测一个空闲 TCP 端口（sing-box clash API 用；存在竞态窗口但
  /// 实践上足够可靠，端口被占时内核启动会立即暴露）。
  static Future<String> _freeLoopbackAddr() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    return '127.0.0.1:$port';
  }

  static String _randomSecret() {
    final rng = Random.secure();
    return List.generate(
            24, (i) => 'abcdefghijklmnopqrstuvwxyz0123456789'[rng.nextInt(36)])
        .join();
  }

  /// 启动指定 Profile（按其 coreKind 自动选择编译器与适配器）。
  /// [runDir] 为应用数据目录（配置文件与缓存存放处）。
  Future<void> start(Profile profile, {required String runDir}) async {
    // 平台权限硬守卫：iOS（未集成 Network Extension）等不支持的平台
    // 在此拦截，覆盖概览页 / 运行页 / 命令面板所有启动入口。
    final blocked = await VelaPermissions.canStartCore();
    if (blocked != null) throw CoreStartException(blocked);
    if (isActive) throw StateError('内核已在运行，请先停止');
    _lastError = '';
    _lastRunDir = runDir;

    final configText = switch (profile.coreKind) {
      CoreKind.mihomo => const MihomoCompiler().compileToString(profile),
      CoreKind.singbox => const SingboxCompiler().compileToString(profile),
    };

    final dir = Directory('$runDir/profiles/${profile.id}')
      ..createSync(recursive: true);
    final ext = profile.coreKind == CoreKind.mihomo ? 'yaml' : 'json';
    final configFile = File('${dir.path}/config.$ext')
      ..writeAsStringSync(configText);

    // controller 地址：mihomo 走短路径 unix socket（macOS socket 路径上限
    // 104 字符，沙盒容器内必超限）；sing-box 走 127.0.0.1 随机端口 + secret
    final String controller;
    String secret = '';
    if (profile.coreKind == CoreKind.mihomo) {
      controller = AppPaths.coreSocketPath();
    } else {
      controller = await _freeLoopbackAddr();
      secret = _randomSecret();
    }

    final adapter = _adapter = _adapterFor(profile.coreKind);
    _statusSub?.cancel();
    _statusSub = adapter.status.listen((s) {
      _status = s;
      notifyListeners();
    });
    _activeProfile = profile;
    notifyListeners();

    try {
      await adapter.start(CoreRunRequest(
        profile: profile,
        configFile: configFile.path,
        workDir: await AppPaths.coreWorkDir(dir.path),
        controllerSocketPath: controller,
        secret: secret,
      ));
      // 状态流的回调是异步微任务派发，await 返回时可能尚未执行；
      // 这里同步读取适配器当前状态，保证 start() 返回即反映 running
      _status = adapter.currentStatus;
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  /// 运行时切换内核：停止当前 → 用新内核的编译器重编译同一 Profile →
  /// 启动。这就是"切内核自动切换到相应配置"的核心链路。
  Future<void> switchCore(CoreKind newKind) async {
    final profile = _activeProfile;
    if (profile == null) throw StateError('没有正在运行的配置');
    if (profile.coreKind == newKind) return;
    final runDir = _lastRunDir;
    if (runDir == null) throw StateError('缺少运行目录信息');
    await stop();
    await start(profile.copyWith(coreKind: newKind), runDir: runDir);
  }

  Future<void> stop() async {
    await _adapter?.stop();
    // 状态流回调是异步微任务派发，stop() 返回时同步读取当前状态，
    // 保证 isActive 立即为 false（switchCore 依赖此语义）
    _status = _adapter?.currentStatus ?? const CoreStatus(CoreStatusKind.stopped);
    notifyListeners();
  }

  Future<List<ConnectionInfo>> connections() =>
      _adapter?.connections() ?? Future.value(const []);

  Future<int?> testDelay(String nodeTag) =>
      _adapter?.testDelay(nodeTag) ?? Future.value(null);

  /// 手动分组里切换选中出口。
  Future<void> selectOutbound(String groupTag, String outboundTag) async {
    await _adapter?.selectOutbound(groupTag, outboundTag);
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }
}
