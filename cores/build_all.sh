#!/bin/bash
# BoxHub 全平台构建编排。
#
# 用法: ./build_all.sh desktop|android|all
#   desktop  桥接 dylib/dll/so + flutter build macos（在 macOS 上）
#   android  gomobile aar（arm64，需要 NDK）+ flutter build apk
#   all      依序执行
#
# 环境要求：
#   - tools/flutter-env.sh / tools/go-env.sh / tools/android-env.sh
#   - Windows/Linux 桌面端请在对应平台运行本脚本（构建本机产物）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # boxhub/
APP="$ROOT/app"
CORES="$ROOT/cores"

MODE="${1:-all}"

run_desktop() {
  echo "==> 桥接动态库（c-shared）"
  bash "$CORES/mihomo-bridge/build_desktop.sh"
  echo "==> flutter build macos"
  (cd "$APP" && flutter build macos --debug)
}

run_android() {
  echo "==> gomobile aar（android/arm64）"
  bash "$CORES/build_mobile.sh" mihomo android/arm64
  bash "$CORES/build_mobile.sh" singbox android/arm64
  cp "$ROOT"/mobile-libs/android/*.aar "$APP/android/app/libs/"
  echo "==> flutter build apk"
  (cd "$APP" && flutter build apk --release --target-platform android-arm64)
}

case "$MODE" in
  desktop) run_desktop ;;
  android) run_android ;;
  all)     run_desktop; run_android ;;
  *) echo "用法: $0 [desktop|android|all]" >&2; exit 1 ;;
esac
echo ALL_DONE
