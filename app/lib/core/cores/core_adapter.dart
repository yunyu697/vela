/// 内核适配层抽象。
///
/// UI 只面向本接口；sing-box（libbox）与 mihomo（fork 库 + unix socket
/// controller）各自实现。运行时切换内核 = 换一个 CoreAdapter 实例，
/// 配置由编译器按内核重新生成，入站端口保持不变以减少断网瞬间。
library;

import '../ir/profile.dart';

enum CoreStatusKind { stopped, starting, running, stopping, error }

class CoreStatus {
  const CoreStatus(this.kind, [this.message]);
  final CoreStatusKind kind;
  final String? message;
}

/// 内核启动/停止失败（携带 Go 侧错误信息）。
class CoreStartException implements Exception {
  CoreStartException(this.message);
  final String message;

  @override
  String toString() => 'CoreStartException: $message';
}

class LogEntry {
  const LogEntry({required this.time, required this.level, required this.message});
  final DateTime time;
  final String level; // debug | info | warn | error
  final String message;
}

class StatsSnapshot {
  const StatsSnapshot({
    required this.upBps,
    required this.downBps,
    required this.totalUp,
    required this.totalDown,
  });
  final int upBps;
  final int downBps;
  final int totalUp;
  final int totalDown;
}

class ConnectionInfo {
  const ConnectionInfo({
    required this.id,
    required this.network,
    required this.source,
    required this.destination,
    required this.rule,
    required this.chain,
    required this.upload,
    required this.download,
    required this.start,
  });
  final String id;
  final String network; // tcp | udp
  final String source;
  final String destination;
  final String rule;
  final List<String> chain; // 命中的出口链
  final int upload;
  final int download;
  final DateTime start;
}

class CoreRunRequest {
  const CoreRunRequest({
    required this.profile,
    required this.configFile,
    required this.workDir,
    required this.controllerSocketPath,
    this.secret = '',
  });

  /// IR Profile（用于适配器做内核侧的补充设置）
  final Profile profile;

  /// 编译器产出的最终配置文件路径（sing-box JSON / mihomo YAML）
  final String configFile;
  final String workDir;

  /// external controller 地址：mihomo 为 unix socket 路径；
  /// sing-box 为 "127.0.0.1:<port>"（其 clashapi 仅支持 TCP）
  final String controllerSocketPath;

  /// clash API 访问密钥（sing-box TCP 监听必须；mihomo unix socket 可空）
  final String secret;
}

abstract class CoreAdapter {
  CoreKind get kind;

  /// 当前状态快照（同步读取；status 流的回调是异步派发，
  /// start() await 返回后立即查询时应使用本属性）。
  CoreStatus get currentStatus;

  Future<void> start(CoreRunRequest request);
  Future<void> stop();
  Future<void> restart(CoreRunRequest request) async {
    await stop();
    await start(request);
  }

  Stream<CoreStatus> get status;
  Stream<LogEntry> get logs;
  Stream<StatsSnapshot> get stats;

  Future<List<ConnectionInfo>> connections();
  Future<int?> testDelay(String nodeTag);

  /// 手动分组里切换选中的出口（selector）。
  Future<void> selectOutbound(String groupTag, String outboundTag);
}
