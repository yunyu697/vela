#!/bin/bash
# gomobile bind 生成 Android aar（统一绑定包，含双内核）。
#
# 为什么只有一个 aar：gomobile 每个 bind 产物都带 libgojni.so，
# 一个进程只能加载一份；双内核必须合并进单一绑定包（cores/mobile）。
#
# 用法: ./build_mobile.sh [abi]     # abi 默认 android/arm64
set -e
ABI="${1:-android/arm64}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # boxhub/

command -v gomobile >/dev/null || { echo "need gomobile in PATH (source tools/go-env.sh + go install golang.org/x/mobile/cmd/gomobile@latest)"; exit 1; }
: "${ANDROID_NDK_HOME:?source tools/android-env.sh first}"

OUT_DIR="$ROOT/mobile-libs/android"
mkdir -p "$OUT_DIR"
cd "$ROOT/cores/mobile"
gomobile bind -target="$ABI" -androidapi 24 -javapkg com.boxhub \
  -o "$OUT_DIR/boxhub-mobile.aar" .
echo "BUILT: $OUT_DIR/boxhub-mobile.aar"
