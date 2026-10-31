# Vela

跨平台 sing-box / mihomo 客户端（桌面端 + 移动端），以「配置向导」为核心，让普通用户不接触底层配置文件即可完成订阅、分流规则与 DNS 的全部设置。

> 名称取自**船帆座（Vela）**——扬帆的意象既贴合代理「突破网络边界」的定位，双翼帆形图标也呼应「双内核合流」的产品主线。现有同类客户端（Clash / Clash Verge / Nyanpasu / Mihomo Party / FlClash / Karing / Hiddify / GUI.for.SingBox / Sparkle / Egern）均未占用该名。

## 核心理念

- **统一配置 IR**：所有功能（向导、规则编辑器、订阅解析）只操作一套内部模型；切换内核 = 换编译器，Profile 本身不变。
- **双内核编译器**：`IR → sing-box JSON`（1.11+ rule-set 格式）与 `IR → mihomo YAML`（rule-providers mrs 格式）。
- **Lint 检查引擎**：DNS 危险组合告警、内核兼容性矩阵检查，错误阻断生成、警告一键修复。
- **Override 补丁层**：订阅原始数据与用户修改分离存储，订阅更新不会覆盖用户的定制。

## 界面设计

- **设计系统**：`app/lib/ui/`
  - `tokens.dart` —— 间距（`Insets`）、圆角（`Radii`）、动效时长（`Motion`）、断点（`Breakpoints`）的唯一来源，所有页面只引用常量，保证跨页面对齐一致。
  - `vela_theme.dart` —— 靛蓝紫主色（`#4F46E5`）+ 紫罗兰 / 天青 / 琥珀 / 翠绿 / 玫红功能色，亮暗双模，含全套 Material 3 组件主题；`buildVelaTheme(fontFamily:)` 可统一指定全局字体族（按钮 / 输入框等组件自带 textStyle 也会跟随）。
  - `adaptive.dart` —— 响应式基础设施：断点判定、横竖屏识别、`AdaptiveScaffold`（宽屏侧栏 ↔ 中屏图标栏 ↔ 窄屏底部栏）、`VelaPageTransition`（淡入位移转场）、`StaggeredEntrance`（逐项入场）、`VelaBackdrop`（渐变光斑背景）。
  - `widgets.dart` —— 共享组件：`VelaCard`、`StatTile`、`StatusPill`、`ChoiceCard`、`VelaGradientButton`、`EmptyState`、`InfoRow` 等。
- **响应式布局**：
  - 概览页 —— 品牌主视觉 + 状态概览 + 快捷入口 + 能力网格（1/2/4 列自适应）。
  - 向导页 —— 宽屏「步骤栏 + 内容 + Lint 侧栏」三栏，中屏两栏，窄屏「横向步骤条 + 内容」单栏；步骤切换带淡入位移动画。
  - 运行页 —— 宽屏「控制台 + 实时仪表盘」左右双栏，窄屏上下堆叠；统计磁贴按可用宽度自动 1/2/4 列。
- **最小安全尺寸**：窗口小于 880×600 时界面元素会被挤压或截断，故在平台层禁止继续缩小——
  - macOS：`MainFlutterWindow.swift` 设置 `NSWindow.contentMinSize`（约束**内容区**；用 `minSize` 会把标题栏算进去，内容仍可被压到 880×572）
  - Windows：`win32_window.cpp` 处理 `WM_GETMINMAXINFO` 设置 `ptMinTrackSize`，并用 `AdjustWindowRectEx` 把边框标题栏补回去（该值约束的是**外框**）
  - Linux：`my_application.cc` 通过 `gtk_window_set_geometry_hints` 设置 `GDK_HINT_MIN_SIZE`，CSD 标题栏额外预留 48px
  - 三处数值与 Dart 侧 `Breakpoints.minWindowWidth / minWindowHeight` 保持一致。
- **图标**：`tools/make_icon.py` 生成「双翼帆形」图标（4× 超采样渲染 → LANCZOS 缩放 + 渐变噪点防色带），产出 macOS `.iconset` / `.icns`、Android 各密度 `mipmap`（含自适应图标前景层）、Flutter `assets/icon/`。改设计只需编辑脚本后重跑。

## 目录结构

```
vela/
├── docs/
│   ├── ARCHITECTURE.md      # 架构设计
│   └── ROADMAP.md           # 里程碑规划
├── tools/
│   └── make_icon.py         # 图标生成器（PIL 矢量绘制）
├── app/                     # Flutter 应用（单一代码库覆盖全平台）
│   ├── pubspec.yaml
│   ├── lib/
│   │   ├── main.dart
│   │   ├── core/
│   │   │   ├── ir/              # 统一配置 IR + 内置规则集注册表
│   │   │   ├── compiler/        # 双内核编译器（含轻量 YAML emitter）
│   │   │   ├── lint/            # Lint 检查引擎
│   │   │   ├── cores/           # CoreAdapter 抽象 + 各内核适配器
│   │   │   └── storage/         # Profile 持久化 + Override 补丁层
│   │   ├── ui/                  # 设计系统 + 响应式框架
│   │   └── features/
│   │       ├── home/            # 概览
│   │       ├── profiles/        # 配置管理
│   │       ├── run/             # 运行面板
│   │       └── wizard/          # 配置向导（状态机 + 页面）
│   └── test/
└── cores/                   # Go 桥接层（编译为移动端库 / 桌面端 cgo）
    ├── singbox-bridge/      # 基于 libbox 封装 sing-box
    ├── mihomo-bridge/       # 基于 mihomo hub 封装 + unix socket controller
    └── mobile/              # gomobile 统一绑定包（双内核合并为一个 aar）
```

> 说明：Go 模块路径（`github.com/boxhub/...`）、Java 包名（`com.boxhub`）、dylib 文件名（`libboxhub_*`）、bundle id（`dev.boxhub.boxhub`）、Android 存储 key（`boxhub.profiles`）等**内部标识保持不变**——它们已被已构建产物、Android 签名与 FFI 查找逻辑引用，改动会导致既有安装包失效。用户可见的名称（窗口标题、应用名、图标、可执行文件名、UI 文案、文档）全部为 Vela。

## 状态

**桌面端端到端已打通**（macOS arm64 主机验证）：
- `flutter analyze` 0 问题、`flutter test` **72/72 通过**（25 项单元 / 端到端测试 + 47 项响应式布局回归：6 种尺寸 × 4 页面 × 向导 7 步，含 13 张黄金图）
- IR / 双编译器 / Lint / Override 补丁层 / 订阅解析（7 协议 + 3 种订阅格式）全部就绪
- **mihomo Go 桥接 + Dart FFI 绑定**：`cores/mihomo-bridge/build_desktop.sh` 构建 dylib（`desktop-libs/<os>-<arch>/`），错误经 `LastError` 回传
- **Clash API 客户端**：纯 Dart 实现的 HTTP/1.1 over unix socket / TCP+secret（version / connections / 切换节点 / 测延迟）
- **界面已全面重构**：概览 / 配置管理 / 运行三模块 + 七步向导，配色、动效、响应式布局与最小窗口尺寸限制全部落地
  - 布局回归测试 `app/test/layout_test.dart`：注入样例配置后覆盖 6 种窗口尺寸（390×844 / 844×390 / 834×1112 / 1280×800 / 1680×1050 / 880×600）× 4 个页面 + 向导 7 步逐步切换，逐帧断言无溢出 / 错位 / 遮挡，并产出黄金图供人工核对
  - 注意：widget 测试跑在 fake-async 时钟里，页面读取本地配置的真实 IO 不会自动完成，必须用 `runAsync` 与带时长的 `pump()` 交替推进（见测试内 `_settleAsyncIO`）
- **sing-box 桥接已落地**（v1.14.4 内核，c-shared dylib，TCP clash API + 强制 secret），
  运行页可热切换内核：同一 Profile 自动换编译器换配置重启（e2e 测试覆盖 mihomo↔sing-box 往返）
- **Android 已接线**（gomobile aar + VpnService）：
  - `cores/build_mobile.sh` 产出统一 `mobile-libs/android/boxhub-mobile.aar`（双内核合并为一个绑定包，否则同名 `libgojni.so` 会冲突），gradle 接入
  - `BoxHubVpnService` 建立 TUN 后把 fd 交给内核（mihomo 走 `tun.file-descriptor`；sing-box 走自定义 `adapter.PlatformInterface`），出站 socket 经 `VpnService.protect` 防回环（mihomo = `DefaultSocketHook`，sing-box = `AutoDetectInterfaceControl`）
  - Dart 侧 `CoreBridge` 抽象统一桌面 FFI 与 Android MethodChannel 两条通道，`CoreAdapter` 无感切换
- Windows/Linux：平台壳已生成，桥接库构建脚本跨平台可用，在对应平台执行 `cores/build_all.sh desktop` 即可（本机 macOS 无法交叉验证）
- iOS（NetworkExtension）与桌面 TUN 特权服务在 M2/M3

## 开发

```bash
cd app
flutter pub get
flutter test        # 运行 IR / 编译器 / Lint 单元测试
flutter run -d macos
```

Go 桥接层构建见 `cores/*/` 内注释；全平台构建编排见 `cores/build_all.sh`
（desktop = 桥接库 + macOS bundle；android = aar + 签名 apk）。
图标重生成：`python3 tools/make_icon.py`
Android 发布签名：`app/android/key.properties` + `keystores/boxhub-release.jks`
（首次生成，密码在 key.properties 中，均不入库）。
