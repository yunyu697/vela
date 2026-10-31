import Foundation
import NetworkExtension
import os.log

#if canImport(Boxhubmobile)
import Boxhubmobile
#endif

/// Packet Tunnel Provider：iOS 上真正承载代理内核的进程。
///
/// 结构：
///
///   Vela.app ──App Group(配置)──> PacketTunnel ──> Go 内核（gomobile）
///                                      │
///                                      └── utun fd ──> TUN 收发
///
/// App 进程只负责拉起/关闭隧道（见 `CoreBridgePlugin`），内核本体跑在这里：
/// iOS 不允许普通 App 长期持有 TUN，必须由 Network Extension 承载。
final class PacketTunnelProvider: NEPacketTunnelProvider {

  // MARK: - 与 App 共享的键（必须与 CoreBridgePlugin 保持一致）

  private enum Shared {
    static let appGroup = "group.dev.boxhub.boxhub"
    static let config = "coreConfig"
    static let coreKind = "coreKind"
    static let controller = "controller"
    static let secret = "secret"
    static let tun = "tun"
    static let home = "homeDir"
  }

  /// TUN 参数约定与 Android 侧保持一致（见 BoxHubVpnService 类注释），
  /// 这样 Dart 编译器产出的配置无需按平台分叉。
  private enum Tun {
    static let mihomoAddress = "198.18.0.1"
    static let mihomoDNS = "198.18.0.2"
    static let singboxAddress = "172.19.0.1"
    static let singboxDNS = "172.19.0.1"
    static let mask = "255.255.255.252"
    static let mtu = 9000
  }

  private let log = OSLog(subsystem: "dev.boxhub.boxhub", category: "PacketTunnel")
  private var core: String = "mihomo"
  private var tunFD: Int32 = -1

  // MARK: - 生命周期

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard let defaults = UserDefaults(suiteName: Shared.appGroup) else {
      completionHandler(tunnelError("App Group \(Shared.appGroup) 不可用"))
      return
    }
    guard let config = defaults.string(forKey: Shared.config), !config.isEmpty else {
      completionHandler(tunnelError("App Group 中没有待启动的配置"))
      return
    }
    core = defaults.string(forKey: Shared.coreKind) ?? "mihomo"

    let isMihomo = core != "singbox"
    let address = isMihomo ? Tun.mihomoAddress : Tun.singboxAddress
    let dns = isMihomo ? Tun.mihomoDNS : Tun.singboxDNS

    applyNetworkSettings(address: address, dns: dns) { [weak self] error in
      guard let self = self else { return }
      if let error = error {
        completionHandler(error)
        return
      }
      // 网络设置生效后系统才真正建出 utun 接口，此时 packetFlow 才有 fd
      guard let fd = self.openTunFD() else {
        completionHandler(self.tunnelError(
          "无法获取 utun 文件描述符（packetFlow 私有接口不可用）"))
        return
      }
      self.tunFD = fd
      self.startCore(config: config, fd: fd, defaults: defaults, completion: completionHandler)
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    #if canImport(Boxhubmobile)
    var error: NSError?
    let ok = core == "singbox"
      ? BoxhubmobileSingboxStop(&error)
      : BoxhubmobileMihomoStop(&error)
    if !ok {
      os_log("停止内核失败: %{public}@", log: log, type: .error,
             error?.localizedDescription ?? "未知错误")
    }
    #endif
    if tunFD >= 0 {
      close(tunFD)
      tunFD = -1
    }
    completionHandler()
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    // 供 App 侧查询内核状态（当前只需「是否在跑」）
    #if canImport(Boxhubmobile)
    let running = core == "singbox"
      ? BoxhubmobileSingboxIsRunning()
      : BoxhubmobileMihomoIsRunning()
    completionHandler?(Data([running ? 1 : 0]))
    #else
    completionHandler?(Data([0]))
    #endif
  }

  // MARK: - 隧道设置

  private func applyNetworkSettings(
    address: String,
    dns: String,
    completion: @escaping (Error?) -> Void
  ) {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: address)
    settings.mtu = NSNumber(value: Tun.mtu)

    let ipv4 = NEIPv4Settings(addresses: [address], subnetMasks: [Tun.mask])
    // 全量接管：与 Android 侧 addRoute("0.0.0.0", 0) 等价
    ipv4.includedRoutes = [NEIPv4Route.default()]
    settings.ipv4Settings = ipv4

    settings.dnsSettings = NEDNSSettings(servers: [dns])

    setTunnelNetworkSettings(settings, completionHandler: completion)
  }

  // MARK: - 启动内核

  private func startCore(
    config: String,
    fd: Int32,
    defaults: UserDefaults,
    completion: @escaping (Error?) -> Void
  ) {
    #if canImport(Boxhubmobile)
    let controller = defaults.string(forKey: Shared.controller) ?? ""
    let secret = defaults.string(forKey: Shared.secret) ?? ""
    // 工作目录由 App 侧准备（App Group 容器）：geoip.metadb 等数据在那里，
    // 扩展进程的沙盒与 App 不通，不能各用各的。
    let home = defaults.string(forKey: Shared.home) ?? ""
    let work = home.isEmpty
      ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path
      : home

    var error: NSError?
    let ok: Bool
    if core == "singbox" {
      ok = BoxhubmobileSingboxStart(config, work, controller, secret, fd, nil, &error)
    } else {
      ok = BoxhubmobileMihomoStart(config, home, controller, secret, fd, nil, &error)
    }
    if ok {
      completion(nil)
    } else {
      completion(tunnelError("内核启动失败：\(error?.localizedDescription ?? "未知错误")"))
    }
    #else
    // 没打包 Go 框架时给出明确原因，而不是让隧道静默连不上
    completion(tunnelError(
      "未链接内核框架 Boxhubmobile：请先运行 cores/build_mobile.sh ios 生成 XCFramework"))
    #endif
  }

  // MARK: - utun fd

  /// 取得系统为本次隧道建出的 utun 接口的 fd。
  ///
  /// 为什么必须绕一圈：iOS SDK 里没有 `sys/kern_control.h`（那是 macOS
  /// 才有的），App 无法自己开 utun 控制通道附着到接口；而
  /// `NEPacketTunnelFlow` 的公开 API 只有 readPackets/writePackets，
  /// 不暴露 fd，内核本体却需要直接读写原始报文。
  ///
  /// 因此这里取 `packetFlow` 内部的 socket.fileDescriptor——这是
  /// Network Extension 实现里事实上的通行做法（sing-box / Clash 系
  /// 客户端都这么干），但它属于私有 API：App Store 审核会拒，自签名
  /// 分发不受影响。取不到时返回 nil，由调用方给出明确错误，而不是让
  /// 隧道「连上了但完全不通」。
  private func openTunFD() -> Int32? {
    let socketSelector = NSSelectorFromString("socket")
    guard packetFlow.responds(to: socketSelector),
          let socket = packetFlow.value(forKey: "socket") as? NSObject else {
      os_log("packetFlow 未暴露 socket（私有 API 形态变化？）", log: log, type: .error)
      return nil
    }
    let value = socket.value(forKey: "fileDescriptor")
    if let number = value as? NSNumber, number.int32Value > 0 {
      return number.int32Value
    }
    if let fd = value as? Int32, fd > 0 {
      return fd
    }
    os_log("socket.fileDescriptor 取值失败：%{public}@", log: log, type: .error,
           String(describing: value))
    return nil
  }

  // MARK: - 错误

  private func tunnelError(_ message: String) -> NSError {
    os_log("%{public}@", log: log, type: .error, message)
    return NSError(
      domain: "dev.boxhub.boxhub.PacketTunnel",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
