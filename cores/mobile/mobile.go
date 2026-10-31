// BoxHub 移动端统一绑定包（gomobile bind 唯一入口）。
//
// 为什么必须合并：gomobile bind 的每个 aar 都自带 libgojni.so，
// 一个 Android 进程只能加载一份（System.loadLibrary("gojni") 按名字
// 加载），两个内核各自 bind 会在 mergeDebugNativeLibs 阶段直接冲突。
// 因此 mihomo 与 sing-box 的绑定统一经本包导出（Mihomo* / Singbox*
// 前缀），一次 bind 产出单个 aar。
package boxhubmobile

import (
	mihomobridge "github.com/boxhub/mihomo-bridge/mobile"
	singboxbridge "github.com/boxhub/singbox-bridge/mobile"
)

// FDProtector 由宿主（Android Kotlin）实现：把内核创建的 socket fd
// 交给 VpnService.protect()，防止出站连接被 VPN 自身再次捕获。
type FDProtector interface {
	Protect(fd int32) bool
}

// ---- mihomo ----

// MihomoStart 启动 mihomo 内核。
//   - configYAML: Dart 侧 MihomoCompiler 产出
//   - homeDir:    内核工作目录（context.filesDir）
//   - controllerUnixPath: external controller 的 unix socket 路径
//   - secret:     controller 鉴权密钥
//   - tunFd:      VpnService 的 TUN fd；<=0 表示不走 TUN
//   - protector:  socket 保护回调，可为 nil
func MihomoStart(configYAML, homeDir, controllerUnixPath, secret string, tunFd int32, protector FDProtector) error {
	var p mihomobridge.FDProtector
	if protector != nil {
		p = protectorAdapter{protector}
	}
	return mihomobridge.StartConfig(configYAML, homeDir, controllerUnixPath, secret, tunFd, p)
}

func MihomoStop() error          { return mihomobridge.StopConfig() }
func MihomoIsRunning() bool      { return mihomobridge.IsRunning() }
func MihomoLastError() string    { return mihomobridge.LastError() }

// ---- sing-box ----

// SingboxStart 启动 sing-box 内核。
//   - configJSON: Dart 侧 SingboxCompiler 产出（1.11+ 新格式）
//   - workingDir: cache 文件落地目录（context.cacheDir）
//   - controllerAddr: clash API 监听地址（127.0.0.1:<port>，强制覆写）
//   - secret:     clash API 访问密钥
//   - tunFd:      VpnService 的 TUN fd；<=0 表示不走 TUN
//   - protector:  socket 保护回调，可为 nil
func SingboxStart(configJSON, workingDir, controllerAddr, secret string, tunFd int32, protector FDProtector) error {
	var p singboxbridge.FDProtector
	if protector != nil {
		p = protectorAdapter{protector}
	}
	return singboxbridge.StartConfig(configJSON, workingDir, controllerAddr, secret, tunFd, p)
}

func SingboxStop() error       { return singboxbridge.StopConfig() }
func SingboxIsRunning() bool   { return singboxbridge.IsRunning() }
func SingboxLastError() string { return singboxbridge.LastError() }

// protectorAdapter 把统一包的 FDProtector 适配到各内核包的同名接口。
type protectorAdapter struct{ p FDProtector }

func (a protectorAdapter) Protect(fd int32) bool {
	if a.p == nil {
		return false
	}
	return a.p.Protect(fd)
}
