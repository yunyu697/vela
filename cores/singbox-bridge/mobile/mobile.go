// BoxHub sing-box 移动端绑定（gomobile bind 入口包）。
//
// Android TUN 方案：VpnService 创建 TUN 后把 fd 传进来；本包注册一个
// 最小化的 adapter.PlatformInterface，其 OpenInterface 在内核要打开
// TUN 设备时把 fd 塞进 sing-tun 的 Options（跳过设备创建，直接用
// VpnService 的 fd）。其余方法全部返回"不使用平台能力"的桩实现，
// 行为与纯 Linux 内核一致。
package singboxbridge

import (
	"context"
	"encoding/json"
	"fmt"
	"net/netip"

	boxhubsingbox "github.com/boxhub/singbox-bridge"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/logger"
)

// StartConfig 启动内核（mobile 版）。
//
//   - configJSON: Dart 侧 SingboxCompiler 的产出（1.11+ 新格式）
//   - workingDir: cache 文件落地目录（Android 上来自 context.cacheDir）
//   - controllerAddr: clash API 监听地址（127.0.0.1:<port>，强制覆写）
//   - secret:     clash API 访问密钥
//   - tunFd:      VpnService 的 TUN fd；<=0 表示不走 TUN
//   - protector:  socket 保护回调（Kotlin 侧实现 VpnService.protect），
//     防止内核出站连接被 VPN 自身再次捕获形成回环；可为 nil
func StartConfig(configJSON, workingDir, controllerAddr, secret string, tunFd int32, protector FDProtector) error {
	patched, err := patchAndroidTun(configJSON, tunFd)
	if err != nil {
		return fmt.Errorf("patch android tun: %w", err)
	}
	var platform adapter.PlatformInterface
	if tunFd > 0 {
		platform = &fdPlatform{fd: tunFd, protector: protector}
	}
	return boxhubsingbox.StartConfigWithPlatform(patched, workingDir, controllerAddr, secret, platform)
}

// FDProtector 由宿主（Android Kotlin）实现：把内核创建的 socket fd
// 交给 VpnService.protect()，使其绕过 VPN 接口直连底层网络。
// 返回 false 表示保护失败。
type FDProtector interface {
	Protect(fd int32) bool
}

// patchAndroidTun 当 tunFd > 0 时：
//   - tun.auto_route / strict_route 关闭（路由由 VpnService 管理）
//   - route.auto_detect_interface 保持开启 —— 这不是"自动探测物理网卡"，
//     而是让 sing-box 走 PlatformInterface.AutoDetectInterfaceControl
//     通道（即 FDProtector.Protect → VpnService.protect）
func patchAndroidTun(configJSON string, tunFd int32) (string, error) {
	if tunFd <= 0 {
		return configJSON, nil
	}
	var cfg map[string]interface{}
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return "", fmt.Errorf("decode json: %w", err)
	}
	inbounds, _ := cfg["inbounds"].([]interface{})
	for _, raw := range inbounds {
		inb, ok := raw.(map[string]interface{})
		if !ok || inb["type"] != "tun" {
			continue
		}
		inb["auto_route"] = false
		inb["strict_route"] = false
	}
	route, _ := cfg["route"].(map[string]interface{})
	if route != nil {
		route["auto_detect_interface"] = true
	}
	out, err := json.Marshal(cfg)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// fdPlatform 实现 adapter.PlatformInterface：把 VpnService 的 fd 交给
// sing-tun，并把出站 socket 的保护请求转给 FDProtector。
type fdPlatform struct {
	fd        int32
	protector FDProtector
}

func (p *fdPlatform) Initialize(networkManager adapter.NetworkManager) error { return nil }
func (p *fdPlatform) UsePlatformAutoDetectInterfaceControl() bool {
	return p.protector != nil
}
func (p *fdPlatform) AutoDetectInterfaceControl(fd int) error {
	if p.protector == nil {
		return nil
	}
	if !p.protector.Protect(int32(fd)) {
		return fmt.Errorf("protect fd %d failed", fd)
	}
	return nil
}
func (p *fdPlatform) UsePlatformInterface() bool                             { return true }
func (p *fdPlatform) ProcessPlatformOptions(options option.TunPlatformOptions) error {
	return nil
}

func (p *fdPlatform) OpenInterface(options *tun.Options, platformOptions option.TunPlatformOptions) (tun.Tun, error) {
	options.FileDescriptor = int(p.fd)
	if options.Name == "" {
		options.Name = "tun0"
	}
	return tun.New(*options)
}

func (p *fdPlatform) UsePlatformDefaultInterfaceMonitor() bool { return false }
func (p *fdPlatform) CreateDefaultInterfaceMonitor(logger logger.Logger) tun.DefaultInterfaceMonitor {
	return nil
}
func (p *fdPlatform) UsePlatformNetworkInterfaces() bool { return false }
func (p *fdPlatform) NetworkInterfaces() ([]adapter.NetworkInterface, error) {
	return nil, nil
}
func (p *fdPlatform) UnderNetworkExtension() bool              { return false }
func (p *fdPlatform) NetworkExtensionIncludeAllNetworks() bool { return false }
func (p *fdPlatform) ClearDNSCache()                           {}
func (p *fdPlatform) RequestPermissionForWIFIState() error     { return nil }
func (p *fdPlatform) ReadWIFIState(ctx context.Context) adapter.WIFIState {
	return adapter.WIFIState{}
}
func (p *fdPlatform) UsePlatformConnectionOwnerFinder() bool { return false }
func (p *fdPlatform) FindConnectionOwner(request *adapter.FindConnectionOwnerRequest) (*adapter.ConnectionOwner, error) {
	return nil, nil
}
func (p *fdPlatform) UsePlatformWIFIMonitor() bool                              { return false }
func (p *fdPlatform) UsePlatformNotification() bool                             { return false }
func (p *fdPlatform) SendNotification(notification *adapter.Notification) error { return nil }
func (p *fdPlatform) CancelNotification(identifier string, typeID int32) error  { return nil }
func (p *fdPlatform) MyInterfaceAddress() []netip.Addr                          { return nil }
func (p *fdPlatform) UsePlatformNeighborResolver() bool                         { return false }
func (p *fdPlatform) StartNeighborMonitor(listener adapter.NeighborUpdateListener) error {
	return nil
}
func (p *fdPlatform) CloseNeighborMonitor(listener adapter.NeighborUpdateListener) error {
	return nil
}
func (p *fdPlatform) UsePlatformShell() bool    { return false }
func (p *fdPlatform) CheckPlatformShell() error { return nil }
func (p *fdPlatform) OpenShellSession(user *adapter.PlatformUser, command string, env []string, term string, rows int32, cols int32) (adapter.ShellSession, error) {
	return nil, nil
}
func (p *fdPlatform) LookupUser(username string) (*adapter.PlatformUser, error) { return nil, nil }
func (p *fdPlatform) LookupSFTPServer() (string, error)                         { return "", nil }
func (p *fdPlatform) ReadSystemSSHHostKey() ([]byte, error)                     { return nil, nil }
func (p *fdPlatform) TailscaleHostname() string                                 { return "" }
func (p *fdPlatform) UsePlatformBridge() bool                                   { return false }
func (p *fdPlatform) CreateBridge(options adapter.BridgeOptions) (adapter.BridgeSession, error) {
	return nil, nil
}

// StopConfig 停止内核。
func StopConfig() error {
	return boxhubsingbox.StopConfig()
}

// LastError 返回最近一次操作的错误信息。
func LastError() string {
	return boxhubsingbox.LastError()
}

// IsRunning 返回内核是否在运行。
func IsRunning() bool {
	return boxhubsingbox.IsRunning()
}
