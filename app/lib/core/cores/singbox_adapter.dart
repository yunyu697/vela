/// sing-box 适配器（桌面端真实实现）。
///
/// 数据流：编译器产出 JSON → FFI 调用 Go 桥接（cores/singbox-bridge）启动
/// 内核 → 控制面经 127.0.0.1:<port> 的 clash API（v1.14 内核仅支持 TCP
/// 监听，Go 侧强制注入 secret）。
///
/// 与 mihomo 的差异：启停 = 全新 Box 实例 Start/Close；配置为 JSON。
/// 移动端（gomobile 平台通道）在 Android/iOS 接入时替换本实现。
library;

import 'dart:async';
import 'dart:io';

import '../ir/profile.dart';
import 'clash_api_client.dart';
import 'core_adapter.dart';
import 'core_bridge.dart';
import 'ffi_bridge.dart' show BridgeCore;

class SingboxAdapter extends CoreAdapter {
  final _statusCtrl = StreamController<CoreStatus>.broadcast();
  final _statsCtrl = StreamController<StatsSnapshot>.broadcast();
  final _logsCtrl = StreamController<LogEntry>.broadcast();

  CoreBridge? _bridge;
  ClashApiClient? _api;
  Timer? _statsTimer;

  // 流量速率计算基准（clash API 只给累计值）
  int _lastUpTotal = 0;
  int _lastDownTotal = 0;
  bool _hasLastSample = false;

  CoreStatus _current = const CoreStatus(CoreStatusKind.stopped);

  @override
  CoreStatus get currentStatus => _current;

  @override
  CoreKind get kind => CoreKind.singbox;

  @override
  Stream<CoreStatus> get status => _statusCtrl.stream;

  @override
  Stream<LogEntry> get logs => _logsCtrl.stream;

  @override
  Stream<StatsSnapshot> get stats => _statsCtrl.stream;

  void _setStatus(CoreStatus s) {
    _current = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }

  @override
  Future<void> start(CoreRunRequest request) async {
    final bridge = _bridge = createCoreBridge(BridgeCore.singbox);
    _setStatus(const CoreStatus(CoreStatusKind.starting));

    final json = await File(request.configFile).readAsString();
    await Directory(request.workDir).create(recursive: true);

    try {
      await bridge.start(CoreBridgeRequest(
        configText: json,
        homeDir: request.workDir,
        controller: request.controllerSocketPath,
        secret: request.secret,
        tun: request.profile.inbound.mode == AccessMode.tun,
      ));
    } on CoreStartException catch (e) {
      _setStatus(CoreStatus(CoreStatusKind.error, e.message));
      rethrow;
    }

    _api = ClashApiClient.tcp(request.controllerSocketPath,
        secret: request.secret);
    await _waitControllerReady();

    _lastUpTotal = _lastDownTotal = 0;
    _hasLastSample = false;
    _setStatus(const CoreStatus(CoreStatusKind.running));
    _startStatsPolling();
  }

  @override
  Future<void> stop() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    final bridge = _bridge;
    if (bridge != null && bridge.isRunning()) {
      try {
        await bridge.stop();
      } on CoreStartException catch (e) {
        _setStatus(CoreStatus(CoreStatusKind.error, e.message));
        rethrow;
      }
    }
    _api = null;
    _setStatus(const CoreStatus(CoreStatusKind.stopped));
  }

  @override
  Future<List<ConnectionInfo>> connections() async {
    final api = _api;
    if (api == null || _current.kind != CoreStatusKind.running) return const [];
    final raw = await api.connectionsRaw();
    if (raw == null) return const [];
    final items = (raw['connections'] as List<Object?>?) ?? const [];
    return [
      for (final item in items)
        if (item is Map<Object?, Object?>)
          _connectionFromJson(item.cast<String, Object?>()),
    ];
  }

  @override
  Future<int?> testDelay(String nodeTag) =>
      _api?.proxyDelay(nodeTag) ?? Future.value(null);

  @override
  Future<void> selectOutbound(String groupTag, String outboundTag) async {
    final api = _api;
    if (api == null) {
      throw StateError('内核未运行，无法切换节点');
    }
    await api.selectProxy(groupTag, outboundTag);
  }

  ConnectionInfo _connectionFromJson(Map<String, Object?> item) {
    final meta =
        (item['metadata'] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
            const {};
    final host = (meta['host'] ?? '').toString();
    final dstIp = (meta['destinationIP'] ?? '').toString();
    final dstPort = (meta['destinationPort'] ?? '').toString();
    final upTotal = (item['upload'] as num?)?.toInt() ?? 0;
    final downTotal = (item['download'] as num?)?.toInt() ?? 0;
    return ConnectionInfo(
      id: (item['id'] ?? '').toString(),
      network: (meta['network'] ?? '').toString(),
      source: '${meta['sourceIP'] ?? ''}:${meta['sourcePort'] ?? ''}',
      destination: host.isNotEmpty ? '$host:$dstPort' : '$dstIp:$dstPort',
      rule: (item['rule'] ?? '').toString(),
      chain: ((item['chains'] as List<Object?>?) ?? const []).cast<String>(),
      upload: upTotal,
      download: downTotal,
      start: DateTime.tryParse((item['start'] ?? '').toString()) ??
          DateTime.now(),
    );
  }

  /// controller 就绪轮询（内核启动是异步过程，TCP 端口监听有短暂延迟）。
  Future<void> _waitControllerReady() async {
    final api = _api!;
    Object? lastErr;
    for (var i = 0; i < 50; i++) {
      try {
        await api.version();
        return;
      } catch (e) {
        lastErr = e;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    _setStatus(CoreStatus(CoreStatusKind.error, 'controller 未就绪: $lastErr'));
    throw CoreStartException('sing-box controller 未就绪: $lastErr');
  }

  void _startStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final api = _api;
      if (api == null || _statsCtrl.isClosed) return;
      try {
        final raw = await api.connectionsRaw();
        if (raw == null) return;
        final upTotal = (raw['uploadTotal'] as num?)?.toInt() ?? 0;
        final downTotal = (raw['downloadTotal'] as num?)?.toInt() ?? 0;
        var upBps = 0;
        var downBps = 0;
        if (_hasLastSample) {
          upBps = (upTotal - _lastUpTotal).clamp(0, 1 << 60);
          downBps = (downTotal - _lastDownTotal).clamp(0, 1 << 60);
        }
        _lastUpTotal = upTotal;
        _lastDownTotal = downTotal;
        _hasLastSample = true;
        _statsCtrl.add(StatsSnapshot(
          upBps: upBps,
          downBps: downBps,
          totalUp: upTotal,
          totalDown: downTotal,
        ));
      } catch (_) {
        // 轮询失败静默（内核刚停止的竞态窗口）
      }
    });
  }

  /// 释放流控制器（应用退出时调用）。
  Future<void> dispose() async {
    _statsTimer?.cancel();
    await _statusCtrl.close();
    await _statsCtrl.close();
    await _logsCtrl.close();
  }
}
