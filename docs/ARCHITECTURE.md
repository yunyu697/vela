# 架构设计

## 分层

1. **UI 层（Flutter）**：配置向导、连接仪表盘、规则编辑器、日志/诊断。
2. **应用核心层（Dart）**：统一配置 IR、双内核编译器、Lint 引擎、Profile 存储（含 Override 补丁层）。
3. **内核适配层（Dart 接口 + Go 桥接）**：`CoreAdapter` 统一启停 / 状态 / 日志 / 连接表 / 测延迟 / 切换节点。
4. **平台层（各端薄胶水）**：Android VpnService、iOS NetworkExtension、macOS NE 或特权助手、Windows wintun + 特权服务、Linux tun + systemd。

## 统一配置 IR

一切功能只读写 IR（`lib/core/ir/profile.dart`）：

```
Profile
├── coreKind          # singbox | mihomo（决定用哪个编译器）
├── source            # subscription | links | manual | file
├── nodes[]           # 节点（协议 + 服务器 + 私有参数包）
├── groups[]          # 分组（select / urlTest / fallback / loadBalance）
├── rules[]           # 规则（动作 + 规则集引用 + 自定义域名/CIDR）
├── dns               # DNS 模式（fakeIp / redirHost / plain）+ 服务器
└── inbound           # TUN / 系统代理 / 混合
```

- **切换内核**：同一 Profile 传给另一个编译器重新生成配置并平滑重启（保持入站端口不变，减少断网瞬间）。
- **原生配置模式**：高级用户直接编辑 JSON/YAML 的 Profile 跳过 IR，标注为不可跨内核切换。

## 内核接入

- **sing-box**：使用官方 `libbox` 高层 API（Go → gomobile/gobind 编译为 Android AAR / iOS xcframework；桌面端 cgo 共享库）。见 `cores/singbox-bridge/`。
- **mihomo**：fork 内核编译为库，external controller 走 **unix socket / 命名管道**（不暴露 TCP 端口），由宿主进程代理给 UI。见 `cores/mihomo-bridge/`。

## 规则集

内置规则集以 MetaCubeX/meta-rules-dat 为源，注册表（`lib/core/ir/rule_set_registry.dart`）里每一条同时声明：
- sing-box 远程 `.srs`（二进制 rule-set，iOS NetworkExtension 内存受限场景友好）
- mihomo `rule-providers` 的 `.mrs`（behavior + format）

用户在向导里只点「国内直连 / 去广告 / 流媒体 / AI 服务」等卡片，编译器自动展开为对应格式。注册表支持远程清单刷新，不随 App 发版更新。

## Lint 引擎

所有告警分三级：**error（阻断生成）→ warning（红色提示 + 一键修复）→ info（灰字建议）**。

已实现的检查包括：
- 兼容性矩阵：节点协议在所选内核上不受支持（如 sing-box 不支持 SSR）→ error
- fake-ip 模式但过滤器为空 → warning（本地服务 / NAS 异常）
- TUN 模式未配置 DNS 劫持 → warning（DNS 泄露）
- 外国 DNS 优先且未按规则分流 → warning（解析变慢 / 泄露）
- 无兜底（MATCH/final）规则 → error
- 规则引用了未知的规则集 id → error

## Override 补丁层

`ProfileStore` 把 **base（订阅快照或向导产物）** 与 **UserPatch（用户修改：规则开关、自定义规则、DNS 调整、分组选择）** 分开持久化。订阅更新 = 仅替换 base 后重新 apply patch，用户定制永不丢失。

## 安全

- external controller 仅监听 unix socket / 命名管道。
- 订阅与节点凭据本地加密存储（移动端接 Keychain / Keystore），支持应用锁。
- iOS 需注意 NetworkExtension 内存上限：使用 .srs 压缩格式、限制规则条数、延迟加载。
