/// 内核桥接统一抽象：桌面端 FFI / Android 平台通道。
///
/// mihomo 与 sing-box 两个桥接库（桌面 c-shared dylib / Android gomobile
/// aar）导出同构的控制面：start / stop / isRunning / lastError。
/// 本文件把"如何调到 Go"封装起来，CoreAdapter 只面向 [CoreBridge]。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'core_adapter.dart';
import 'ffi_bridge.dart';

/// 一次内核启动所需的参数（配置文本 + 控制面地址 + TUN 模式标记）。
class CoreBridgeRequest {
  const CoreBridgeRequest({
    required this.configText,
    required this.homeDir,
    required this.controller,
    this.secret = '',
    this.tun = false,
  });

  /// 编译器产出的最终配置（mihomo YAML / sing-box JSON）
  final String configText;

  /// 内核工作目录（Android 上由 Dart 侧从 getPaths 取 filesDir 传入）
  final String homeDir;

  /// external controller：mihomo 为 unix socket 路径，sing-box 为
  /// 127.0.0.1:<port>
  final String controller;
  final String secret;

  /// 是否以 TUN 模式运行（Android 上触发 VpnService 授权 + fd 注入）
  final bool tun;
}

abstract class CoreBridge {
  BridgeCore get core;

  /// 启动内核；失败抛 [CoreStartException]。
  Future<void> start(CoreBridgeRequest request);
  Future<void> stop();
  bool isRunning();
  String lastError();
}

/// 桌面端实现：FFI 调 c-shared 动态库。
///
/// 关键约束：FFI 调用是**同步阻塞**的——内核启动（解析配置、起 DNS/TUN/
/// 监听器）可达数秒，停止也可能阻塞。因此 start/stop/restart 一律丢进
/// 后台 isolate 执行，否则 UI 线程整个冻住（表现为「点启动就卡死」）。
///
/// 跨 isolate 安全性：动态库由 `DynamicLibrary.open` 按路径加载，进程内
/// 只有同一份实例；Go 桥的全局状态天然跨 isolate 共享，后台 isolate 里
/// 重新 load 只是重查符号表，不产生第二份内核。
class FfiCoreBridge implements CoreBridge {
  FfiCoreBridge(this.core);

  @override
  final BridgeCore core;

  BoxBridgeFfi? _ffi;
  BoxBridgeFfi get _impl => _ffi ??= BoxBridgeFfi.load(core);

  @override
  Future<void> start(CoreBridgeRequest request) async {
    final (rc, err) = await Isolate.run(() async {
      final ffi = BoxBridgeFfi.load(core);
      final rc = ffi.startConfig(
        request.configText,
        request.homeDir,
        request.controller,
        request.secret,
      );
      return (rc, rc == 0 ? '' : ffi.lastError());
    });
    if (rc != 0) {
      throw CoreStartException(err.isEmpty ? '未知错误' : err);
    }
  }

  @override
  Future<void> stop() async {
    final (rc, err) = await Isolate.run(() async {
      final ffi = BoxBridgeFfi.load(core);
      final rc = ffi.stopConfig();
      return (rc, rc == 0 ? '' : ffi.lastError());
    });
    if (rc != 0) {
      throw CoreStartException(err.isEmpty ? '未知错误' : err);
    }
  }

  @override
  bool isRunning() => _impl.isRunning();

  @override
  String lastError() => _impl.lastError();
}

/// Android 实现：MethodChannel → MainActivity → VpnService → gomobile aar。
///
/// TUN 模式时序：
///   1. Dart 调 startCore（tun: true）
///   2. Kotlin 检查 VpnService.prepare → 未授权则弹系统对话框，
///      返回 {status: permission_required}
///   3. 用户同意 → 服务启动 → 建立 TUN → fd 交给 Go 内核
///   4. 结果经 onCoreEvent 推回，本类完成挂起的 Completer
class AndroidCoreBridge implements CoreBridge {
  AndroidCoreBridge(this.core) {
    _registerHandler();
  }

  static const _channel = MethodChannel('dev.boxhub.boxhub/core');
  static bool _handlerRegistered = false;
  static Completer<({bool ok, String error})>? _pending;

  @override
  final BridgeCore core;

  bool _running = false;
  String _lastError = '';

  static void _registerHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCoreEvent') {
        final args = (call.arguments as Map<Object?, Object?>?) ?? const {};
        final pending = _pending;
        if (pending != null && !pending.isCompleted) {
          pending.complete((
            ok: args['ok'] == true,
            error: (args['error'] ?? '').toString(),
          ));
        }
      }
      return null;
    });
  }

  @override
  Future<void> start(CoreBridgeRequest request) async {
    _pending = Completer<({bool ok, String error})>();
    try {
      final res = await _channel
          .invokeMethod<Map<Object?, Object?>>('startCore', {
        'core': core.name,
        'config': request.configText,
        'homeDir': request.homeDir,
        'controller': request.controller,
        'secret': request.secret,
        'tun': request.tun,
      });
      final status = res?['status'];
      if (status == 'starting' || status == 'permission_required') {
        // 等 VpnService 侧最终结果（含用户授权对话框的等待时间）
        final event = await _pending!.future
            .timeout(const Duration(minutes: 5), onTimeout: () {
          return (ok: false, error: '内核启动超时（等待 VPN 授权或内核就绪）');
        });
        if (!event.ok) {
          _lastError = event.error;
          throw CoreStartException(
              event.error.isEmpty ? '内核启动失败' : event.error);
        }
      }
      _running = true;
      _lastError = '';
    } on PlatformException catch (e) {
      _lastError = e.message ?? e.code;
      throw CoreStartException('Android 内核启动失败: $_lastError');
    } finally {
      _pending = null;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopCore', {'core': core.name});
      _running = false;
    } on PlatformException catch (e) {
      throw CoreStartException('Android 内核停止失败: ${e.message ?? e.code}');
    }
  }

  @override
  bool isRunning() => _running;

  @override
  String lastError() => _lastError;
}

/// 按平台选择桥接实现。
CoreBridge createCoreBridge(BridgeCore core) =>
    Platform.isAndroid ? AndroidCoreBridge(core) : FfiCoreBridge(core);
