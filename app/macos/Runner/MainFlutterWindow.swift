import Cocoa
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  /// 最小安全尺寸（逻辑像素）。
  ///
  /// 低于此宽度/高度时界面元素（按钮、统计磁贴、连接表）会被挤压或
  /// 截断，因此禁止窗口缩到更小。与 Dart 侧
  /// `Breakpoints.minWindowWidth / minWindowHeight` 保持一致。
  private static let minContentWidth: CGFloat = 880
  private static let minContentHeight: CGFloat = 600

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 限制最小尺寸，用户拖拽时无法缩到内容显示不全的状态。
    //
    // 用 contentMinSize 而非 minSize：minSize 约束的是**窗口外框**
    // （含标题栏），用户仍能把内容区压到 880×572，低于安全高度。
    // contentMinSize 直接约束内容区，与 Dart 侧
    // Breakpoints.minWindowWidth / minWindowHeight 严格一致。
    self.contentMinSize = NSSize(
      width: MainFlutterWindow.minContentWidth,
      height: MainFlutterWindow.minContentHeight
    )

    // 保证初始窗口不小于最小尺寸。
    let content = self.contentView?.frame.size ?? windowFrame.size
    self.setContentSize(NSSize(
      width: max(content.width, MainFlutterWindow.minContentWidth),
      height: max(content.height, MainFlutterWindow.minContentHeight)
    ))
    self.center()

    // 第一方原生能力：托盘 + 开机自启（零第三方插件，见 SystemChannels）
    SystemChannels.shared.register(
      messenger: flutterViewController.engine.binaryMessenger, window: self)

    super.awakeFromNib()
  }
}

/// 应用托管的原生能力（第一方代码，不引入第三方插件，保持零原生插件
/// 依赖的构建链路）：
///
/// 通道 `dev.boxhub.boxhub/system`：
///   - setTray {items: [{id, title, checked, enabled}], tooltip}
///                 → 重建菜单栏图标与菜单（macOS 托盘）
///   - setAutostart {enabled: Bool} → SMAppService 开机自启开关
///   - getAutostart → Bool
///
/// 回调（原生 → Dart）：
///   - onTrayAction {id: String}   用户点击了菜单项
class SystemChannels: NSObject {
  static let shared = SystemChannels()
  static let channelName = "dev.boxhub.boxhub/system"

  private var trayItems: [[String: Any]] = []
  private var trayTooltip = ""
  private var statusItem: NSStatusItem?
  private weak var channel: FlutterMethodChannel?
  private weak var mainWindow: NSWindow?

  func register(messenger: FlutterBinaryMessenger, window: NSWindow?) {
    mainWindow = window
    let channel = FlutterMethodChannel(name: SystemChannels.channelName,
                                       binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "setTray":
        let args = call.arguments as? [String: Any] ?? [:]
        self.trayItems = args["items"] as? [[String: Any]] ?? []
        self.trayTooltip = args["tooltip"] as? String ?? "Vela"
        self.rebuildTray()
        result(nil)
      case "setAutostart":
        let args = call.arguments as? [String: Any] ?? [:]
        result(self.setAutostart(enabled: (args["enabled"] as? Bool) == true))
      case "getAutostart":
        if #available(macOS 13.0, *) {
          result(SMAppService.mainApp.status == .enabled)
        } else {
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // ------------------------------------------------------------- 托盘

  private func rebuildTray() {
    if statusItem == nil {
      statusItem = NSStatusBar.system.statusItem(withLength: 22)
      statusItem?.button?.image = NSImage(named: "TrayIcon")
      statusItem?.button?.image?.isTemplate = true
    }
    let menu = NSMenu()
    for (idx, item) in trayItems.enumerated() {
      let id = item["id"] as? String ?? ""
      let title = item["title"] as? String ?? ""
      if id == "---" {
        menu.addItem(NSMenuItem.separator())
        continue
      }
      let mi = NSMenuItem(title: title, action: #selector(trayAction(_:)),
                          keyEquivalent: "")
      mi.target = self
      mi.tag = idx
      mi.isEnabled = item["enabled"] as? Bool ?? true
      if (item["checked"] as? Bool) == true { mi.state = .on }
      menu.addItem(mi)
    }
    statusItem?.menu = menu
    statusItem?.button?.toolTip = trayTooltip
  }

  @objc private func trayAction(_ sender: NSMenuItem) {
    let idx = sender.tag
    guard idx >= 0 && idx < trayItems.count,
          let id = trayItems[idx]["id"] as? String else { return }
    if id == "show" {
      NSApp.activate(ignoringOtherApps: true)
      mainWindow?.makeKeyAndOrderFront(nil)
    }
    channel?.invokeMethod("onTrayAction", arguments: ["id": id])
  }

  // --------------------------------------------------------- 开机自启

  private func setAutostart(enabled: Bool) -> Bool {
    guard #available(macOS 13.0, *) else { return false }
    do {
      if enabled {
        if SMAppService.mainApp.status != .enabled {
          try SMAppService.mainApp.register()
        }
      } else {
        if SMAppService.mainApp.status == .enabled {
          try SMAppService.mainApp.unregister()
        }
      }
      return true
    } catch {
      return false
    }
  }
}
