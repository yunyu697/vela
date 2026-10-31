// BoxHub sing-box 桥接的桌面端 cgo 包装（macOS dylib / Windows dll / Linux so）。
//
// 移动端（gomobile）直接绑定库包本体,不需要本文件。
// 构建见 ../build_desktop.sh。
package main

// #include <stdlib.h>
import "C"

import (
	"unsafe"

	boxhub "github.com/boxhub/singbox-bridge"
)

//export StartConfig
func StartConfig(configJSON, workingDir, controllerAddr, secret *C.char) C.int {
	err := boxhub.StartConfig(
		C.GoString(configJSON),
		C.GoString(workingDir),
		C.GoString(controllerAddr),
		C.GoString(secret),
	)
	if err != nil {
		return 1
	}
	return 0
}

//export StopConfig
func StopConfig() C.int {
	if err := boxhub.StopConfig(); err != nil {
		return 1
	}
	return 0
}

//export RestartConfig
func RestartConfig(configJSON, workingDir, controllerAddr, secret *C.char) C.int {
	err := boxhub.RestartConfig(
		C.GoString(configJSON),
		C.GoString(workingDir),
		C.GoString(controllerAddr),
		C.GoString(secret),
	)
	if err != nil {
		return 1
	}
	return 0
}

//export IsRunning
func IsRunning() C.int {
	if boxhub.IsRunning() {
		return 1
	}
	return 0
}

//export LastError
func LastError() *C.char {
	return C.CString(boxhub.LastError())
}

//export FreeCString
func FreeCString(s *C.char) {
	C.free(unsafe.Pointer(s))
}

func main() {}
