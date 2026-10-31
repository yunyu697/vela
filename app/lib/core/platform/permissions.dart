/// 平台能力与系统权限的统一入口。
///
/// Vela 的内核运行方式因平台而异，权限要求也不同：
///
/// | 平台      | 内核形态                     | 需要的系统权限                                  |
/// |-----------|------------------------------|------------------------------------------------|
/// | macOS     | 进程内 FFI 动态库            | 无（本机网络监听不需要额外授权）                |
/// | Windows   | 进程内 FFI 动态库            | 无                                              |
/// | Linux     | 进程内 FFI 动态库            | 无                                              |
/// | Android   | 前台服务 + gomobile          | VpnService 授权（TUN）、通知（13+ 前台服务通知）|
/// | iOS       | Network Extension + gomobile | VPN 配置授权（首次启动隧道时由系统弹窗）        |
///
/// UI 层在启动内核前应先调 [canStartCore] 拦截，Android 上再按需
/// 请求通知权限；VpnService 授权由 Kotlin 侧在 startCore 时拉起系统
/// 对话框，iOS 的 VPN 授权由 Network Extension 框架在首次
/// startVPNTunnel 时弹出，都不需要 Dart 预检。
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// 平台能力探测与权限请求。
abstract final class VelaPermissions {
  static const _channel = MethodChannel('dev.boxhub.boxhub/core');

  /// 当前平台是否支持运行代理内核。
  ///
  /// 四个桌面/移动平台均已接入：桌面走进程内 FFI，Android 走前台服务
  /// + VpnService，iOS 走 Network Extension（Packet Tunnel Provider）。
  static bool get coreSupported =>
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isAndroid ||
      Platform.isIOS;

  /// 平台不受支持时的用户可读说明（当前所有目标平台均已接入，
  /// 保留该入口以覆盖将来可能出现的未知平台）。
  static String get coreUnsupportedReason =>
      '当前平台暂不支持运行代理内核。'
      '请使用 macOS / Windows / Linux / Android / iOS 版本。';

  /// 通知权限是否已授予（Android 13+ 为运行时权限；其它平台恒为 true）。
  ///
  /// Android 13 及以上，前台服务的常驻通知需要 POST_NOTIFICATIONS 授权，
  /// 未授权时服务仍能运行，但用户看不到运行状态通知。
  static Future<bool> get notificationsGranted async {
    if (!Platform.isAndroid) return true;
    try {
      // 通道返回类型不做强类型断言：Android 侧曾经返回
      // `{granted: bool}`，而这里按 bool 解析，运行时抛
      // `_Map<Object?, Object?> is not a subtype of bool?`——错误在
      // 内核启动链路里冒出来，看起来像「启动失败」，实际只是权限查询。
      // 现在两种形状都接受，避免原生/Dart 契约再次漂移时炸整条链路。
      final res = await _channel.invokeMethod<Object?>('checkNotifications');
      if (res is bool) return res;
      if (res is Map) {
        final granted = res['granted'];
        if (granted is bool) return granted;
      }
      return true;
    } catch (_) {
      return true; // 通道异常时按已授予处理，不阻塞主流程
    }
  }

  /// 请求通知权限（Android 13+；其它平台为空操作）。
  ///
  /// 结果不阻塞内核启动——未授权只影响通知可见性。
  static Future<void> requestNotifications() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestNotifications');
    } on PlatformException {
      // 忽略：用户拒绝或系统对话框未弹出都不影响启动
    }
  }

  /// 启动内核前的统一守卫。
  ///
  /// 返回 null 表示可以启动；否则返回用户可读的阻止原因。
  /// iOS 拦截在此处完成；Android 的 VpnService 授权对话框由原生侧
  /// 在 startCore 流程内拉起，不属于本方法职责。
  static Future<String?> canStartCore() async {
    if (!coreSupported) return coreUnsupportedReason;
    if (Platform.isAndroid && !(await notificationsGranted)) {
      await requestNotifications();
    }
    return null;
  }
}
