// BoxHub sing-box 桥接层（与 mihomo-bridge 同构的宿主侧控制面）。
//
// 与 mihomo 桥接的差异（均为 sing-box v1.14 内核事实）：
//   - 启停模型：每次 StartConfig 构造全新 box.Box 实例，StopConfig 直接
//     Close（sing-box 无 mihomo 那种"空配置热替换"语义）；
//   - clash API：v1.14 的 clashapi 仅支持 TCP 监听（server.go 硬编码
//     NetworkTCP），因此 external controller 走 127.0.0.1:<port> 并强制
//     注入 secret —— 由本层覆写配置，杜绝 controller 裸奔；
//   - 注册表：box.New 的 context 必须经 include.Context() 注入协议注册表。
//
// 构建方式：
//   桌面端:  go build -tags "with_clash_api,with_gvisor,with_quic" \
//                -buildmode=c-shared -o libboxhub_singbox.dylib ./cshared
//   移动端:  gomobile bind（库包本体 + 移动端包装）
package boxhubsingbox

import (
	"context"
	"os"
	"sync"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/service"
	"github.com/sagernet/sing/service/filemanager"
)

var (
	mu       sync.Mutex
	instance *box.Box
	running  bool

	errMu   sync.Mutex // 独立错误锁：避免 Start 持锁期间读错误死锁
	lastErr string
)

func setErr(err error) error {
	errMu.Lock()
	if err == nil {
		lastErr = ""
	} else {
		lastErr = err.Error()
	}
	errMu.Unlock()
	return err
}

// LastError 返回最近一次操作的错误信息（供 FFI 侧读取）。
func LastError() string {
	errMu.Lock()
	defer errMu.Unlock()
	return lastErr
}

// IsRunning 返回内核是否在运行。
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return running
}

// StartConfig 启动内核。
//
//   - configJSON：Dart 侧 SingboxCompiler 产出（1.11+ 新格式）
//   - workingDir：cache 文件（geoip.db 等）的落地目录
//   - controllerAddr：clash API 监听地址，必须为 127.0.0.1:<port>；
//     由本层强制覆写进配置，调用方传入的配置值会被替换
//   - secret：clash API 访问密钥，空则本层生成一个随机值（此时调用方
//     无法拿到，故建议总是显式传入）
func StartConfig(configJSON, workingDir, controllerAddr, secret string) error {
	return StartConfigWithPlatform(configJSON, workingDir, controllerAddr, secret, nil)
}

// StartConfigWithPlatform 在 StartConfig 基础上允许注入平台接口
// （移动端用它把 VpnService 的 TUN fd 交给 sing-tun；桌面端传 nil）。
func StartConfigWithPlatform(configJSON, workingDir, controllerAddr, secret string, platform adapter.PlatformInterface) error {
	mu.Lock()
	defer mu.Unlock()
	if running {
		return setErr(E.New("sing-box is already running"))
	}
	if err := startLocked(configJSON, workingDir, controllerAddr, secret, platform); err != nil {
		return setErr(err)
	}
	setErr(nil)
	return nil
}

func startLocked(configJSON, workingDir, controllerAddr, secret string, platform adapter.PlatformInterface) error {
	ctx := context.Background()
	if workingDir != "" {
		// 传入当前进程 uid/gid：WithDefault 的 chown 条件是
		// userID != os.Getuid()，传 0 会尝试 chown 到 root 而失败
		ctx = filemanager.WithDefault(ctx, workingDir, "", os.Getuid(), os.Getgid())
	}
	ctx = include.Context(ctx)
	if platform != nil {
		ctx = service.ContextWith[adapter.PlatformInterface](ctx, platform)
	}

	// 解析 1.11+ 新格式配置（与官方 cmd/sing-box 相同的入口）
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	if err != nil {
		return E.Cause(err, "decode config")
	}

	// 安全覆写 clash API：仅本机回环 + 强制 secret
	if options.Experimental == nil {
		options.Experimental = &option.ExperimentalOptions{}
	}
	if options.Experimental.ClashAPI == nil {
		options.Experimental.ClashAPI = &option.ClashAPIOptions{}
	}
	options.Experimental.ClashAPI.ExternalController = controllerAddr
	options.Experimental.ClashAPI.Secret = secret
	options.Experimental.ClashAPI.ExternalUI = "" // 不下载 yacd 等 UI 资源

	instance0, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		return E.Cause(err, "create service")
	}
	if err := instance0.Start(); err != nil {
		instance0.Close()
		return E.Cause(err, "start service")
	}
	instance = instance0
	running = true
	return nil
}

// StopConfig 停止内核（幂等）。
func StopConfig() error {
	mu.Lock()
	defer mu.Unlock()
	if !running {
		return nil
	}
	if err := instance.Close(); err != nil {
		return setErr(E.Cause(err, "close service"))
	}
	instance = nil
	running = false
	setErr(nil)
	return nil
}

// RestartConfig 换配置重启（切换内核 / 更新 Profile 时复用）。
func RestartConfig(configJSON, workingDir, controllerAddr, secret string) error {
	if err := StopConfig(); err != nil {
		return err
	}
	return StartConfig(configJSON, workingDir, controllerAddr, secret)
}
