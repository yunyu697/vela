// BoxHub mihomo 移动端绑定（gomobile bind 入口包）。
//
// 与桌面 FFI 桥的差异：gobind 要求可绑定包使用基本类型签名，
// 且移动端 TUN 不由内核创建 —— Android VpnService 创建 TUN 后把
// fd 传进来，本包在启动前把 fd 注入 YAML 的 tun.file-descriptor，
// 并关闭 auto-route（Android 的路由由 VpnService.Builder 管理）。
//
// 回环防护：内核出站 socket 必须经 VpnService.protect() 绕过 VPN
// 接口，否则出站连接会被自身 TUN 再次捕获。mihomo 的钩子是
// dialer.DefaultSocketHook（与官方 Android 客户端 CMFA 同款），
// 本包把它接到 FDProtector 回调上。
package mihomobridge

import (
	"fmt"
	"syscall"

	boxhubmihomo "github.com/boxhub/mihomo-bridge"
	"github.com/metacubex/mihomo/component/dialer"

	"go.yaml.in/yaml/v3"
)

// FDProtector 由宿主（Android Kotlin）实现：把内核创建的 socket fd
// 交给 VpnService.protect()。返回 false 表示保护失败。
type FDProtector interface {
	Protect(fd int32) bool
}

// StartConfig 启动内核（mobile 版）。
//
//   - configYAML: Dart 侧 MihomoCompiler 的产出
//   - homeDir:    内核工作目录（Android 上来自 context.filesDir）
//   - controllerUnixPath: external controller 的 unix socket 路径
//   - secret:     controller 鉴权密钥（可为空）
//   - tunFd:      VpnService 的 TUN fd；<=0 表示不走 TUN
//   - protector:  socket 保护回调，可为 nil（非 VPN 模式）
func StartConfig(configYAML, homeDir, controllerUnixPath, secret string, tunFd int32, protector FDProtector) error {
	if protector != nil {
		dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
			var ferr error
			if err := conn.Control(func(fd uintptr) {
				if !protector.Protect(int32(fd)) {
					ferr = fmt.Errorf("protect fd %d failed", fd)
				}
			}); err != nil {
				return err
			}
			return ferr
		}
	}
	patched, err := applyTunFD(configYAML, tunFd)
	if err != nil {
		return fmt.Errorf("patch tun fd: %w", err)
	}
	return boxhubmihomo.StartConfig(patched, homeDir, controllerUnixPath, secret)
}

// applyTunFD 当 tunFd > 0 时注入 Android TUN 配置。
//
// Android 约定（与 Kotlin VpnService.Builder 保持一致）：
//   - 地址 198.18.0.1/30，MTU 9000，DNS 服务器 198.18.0.2
//   - auto-route / auto-detect-interface 必须关闭（路由由 VPN 服务管理）
//   - stack 用 gvisor（不依赖系统 tun 设备节点管理）
func applyTunFD(configYAML string, tunFd int32) (string, error) {
	if tunFd <= 0 {
		return configYAML, nil
	}
	var cfg map[string]interface{}
	if err := yaml.Unmarshal([]byte(configYAML), &cfg); err != nil {
		return "", fmt.Errorf("decode yaml: %w", err)
	}
	if cfg == nil {
		cfg = map[string]interface{}{}
	}
	cfg["tun"] = map[string]interface{}{
		"enable":                true,
		"device":                "",
		"stack":                 "gvisor",
		"mtu":                   9000,
		"file-descriptor":       int(tunFd),
		"auto-route":            false,
		"auto-detect-interface": false,
		"inet4-address":         []interface{}{"198.18.0.1/30"},
		"dns-hijack":            []interface{}{"any:53"},
	}
	out, err := yaml.Marshal(cfg)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// StopConfig 停止内核。
func StopConfig() error {
	return boxhubmihomo.StopConfig()
}

// LastError 返回最近一次操作的错误信息。
func LastError() string {
	return boxhubmihomo.LastError()
}

// IsRunning 返回内核是否在运行。
func IsRunning() bool {
	return boxhubmihomo.IsRunning()
}
