import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // CoreBridgePlugin 是本工程内的 Swift 文件，不在插件注册表里，
    // 需要手动挂上（与 GeneratedPluginRegistrant 同样的 registrar）
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CoreBridgePlugin") {
      CoreBridgePlugin.register(with: registrar)
    }
  }
}
