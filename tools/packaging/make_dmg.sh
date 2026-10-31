#!/usr/bin/env bash
# 生成 macOS DMG 安装包。
#
# 用法:
#   ./make_dmg.sh <release_app_bundle> <output_dmg> [app_name]
#
# 入参:
#   release_app_bundle  例如 build/macos/Build/Products/Release/Vela.app
#   output_dmg         例如 artifacts/Vela-0.1.0-macos.dmg
#   app_name           卷标/显示名，默认 Vela
#
# 产物: 一个可拖拽安装的压缩 DMG（含 /Applications 快捷方式）。
set -euo pipefail

APP_BUNDLE="${1:?用法: make_dmg.sh <app_bundle> <output_dmg> [app_name]}"
OUT_DMG="${2:?缺少输出 dmg 路径}"
APP_NAME="${3:-Vela}"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "错误: 找不到 app bundle: $APP_BUNDLE" >&2
  exit 1
fi

# 优先使用 create-dmg（带背景/图标定位），不可用则回退到 hdiutil。
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

STAGING="$TMP_DIR/$APP_NAME"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$(dirname "$OUT_DMG")"

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 150 160 \
    --icon "Applications" 380 160 \
    --app-drop-link 380 160 \
    "$OUT_DMG" \
    "$STAGING" || {
      echo "create-dmg 失败，回退 hdiutil" >&2
      hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$OUT_DMG"
    }
else
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$OUT_DMG"
fi

echo "DMG 已生成: $OUT_DMG ($(du -h "$OUT_DMG" | cut -f1))"
