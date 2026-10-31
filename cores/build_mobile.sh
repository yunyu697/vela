#!/bin/bash
# gomobile bind 生成移动端绑定包（统一绑定包，含双内核）。
#
# 为什么只有一个绑定包：gomobile 每个 bind 产物都带一份 Go 运行时，
# Android 上一个进程只能加载一份 libgojni.so；双内核必须合并进单一
# 绑定包（cores/mobile）。iOS 同理，一个 XCFramework 里含两套内核。
#
# 用法:
#   ./build_mobile.sh                 # Android armeabi 默认 android/arm64
#   ./build_mobile.sh android/arm64
#   ./build_mobile.sh ios             # iOS 设备 + 模拟器 → XCFramework
set -e
TARGET="${1:-android/arm64}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # boxhub/

command -v gomobile >/dev/null || { echo "need gomobile in PATH (source tools/go-env.sh + go install golang.org/x/mobile/cmd/gomobile@latest)"; exit 1; }

cd "$ROOT/cores/mobile"

if [ "$TARGET" = "ios" ]; then
  # Network Extension 里跑内核：设备切片 + 模拟器切片各一份，
  # 由 gomobile 合成 XCFramework，Xcode 按平台自动选切片。
  OUT_DIR="$ROOT/mobile-libs/ios"
  mkdir -p "$OUT_DIR"
  gomobile bind -target=ios,iossimulator/arm64 \
    -o "$OUT_DIR/Boxhubmobile.xcframework" .
  echo "BUILT: $OUT_DIR/Boxhubmobile.xcframework"
  exit 0
fi

: "${ANDROID_NDK_HOME:?source tools/android-env.sh first}"
OUT_DIR="$ROOT/mobile-libs/android"
mkdir -p "$OUT_DIR"
gomobile bind -target="$TARGET" -androidapi 24 -javapkg com.boxhub \
  -o "$OUT_DIR/boxhub-mobile.aar" .
echo "BUILT: $OUT_DIR/boxhub-mobile.aar"
