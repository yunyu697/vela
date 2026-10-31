// 桌面端 cgo 动态库包装（macOS dylib / Windows dll / Linux so）。
// 构建：go build -buildmode=c-shared -o libboxhub_mihomo.dylib ./cshared
// 移动端请直接 gomobile bind 库包（上级目录），勿用本包装。
//
// 错误约定：所有导出函数返回 0 成功 / -1 失败；失败后调用方可用
// LastError 取最近一次的错误文本。
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	boxhubmihomo "github.com/boxhub/mihomo-bridge"
)

func cString(s *C.char) string { return C.GoString(s) }

func try(err error) C.int {
	if err != nil {
		return -1
	}
	return 0
}

//export StartConfig
func StartConfig(configYAML, homeDir, controllerUnixPath, secret *C.char) C.int {
	return try(boxhubmihomo.StartConfig(
		cString(configYAML), cString(homeDir),
		cString(controllerUnixPath), cString(secret),
	))
}

//export StopConfig
func StopConfig() C.int {
	return try(boxhubmihomo.StopConfig())
}

//export RestartConfig
func RestartConfig(configYAML, homeDir, controllerUnixPath, secret *C.char) C.int {
	return try(boxhubmihomo.RestartConfig(
		cString(configYAML), cString(homeDir),
		cString(controllerUnixPath), cString(secret),
	))
}

//export IsRunning
func IsRunning() C.int {
	if boxhubmihomo.IsRunning() {
		return 1
	}
	return 0
}

//export LastError
func LastError() *C.char {
	return C.CString(boxhubmihomo.LastError())
}

// 释放由 Go 分配给调用方的字符串时使用（LastError 的返回值等）。
//
//export FreeCString
func FreeCString(s *C.char) { C.free(unsafe.Pointer(s)) }

func main() {}
