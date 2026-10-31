// BoxHub mihomo 桥接层。
//
// 接入方式：以库形式加载 mihomo 内核（github.com/metacubex/mihomo），
// external controller 仅监听 unix socket / 命名管道（由 Dart 侧
// MihomoAdapter 通过 HTTP-over-unix-socket 访问 clash API）。
//
// 构建方式：
//
//	Android/iOS:  gomobile bind（同 singbox-bridge）
//	桌面端:       go build -buildmode=c-shared
package boxhubmihomo

import (
	"fmt"
	"sync"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
)

var (
	mu      sync.Mutex
	running bool
	errMu   sync.Mutex // 与 mu 分离：StartConfig/StopConfig 持 mu 期间会写 lastErr
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

// StartConfig 启动内核。
//   - configYAML: Dart 侧 MihomoCompiler 的产出
//   - homeDir:    内核工作目录（缓存 / geodata / providers 存放处）
//   - controllerUnixPath: external controller 的 unix socket 路径（覆盖配置）
//   - secret:     controller 鉴权密钥（可为空）
func StartConfig(configYAML, homeDir, controllerUnixPath, secret string) error {
	mu.Lock()
	defer mu.Unlock()
	if running {
		return fmt.Errorf("mihomo core already running")
	}
	if homeDir != "" {
		constant.SetHomeDir(homeDir)
	}
	var opts []hub.Option
	if controllerUnixPath != "" {
		opts = append(opts, hub.WithExternalControllerUnix(controllerUnixPath))
	}
	if secret != "" {
		opts = append(opts, hub.WithSecret(secret))
	}
	// hub.Parse = 解析配置 + 启动 external controller(route) + 应用配置
	// （启动入站监听 / DNS / TUN / 规则 / providers）
	if err := hub.Parse([]byte(configYAML), opts...); err != nil {
		return setErr(fmt.Errorf("start mihomo: %w", err))
	}
	running = true
	return setErr(nil)
}

// stopConfigYAML 用于停机：应用一份「无入站 / 无 TUN / 无控制器」的
// 最小配置，mihomo 会按新配置关闭旧监听（包括 TUN 与 DNS）。
const stopConfigYAML = `
mode: rule
log-level: silent
mixed-port: 0
port: 0
socks-port: 0
external-controller: ""
external-controller-unix: ""
tun:
  enable: false
dns:
  enable: false
`

// StopConfig 停止内核。
func StopConfig() error {
	mu.Lock()
	defer mu.Unlock()
	if !running {
		return nil
	}
	cfg, err := executor.ParseWithBytes([]byte(stopConfigYAML))
	if err != nil {
		return setErr(fmt.Errorf("parse stop config: %w", err))
	}
	hub.ApplyConfig(cfg)
	running = false
	return setErr(nil)
}

// RestartConfig 重启（换配置时复用）。
func RestartConfig(configYAML, homeDir, controllerUnixPath, secret string) error {
	if err := StopConfig(); err != nil {
		return err
	}
	if err := StartConfig(configYAML, homeDir, controllerUnixPath, secret); err != nil {
		return err
	}
	return nil
}

// IsRunning 返回运行状态。
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return running
}
