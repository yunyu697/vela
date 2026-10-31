import Flutter
import NetworkExtension
import UIKit

/// 内核桥（iOS 版）。
///
/// 与 Android 的差异：iOS 不允许 App 进程自己跑代理内核，必须由
/// Network Extension（Packet Tunnel Provider）承载。因此本类只负责
/// **管理隧道生命周期**，真正的内核跑在 `PacketTunnel` 扩展里：
///
///   App ──(App Group 传配置)──> PacketTunnelProvider ──> Go 内核
///
/// 通道契约与 Android 保持一致（`dev.boxhub.boxhub/core`），
/// Dart 侧只需在 `createCoreBridge` 里按平台选择实现：
///   - getPaths            → {filesDir, cacheDir}
///   - startCore           → {status: "started"}（内部等到隧道 connected）
///   - stopCore            → {status: "stopped"}
///   - checkNotifications  → Bool（iOS 恒为 true，无前台服务通知）
///   - requestNotifications→ null（空操作）
final class CoreBridgePlugin: NSObject, FlutterPlugin {
  static let channelName = "dev.boxhub.boxhub/core"

  /// 与两个 target 的 entitlements 保持一致。
  static let appGroup = "group.dev.boxhub.boxhub"
  static let tunnelBundleId = "dev.boxhub.boxhub.PacketTunnel"

  /// App Group 内传递配置的键。
  static let keyConfig = "coreConfig"
  static let keyCoreKind = "coreKind"
  static let keyController = "controller"
  static let keySecret = "secret"
  static let keyTun = "tun"
  static let keyHome = "homeDir"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(CoreBridgePlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPaths":
      let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      var payload: [String: Any] = ["filesDir": docs.path, "cacheDir": caches.path]
      // App Group 容器：内核跑在扩展进程，只有这里是两个进程都能读写的
      // 目录（控制器 socket、geoip.metadb 都放在里面）
      if let group = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroup
      ) {
        payload["groupDir"] = group.path
      }
      result(payload)

    case "startCore":
      guard let args = call.arguments as? [String: Any],
            let core = args["core"] as? String,
            let config = args["config"] as? String else {
        result(FlutterError(code: "bad_args", message: "startCore 参数缺失", details: nil))
        return
      }
      startTunnel(core: core, config: config, args: args, result: result)

    case "stopCore":
      stopTunnel(result: result)

    case "checkNotifications":
      // iOS 上内核跑在扩展里，没有 Android 那种前台服务常驻通知
      result(true)

    case "requestNotifications":
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 隧道生命周期

  private func startTunnel(
    core: String,
    config: String,
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard let defaults = UserDefaults(suiteName: Self.appGroup) else {
      result(FlutterError(
        code: "app_group",
        message: "App Group \(Self.appGroup) 不可用：请检查两个 target 的 entitlements 与签名配置",
        details: nil))
      return
    }

    // 配置通过 App Group 交给扩展进程（两个进程不共享内存）
    defaults.set(config, forKey: Self.keyConfig)
    defaults.set(core, forKey: Self.keyCoreKind)
    defaults.set(args["controller"] as? String ?? "", forKey: Self.keyController)
    defaults.set(args["secret"] as? String ?? "", forKey: Self.keySecret)
    defaults.set(args["tun"] as? Bool ?? true, forKey: Self.keyTun)
    // 内核工作目录同样在 App Group 里：geoip.metadb 由 App 侧下载，
    // 扩展启动内核时要读同一份文件
    defaults.set(args["homeDir"] as? String ?? "", forKey: Self.keyHome)
    defaults.synchronize()

    loadManager { manager, error in
      if let error = error {
        result(FlutterError(code: "manager", message: error.localizedDescription, details: nil))
        return
      }
      guard let manager = manager else {
        result(FlutterError(code: "manager", message: "无法创建隧道配置", details: nil))
        return
      }

      manager.isEnabled = true
      manager.saveToPreferences { saveError in
        if let saveError = saveError {
          result(FlutterError(code: "save", message: saveError.localizedDescription, details: nil))
          return
        }
        // 重新载入一次：saveToPreferences 之后 connection 对象才是最新的
        manager.loadFromPreferences { _ in
          do {
            try manager.connection.startVPNTunnel()
          } catch {
            result(FlutterError(
              code: "start", message: error.localizedDescription, details: nil))
            return
          }
          self.awaitConnected(manager.connection, result: result)
        }
      }
    }
  }

  private func stopTunnel(result: @escaping FlutterResult) {
    loadManager { manager, error in
      if let error = error {
        result(FlutterError(code: "manager", message: error.localizedDescription, details: nil))
        return
      }
      manager?.connection.stopVPNTunnel()
      result(["status": "stopped"])
    }
  }

  private func loadManager(completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      if let error = error {
        completion(nil, error)
        return
      }
      if let existing = managers?.first(where: {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?
          .providerBundleIdentifier == Self.tunnelBundleId
      }) {
        completion(existing, nil)
        return
      }

      let manager = NETunnelProviderManager()
      let proto = NETunnelProviderProtocol()
      proto.providerBundleIdentifier = Self.tunnelBundleId
      proto.serverAddress = "Vela"
      proto.providerConfiguration = [:]
      // 配置本体走 App Group，providerConfiguration 只做标识
      manager.protocolConfiguration = proto
      manager.localizedDescription = "Vela"
      manager.isEnabled = true
      completion(manager, nil)
    }
  }

  /// 轮询隧道状态直到 connected（或超时/断开）。
  ///
  /// 为什么不用通知：NEVPNStatusDidChange 需要额外维护 observer 生命周期，
  /// 而启动路径只需要「等到就绪」这一次结果，轮询更简单也更好超时。
  private func awaitConnected(
    _ connection: NEVPNConnection,
    result: @escaping FlutterResult
  ) {
    let deadline = Date().addingTimeInterval(45)
    func poll() {
      switch connection.status {
      case .connected:
        result(["status": "started"])
      case .disconnected, .invalid:
        result(FlutterError(
          code: "tunnel_down",
          message: "隧道已断开，内核启动失败（详见扩展日志）",
          details: nil))
      default:
        if Date() > deadline {
          result(FlutterError(
            code: "timeout",
            message: "等待隧道连接超时（45s）",
            details: nil))
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: poll)
        }
      }
    }
    poll()
  }
}
