# 路线图

## M0 — 品牌与设计系统（本轮完成）
- [x] 改名 **Vela**（船帆座）：窗口标题、应用名、图标、UI 文案、文档全部统一
- [x] 双翼帆形应用图标（贝塞尔几何 + 靛蓝紫渐变），产出 macOS `.icns` / Android 5 密度 / Flutter 资源全套
- [x] 设计令牌体系：`tokens.dart`（间距 / 圆角 / 动效 / 缓动 / 断点）+ 亮暗双模 `ColorScheme`
- [x] 响应式框架：`AdaptiveBuilder` / `AdaptiveScope` / `AdaptiveScaffold`（侧栏 ↔ 图标栏 ↔ 底部栏）
- [x] 横竖屏自动识别（按内容区宽高比）+ 页面转场与逐项入场动画
- [x] 三页重构：概览 / 配置 / 运行 + 七步向导重做
- [x] 跨平台最小安全尺寸 880×600（macOS `NSWindow.minSize` / Windows `WM_GETMINMAXINFO` / Linux `GDK_HINT_MIN_SIZE`）
- [x] 响应式布局回归测试：6 种尺寸 × 4 页面 × 向导 7 步 + 13 张黄金图

## M1 — 单内核可跑通
- [x] Flutter 骨架 + 向导 UI 完整走通（订阅导入 → 分组 → 规则卡片 → DNS 预设 → 生成）
- [x] mihomo 内核经 Go 桥接嵌入，桌面端 + Android 端到端可连
- [x] 内置规则集 12 条（国内直连、去广告、流媒体、AI、Telegram、游戏等）
- [x] DNS 三预设 + Lint 引擎 DNS 告警
- [x] TUN / 系统代理切换，连接仪表盘（流量 + 连接表）

## M2 — 双内核 + 全平台
- [x] sing-box 经 libbox 嵌入，IR 双编译器完整对齐
- [x] 运行时切换内核（保持入站端口平滑重启）
- [ ] 兼容性矩阵检查全量启用（不支持的节点自动标红剔除）
- [ ] iOS 真机验证（NetworkExtension 骨架已接入，见 docs/ios.md；模拟器不支持 VPN，待真机 + 签名）/ macOS / Linux 适配
- [x] Android gomobile 绑定 + VpnService（fd 注入 + protect 防回环 + 前台服务通知）
- [x] iOS 工程骨架：PacketTunnel 扩展 target、App Group 共享、gomobile XCFramework
- [ ] 订阅自动更新 + subscription-userinfo 流量信息解析

## M3 — 高级能力
- [ ] Override 补丁层编辑 UI（规则编辑器、分组编辑器）
- [ ] 规则测试器（输入域名/IP 显示命中规则链）
- [ ] 一键诊断包（内核日志 + Lint 结果 + 权限状态）
- [ ] Windows/macOS 特权服务（免管理员运行 TUN）、Android 按应用分流
- [ ] 本地加密存储 + 应用锁 + i18n
- [x] 暗色主题打磨 + 主题模式切换（跟随系统 / 亮 / 暗，持久化）
