import Cocoa
import FlutterMacOS

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

    super.awakeFromNib()
  }
}
