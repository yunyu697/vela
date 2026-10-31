#!/usr/bin/env python3
"""Vela 应用图标生成器。

设计：双翼帆形（Apple 风格圆角方形 + 多层渐变 + 玻璃高光）。
- 底层：靛蓝 → 紫罗兰斜向渐变
- 主体：左右两片对称帆翼（白色半透明 → 实白渐变）
- 细节：中央节点圆点、顶部高光、底部内阴影、极轻微噪点避免色带

用法：
    python3 tools/make_icon.py            # 生成全套资源
    python3 tools/make_icon.py preview    # 只生成 1024 预览图到 build/
"""

import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSET_DIR = os.path.join(ROOT, "app", "assets", "icon")
MACOS_DIR = os.path.join(ROOT, "app", "macos", "Runner", "Assets.xcassets", "AppIcon.appiconset")
ANDROID_RES = os.path.join(ROOT, "app", "android", "app", "src", "main", "res")
PREVIEW_DIR = os.path.join(ROOT, "build", "icon-preview")

# Apple 风格圆角比例（相对边长）
CORNER_RATIO = 0.2237
SUPERSAMPLE = 4  # 超采样倍数，绘制后缩小获得抗锯齿

# 品牌渐变色
C_TOP_LEFT = (99, 102, 241)     # indigo-500
C_TOP_RIGHT = (139, 92, 246)    # violet-500
C_BOTTOM_LEFT = (79, 70, 229)   # indigo-600
C_BOTTOM_RIGHT = (168, 85, 247) # purple-500
C_HIGHLIGHT = (255, 255, 255)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def bilinear_gradient(size, c_tl, c_tr, c_bl, c_br):
    """对角四色渐变。

    先在低分辨率上求解再双三次放大：线性渐变放大后与逐像素求解
    结果一致，但耗时从 O(size^2) 降到 O(64^2)。
    """
    small = 64
    img = Image.new("RGB", (small, small))
    px = img.load()
    for y in range(small):
        fy = y / (small - 1)
        for x in range(small):
            fx = x / (small - 1)
            top = lerp(c_tl, c_tr, fx)
            bottom = lerp(c_bl, c_br, fx)
            px[x, y] = lerp(top, bottom, fy)
    return img.resize((size, size), Image.BICUBIC)


def vertical_alpha_ramp(size, a_top, a_bottom):
    """竖直方向线性渐变的白色蒙版（alpha 从 a_top 到 a_bottom）。"""
    ramp = Image.new("L", (1, 256))
    rp = ramp.load()
    for y in range(256):
        fy = y / 255
        rp[0, y] = int(round(a_top + (a_bottom - a_top) * fy))
    return ramp.resize((size, size), Image.BICUBIC)


def rounded_mask(size, radius_ratio, inset=0):
    """圆角矩形遮罩（带 1px 内缩以避免边缘羽化溢出）。"""
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    r = int(size * radius_ratio)
    d.rounded_rectangle(
        [inset, inset, size - 1 - inset, size - 1 - inset],
        radius=r,
        fill=255,
    )
    return mask


def _cubic(p0, p1, p2, p3, t):
    mt = 1 - t
    return (
        mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0],
        mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1],
    )


def tri_sail(size, mirror=False, bulge=1.0, slit=0.030):
    """正面双帆：沿中央桅杆留一道细缝，两片帆外缘外凸（帆腹）。

    这是最终定稿造型：几何简洁、一眼可读为「船帆」，
    与 Vela（船帆座）命名呼应，同时对称双帆暗合「双内核合流」。
    """
    inner = 0.5 + slit
    tip_x = 0.885
    top_y = 0.175
    bot_y = 0.790
    p0 = (inner, top_y)
    p1 = (0.500 + (tip_x - inner) * (0.34 - bulge * 0.18), 0.430 + bulge * 0.02)
    p2 = (0.500 + (tip_x - inner) * (0.92 + bulge * 0.05), 0.660)
    p3 = (tip_x, bot_y)

    pts = []
    for i in range(49):
        t = i / 48
        x, y = _cubic(p0, p1, p2, p3, t)
        pts.append((x, y))
    pts.append((inner, bot_y))
    if mirror:
        pts = [(1.0 - x, y) for (x, y) in pts]
    return [(x * size, y * size) for (x, y) in pts]


def render_icon(size):
    """渲染单张图标（已含圆角裁切与 alpha）。"""
    s = size * SUPERSAMPLE
    base = bilinear_gradient(s, C_TOP_LEFT, C_TOP_RIGHT, C_BOTTOM_LEFT, C_BOTTOM_RIGHT).convert("RGBA")

    # 斜向柔光（左上高光）
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-s * 0.25, -s * 0.45, s * 0.85, s * 0.55], fill=(255, 255, 255, 60))
    glow = glow.filter(ImageFilter.GaussianBlur(s * 0.16))
    base = Image.alpha_composite(base, glow)

    # 右下角冷色反光，增加层次
    cool = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    cd = ImageDraw.Draw(cool)
    cd.ellipse([s * 0.45, s * 0.55, s * 1.35, s * 1.35], fill=(56, 189, 248, 55))
    cool = cool.filter(ImageFilter.GaussianBlur(s * 0.20))
    base = Image.alpha_composite(base, cool)

    # 帆翼：先画柔和投影，再画本体
    sail_layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sail_layer)

    for mirrored in (False, True):
        pts = tri_sail(s, mirrored, bulge=1.0, slit=0.030)
        # 帆面：顶部半透明 -> 底部实白（用竖直 alpha 渐变遮罩实现）
        alpha = vertical_alpha_ramp(s, 150, 255)
        grad = Image.new("RGBA", (s, s), (255, 255, 255, 0))
        grad.putalpha(alpha)
        # 用遮罩裁出帆形
        mask = Image.new("L", (s, s), 0)
        ImageDraw.Draw(mask).polygon(pts, fill=255)
        sail_layer.paste(grad, (0, 0), mask)

    # 帆的投影（向下偏移）
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sh_mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(sh_mask).polygon(tri_sail(s, False), fill=120)
    ImageDraw.Draw(sh_mask).polygon(tri_sail(s, True), fill=120)
    sh_mask = sh_mask.filter(ImageFilter.GaussianBlur(s * 0.030))
    shadow.paste((28, 18, 68, 255), (0, 0), sh_mask)
    # 向下偏移投影
    shadow = shadow.transform(
        (s, s), Image.AFFINE, (1, 0, 0, 0, 1, -int(s * 0.016))
    )
    base = Image.alpha_composite(base, shadow)
    base = Image.alpha_composite(base, sail_layer)

    # 顶部玻璃高光（横向条带，制造材质感）
    sheen = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sd2 = ImageDraw.Draw(sheen)
    sd2.ellipse([-s * 0.1, -s * 0.62, s * 1.1, s * 0.30], fill=(255, 255, 255, 46))
    sheen = sheen.filter(ImageFilter.GaussianBlur(s * 0.09))
    base = Image.alpha_composite(base, sheen)

    # 内描边（1px 亮边，提升边缘清晰度）
    edge = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ed = ImageDraw.Draw(edge)
    rr = int(s * CORNER_RATIO)
    ed.rounded_rectangle([1, 1, s - 2, s - 2], radius=rr, outline=(255, 255, 255, 70), width=max(2, s // 320))
    base = Image.alpha_composite(base, edge)

    # 圆角裁切
    mask = rounded_mask(s, CORNER_RATIO)
    base.putalpha(mask)

    # 降采样抗锯齿
    out = base.resize((size, size), Image.LANCZOS)

    # 轻微噪点（消除大面积渐变的色带）
    noise = Image.effect_noise((size, size), 6).convert("L")
    rgb = out.convert("RGB")
    rgb = Image.blend(rgb, Image.merge("RGB", (noise, noise, noise)), 0.022)
    out = Image.merge("RGBA", (*rgb.split(), out.split()[3]))
    return out


def save_png(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG", optimize=True)
    print("  ", os.path.relpath(path, ROOT))


def make_iconset(icon1024):
    """macOS .iconset 目录（10/16/32 各倍 + 512/1024）。"""
    os.makedirs(MACOS_DIR, exist_ok=True)
    for name, size in [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]:
        save_png(icon1024.resize((size, size), Image.LANCZOS), os.path.join(MACOS_DIR, name))


def make_android(icon1024):
    """Android mipmap 各密度 + 前景层（自适应图标）。"""
    densities = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, size in densities.items():
        d = os.path.join(ANDROID_RES, folder)
        os.makedirs(d, exist_ok=True)
        save_png(icon1024.resize((size, size), Image.LANCZOS), os.path.join(d, "ic_launcher.png"))
        # 自适应图标前景：安全区 66%，帆形居中缩到 60%
        fg_size = int(size * 1.5)
        fg = Image.new("RGBA", (fg_size, fg_size), (0, 0, 0, 0))
        mark = icon1024.resize((int(size * 0.62), int(size * 0.62)), Image.LANCZOS)
        # 抠掉背景：取帆形区域的白色像素，重新着色为白
        px = mark.load()
        mpx = fg.load()
        ox = (fg_size - mark.width) // 2
        oy = (fg_size - mark.height) // 2
        for y in range(mark.height):
            for x in range(mark.width):
                r, g, b, a = px[x, y]
                # 背景色是蓝紫系，帆是白色系；用亮度阈值区分
                lum = (r + g + b) / 3
                if lum > 205:
                    alpha = int((lum - 205) / 50 * a)
                    mpx[ox + x, oy + y] = (255, 255, 255, min(255, alpha))
        save_png(fg, os.path.join(d, "ic_launcher_foreground.png"))


def make_flutter_assets(icon1024):
    save_png(icon1024, os.path.join(ASSET_DIR, "vela_icon.png"))
    save_png(icon1024.resize((512, 512), Image.LANCZOS), os.path.join(ASSET_DIR, "vela_icon_512.png"))
    save_png(icon1024.resize((256, 256), Image.LANCZOS), os.path.join(ASSET_DIR, "vela_icon_256.png"))


def write_iconset_contents():
    contents = """{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
    with open(os.path.join(MACOS_DIR, "Contents.json"), "w") as f:
        f.write(contents)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "all"
    print("渲染 1024px 主图标…")
    icon = render_icon(1024)

    if mode == "preview":
        os.makedirs(PREVIEW_DIR, exist_ok=True)
        save_png(icon, os.path.join(PREVIEW_DIR, "vela_1024.png"))
        save_png(icon.resize((256, 256), Image.LANCZOS), os.path.join(PREVIEW_DIR, "vela_256.png"))
        save_png(icon.resize((64, 64), Image.LANCZOS), os.path.join(PREVIEW_DIR, "vela_64.png"))
        save_png(icon.resize((32, 32), Image.LANCZOS), os.path.join(PREVIEW_DIR, "vela_32.png"))
        print("预览已输出到 build/icon-preview/")
        return

    print("生成 macOS iconset…")
    make_iconset(icon)
    write_iconset_contents()

    print("生成 Android mipmap…")
    make_android(icon)

    print("生成 Flutter 资源…")
    make_flutter_assets(icon)

    print("生成 macOS .icns…")
    icns_path = os.path.join(ROOT, "app", "macos", "Runner", "Assets.xcassets", "AppIcon.icns")
    iconset_dir = os.path.join(PREVIEW_DIR, "AppIcon.iconset")
    os.makedirs(iconset_dir, exist_ok=True)
    for name, size in [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]:
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset_dir, name), "PNG")
    os.system(f'iconutil -c icns "{iconset_dir}" -o "{icns_path}"')
    print("  ", os.path.relpath(icns_path, ROOT))

    print("完成。")


if __name__ == "__main__":
    main()
