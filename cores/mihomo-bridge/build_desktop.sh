#!/bin/bash
# 构建桌面端桥接动态库（mihomo + sing-box）。
# 用法: ./build_desktop.sh [mihomo|singbox]   # 缺省构建两个
# 产物: boxhub/desktop-libs/<os>-<arch>/libboxhub_<core>.{dylib,dll,so}
set -euo pipefail
cd "$(dirname "$0")"

OUT_ROOT="../../desktop-libs"
mkdir -p "$OUT_ROOT"

# 使用国内 Go 代理（如已配置 GOPROXY 则跳过）
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

OS="$(go env GOOS)"
ARCH="$(go env GOARCH)"
OUT_DIR="$OUT_ROOT/$OS-$ARCH"
mkdir -p "$OUT_DIR"

build_one() {
  local core="$1"; shift
  local src_dir="$1"; shift
  local ext
  case "$OS" in
    darwin)  ext="dylib" ;;
    windows) ext="dll" ;;
    linux)   ext="so" ;;
    *) echo "不支持的平台: $OS" >&2; exit 1 ;;
  esac
  local OUT="$OUT_DIR/libboxhub_${core}.${ext}"
  echo "building $core ($OS/$ARCH) -> $OUT"
  (cd "$src_dir" && go build -trimpath -buildmode=c-shared -o "$(pwd)/$OUT" "$@" ./cshared)
  ls -lh "$OUT"
}

case "${1:-all}" in
  mihomo)  build_one mihomo  "."                          ;;
  singbox) build_one singbox "../singbox-bridge" -tags "with_clash_api,with_gvisor,with_quic" ;;
  all)
    build_one mihomo  "."
    build_one singbox "../singbox-bridge" -tags "with_clash_api,with_gvisor,with_quic"
    ;;
  *) echo "用法: $0 [mihomo|singbox]" >&2; exit 1 ;;
esac
echo DONE
