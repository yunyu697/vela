# iOS 接入（Network Extension）

iOS 不允许普通 App 长期持有 TUN，代理内核必须跑在 **Packet Tunnel Provider**
扩展进程里。Vela 的接入形态：

```
Vela.app（Flutter UI）
   │  ① App Group 写配置 / controller 路径 / 工作目录
   │  ② NETunnelProviderManager.startVPNTunnel()
   ▼
PacketTunnel.appex（NEPacketTunnelProvider）
   │  ③ 读 App Group → 设置隧道参数（198.18.0.1/30，DNS 198.18.0.2，MTU 9000）
   │  ④ 取 utun fd → 交给 gomobile 绑定的 Go 内核
   ▼
mihomo / sing-box（Go，静态链接进 appex）
```

两端通道契约与 Android 完全一致（`dev.boxhub.boxhub/core`），Dart 侧
`createCoreBridge` 对 Android / iOS 走同一个 `MobileCoreBridge`。

## 目录与产物

| 路径 | 说明 |
|------|------|
| `cores/mobile/` | gomobile 绑定入口（双内核合并成一个包） |
| `cores/build_mobile.sh ios` | 产出 `mobile-libs/ios/Boxhubmobile.xcframework`（真机 + 模拟器切片） |
| `app/ios/Runner/CoreBridgePlugin.swift` | App 侧桥：getPaths / startCore / stopCore |
| `app/ios/PacketTunnel/` | 扩展源码、Info.plist、entitlements |
| `app/ios/add_packet_tunnel_target.rb` | 把扩展 target 接进 Flutter 生成的工程（幂等） |

## 构建

```bash
source tools/go-env.sh
go install golang.org/x/mobile/cmd/gomobile@latest

cd boxhub
./cores/build_mobile.sh ios          # 约 5–10 分钟，产物 300MB+（含调试符号）
cd app
ruby ios/add_packet_tunnel_target.rb # 首次或重建工程后执行
flutter build ios --simulator --debug   # 仅验证编译/启动
flutter build ipa --release             # 出包（需签名，见下）
```

`add_packet_tunnel_target.rb` 每次运行都会重建 target，可安全重复执行；
它做了四件手工改工程容易漏的事：

1. 把 `CoreBridgePlugin.swift` 加进 Runner 的编译阶段；
2. 新建 `PacketTunnel` app-extension target 并链上内核 XCFramework；
3. 给 Runner 加「嵌入扩展」阶段，并**排在 Thin Binary 之前**（否则 Xcode
   报 `Cycle inside Runner`）；
4. 让扩展复用 Flutter 的 xcconfig——扩展的版本号取自
   `FLUTTER_BUILD_NAME/NUMBER`，与主 App 同步，否则安装时报
   `Invalid placeholder attributes`。

## 真机运行还需要（仓库里无法代替）

1. **Apple 开发者账号**，并在两个 target 的 Signing & Capabilities 里选同一个 Team；
2. **App Group**：`group.dev.boxhub.boxhub`，Runner 与 PacketTunnel 都要勾；
3. **Network Extension**：仅 PacketTunnel 需要勾 `Packet Tunnel Provider`，
   并在描述文件里包含 `com.apple.developer.networking.networkextension`；
4. 首次启动内核时系统会弹「Vela 想要添加 VPN 配置」，用户同意后隧道才建立。

以上三项在 `app/ios/Runner/Runner.entitlements` 与
`app/ios/PacketTunnel/PacketTunnel.entitlements` 里已经声明，缺的是
**签名身份**（`DEVELOPMENT_TEAM`）与对应的描述文件。

## 已知限制 / 待验证

- **utun fd 走私有 API**：iOS SDK 没有 `sys/kern_control.h`，App 无法自己
  附着 utun 接口，`NEPacketTunnelFlow` 也不暴露 fd。当前取
  `packetFlow.socket.fileDescriptor`（业界通行做法），**App Store 审核会拒**，
  自签名/企业分发不受影响。取不到时会明确报错，不会静默连不上。
- **内存上限**：Packet Tunnel 扩展被 jetsam 限制在几十 MB 量级，而 mihomo
  默认会加载 geoip/geosite 数据库。真机上大概率需要改用 `.mrs`/`.srs`
  精简规则集并限制并发，否则扩展会被系统杀掉（表现为隧道反复重连）。
- **未做真机验证**：当前只在 iOS 模拟器上验证了「工程可编译、App 可启动」。
  模拟器不支持 Network Extension 的 VPN，隧道链路的端到端验证必须上真机。
- **DNS**：扩展内内核接管 DNS（198.18.0.2），与 Android 侧一致；
  但 iOS 的 `NEDNSSettings` 在部分系统版本上会与内核 DNS 抢答，需真机观察。
