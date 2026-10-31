#!/usr/bin/env bash
# 生成 Linux 发布包：DEB / AppImage / RPM。
#
# 用法:
#   ./pack.sh <version> <bundle_dir> <out_dir> [app_name] [icon_png]
#
# 入参:
#   version      例如 0.1.0
#   bundle_dir   flutter build linux 产物，例如 build/linux/x64/release/bundle
#   out_dir      产物输出目录
#   app_name     默认 Vela
#   icon_png     桌面图标（png），默认 assets/icon/vela_icon_512.png
#
# 依赖（由 CI 安装）: dpkg-deb / appimagetool / (alien+rpm for RPM)
# 设计: DEB 与 AppImage 为必需产物；RPM 构建失败仅告警。
set -euo pipefail

VERSION="${1:?用法: pack.sh <version> <bundle_dir> <out_dir> [app_name] [icon_png]}"
BUNDLE="${2:?缺少 bundle 目录}"
OUT="${3:?缺少输出目录}"
APP="${4:-Vela}"
ICON="${5:-assets/icon/vela_icon_512.png}"
PKG="${APP,,}-${VERSION}"

if [ ! -d "$BUNDLE" ]; then echo "错误: 找不到 bundle: $BUNDLE" >&2; exit 1; fi

# 定位可执行文件名（bundle 根目录下带执行权限的普通文件）
EXE="$(find "$BUNDLE" -maxdepth 1 -type f -executable | head -n1)"
if [ -z "$EXE" ]; then echo "错误: bundle 中找不到可执行文件" >&2; exit 1; fi
EXE_NAME="$(basename "$EXE")"
echo "检测到可执行文件: $EXE_NAME"

mkdir -p "$OUT"

# ---------- 1) DEB ----------
echo "==> 构建 DEB: ${PKG}_amd64.deb"
STG="$(mktemp -d)"
trap 'rm -rf "$STG"' EXIT
DEB_ROOT="$STG/$PKG"
mkdir -p "$DEB_ROOT/opt/$APP" "$DEB_ROOT/usr/bin" \
         "$DEB_ROOT/usr/share/applications" \
         "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps" \
         "$DEB_ROOT/DEBIAN"

cp -R "$BUNDLE/." "$DEB_ROOT/opt/$APP/"
cat > "$DEB_ROOT/usr/bin/$APP" <<EOF
#!/bin/sh
exec "/opt/$APP/$EXE_NAME" "\$@"
EOF
chmod 755 "$DEB_ROOT/usr/bin/$APP"

cat > "$DEB_ROOT/usr/share/applications/$APP.desktop" <<EOF
[Desktop Entry]
Name=$APP
Comment=Cross-platform sing-box & mihomo client
Exec=/usr/bin/$APP
Icon=$APP
Terminal=false
Type=Application
Categories=Network;
EOF

cp "$ICON" "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps/$APP.png"

INST_SIZE="$(du -sk "$DEB_ROOT/opt/$APP" | cut -f1)"
cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: ${APP,,}
Version: $VERSION
Section: net
Priority: optional
Architecture: amd64
Maintainer: Vela <noreply@boxhub.dev>
Installed-Size: $INST_SIZE
Description: $APP — cross-platform sing-box & mihomo client
 Guided proxy client supporting sing-box and mihomo cores.
EOF
chmod 644 "$DEB_ROOT/DEBIAN/control"
chmod 755 "$DEB_ROOT/opt/$APP/$EXE_NAME"

dpkg-deb --build --root-owner-group "$DEB_ROOT" "$OUT/${PKG}_amd64.deb"
echo "    done: $(du -h "$OUT/${PKG}_amd64.deb" | cut -f1)"

# ---------- 2) AppImage ----------
echo "==> 构建 AppImage: ${PKG}-x86_64.AppImage"
APPDIR="$(mktemp -d)"
trap 'rm -rf "$STG" "$APPDIR"' EXIT
mkdir -p "$APPDIR"
cp -R "$BUNDLE/." "$APPDIR/"
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/$EXE_NAME" "$@"
EOF
chmod 755 "$APPDIR/AppRun"
cp "$ICON" "$APPDIR/$APP.png"
cat > "$APPDIR/$APP.desktop" <<EOF
[Desktop Entry]
Name=$APP
Comment=Cross-platform sing-box & mihomo client
Exec=$APP
Icon=$APP
Terminal=false
Type=Application
Categories=Network;
EOF

APPIMAGETOOL="$(command -v appimagetool || echo "$OUT/appimagetool")"
if [ ! -x "$APPIMAGETOOL" ]; then
  echo "    下载 appimagetool ..."
  curl -fsSL -o "$APPIMAGETOOL" \
    https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$APPIMAGETOOL"
fi
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUT/${PKG}-x86_64.AppImage"
echo "    done: $(du -h "$OUT/${PKG}-x86_64.AppImage" | cut -f1)"

# ---------- 3) RPM (best-effort, via alien) ----------
echo "==> 构建 RPM: ${PKG}-1.x86_64.rpm (best-effort)"
set +e
if command -v alien >/dev/null 2>&1 && command -v rpmbuild >/dev/null 2>&1; then
  if alien --to-rpm --scripts -k "$OUT/${PKG}_amd64.deb" 2>/tmp/alien.log; then
    mv -f "${PKG}-1.x86_64.rpm" "$OUT/" 2>/dev/null || \
      find . -maxdepth 1 -name '*.rpm' -exec mv -f {} "$OUT/" \;
    echo "    done: $(ls -1 "$OUT"/*.rpm 2>/dev/null | head -n1)"
  else
    echo "    alien 失败（不影响 DEB/AppImage）:"; tail -3 /tmp/alien.log
  fi
else
  echo "    未安装 alien/rpmbuild，跳过 RPM"
fi
set -e
