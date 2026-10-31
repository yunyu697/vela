#!/usr/bin/env python3
"""帆形变体对比表：一次渲染多个方案，人工挑选后固化到 make_icon.py。"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw, ImageFilter

import make_icon as MI


def _cubic(p0, p1, p2, p3, t):
    mt = 1 - t
    return (
        mt**3*p0[0] + 3*mt**2*t*p1[0] + 3*mt*t**2*p2[0] + t**3*p3[0],
        mt**3*p0[1] + 3*mt**2*t*p1[1] + 3*mt*t**2*p2[1] + t**3*p3[1],
    )


def _normal(t, p0, p1, p2, p3):
    mt = 1 - t
    dx = 3*mt**2*(p1[0]-p0[0]) + 6*mt*t*(p2[0]-p1[0]) + 3*t**2*(p3[0]-p2[0])
    dy = 3*mt**2*(p1[1]-p0[1]) + 6*mt*t*(p2[1]-p1[1]) + 3*t**2*(p3[1]-p2[1])
    n = math.hypot(dx, dy) or 1.0
    return (-dy/n, dx/n)


def stroke_sail(ctrl, halfw, mirror=False, steps=64):
    """由中心线 + 半宽函数生成一片帆的轮廓。"""
    p0, p1, p2, p3 = ctrl
    a, b = [], []
    for i in range(steps + 1):
        t = i / steps
        cx, cy = _cubic(p0, p1, p2, p3, t)
        nx, ny = _normal(t, p0, p1, p2, p3)
        w = halfw(t)
        a.append((cx + nx*w, cy + ny*w))
        b.append((cx - nx*w, cy - ny*w))
    pts = a + list(reversed(b))
    if mirror:
        pts = [(1.0-x, y) for (x, y) in pts]
    return pts


def stroke_sail(ctrl, halfw, mirror=False, steps=64, cap_bottom=0.0, cap_top=0.0):
    """由中心线 + 半宽函数生成一片帆的轮廓。"""
    p0, p1, p2, p3 = ctrl
    a, b = [], []
    for i in range(steps + 1):
        t = i / steps
        cx, cy = _cubic(p0, p1, p2, p3, t)
        nx, ny = _normal(t, p0, p1, p2, p3)
        w = halfw(t)
        a.append((cx + nx * w, cy + ny * w))
        b.append((cx - nx * w, cy - ny * w))
    pts = a + list(reversed(b))
    if mirror:
        pts = [(1.0 - x, y) for (x, y) in pts]
    return pts, a[0], a[-1], b[0], b[-1]


def render_variant(v, size=512):
    """按变体定义渲染，caps 为需要补圆帽的端点。"""
    s = size * 2
    base = MI.bilinear_gradient(s, MI.C_TOP_LEFT, MI.C_TOP_RIGHT, MI.C_BOTTOM_LEFT, MI.C_BOTTOM_RIGHT).convert("RGBA")
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([-s * 0.25, -s * 0.45, s * 0.85, s * 0.55], fill=(255, 255, 255, 60))
    base = Image.alpha_composite(base, glow.filter(ImageFilter.GaussianBlur(s * 0.16)))

    mask = Image.new("L", (s, s), 0)
    md = ImageDraw.Draw(mask)
    if v.get("poly") == "tri":
        for mirror in (False, True):
            md.polygon(
                _tri_sail(s, mirror, v.get("bulge", 0.0), v.get("slit", 0.026)),
                fill=255,
            )
    else:
        for mirror in (False, True):
            pts, a0, a1, b0, b1 = stroke_sail(v["ctrl"], v["halfw"], mirror)
            md.polygon([(x * s, y * s) for (x, y) in pts], fill=255)
            for (px, py), r in [(a0, v.get("cap_a", 0)), (b0, v.get("cap_b", 0))]:
                if r > 0:
                    md.ellipse([px * s - r * s, py * s - r * s, px * s + r * s, py * s + r * s], fill=255)

    alpha = MI.vertical_alpha_ramp(s, 170, 255)
    grad = Image.new("RGBA", (s, s), (255, 255, 255, 0))
    grad.putalpha(alpha)
    sail = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sail.paste(grad, (0, 0), mask)
    base = Image.alpha_composite(base, sail)

    if v.get("node"):
        nx, ny, r = v["node"]
        node = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        ImageDraw.Draw(node).ellipse(
            [s * nx - s * r, s * ny - s * r, s * nx + s * r, s * ny + s * r], fill=(255, 255, 255, 255))
        base = Image.alpha_composite(base, node.filter(ImageFilter.GaussianBlur(s * 0.003)))

    sheen = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).ellipse([-s * 0.1, -s * 0.62, s * 1.1, s * 0.30], fill=(255, 255, 255, 46))
    base = Image.alpha_composite(base, sheen.filter(ImageFilter.GaussianBlur(s * 0.09)))

    base.putalpha(MI.rounded_mask(s, MI.CORNER_RATIO))
    return base.resize((size, size), Image.LANCZOS)


def _tri_sail(size, mirror=False, bulge=0.0, slit=0.026):
    """正面双帆：沿中央桅杆留一道细缝，两片帆外缘外凸（帆腹）。"""
    inner = 0.5 + slit
    outer = 0.5 - slit
    top_y = 0.175
    bot_y = 0.790
    tip_x = 0.885
    base_x = 0.115
    ctrl = (0.500 + (tip_x - inner) * (0.34 - bulge * 0.18),
            0.430 + bulge * 0.02)
    pts = []
    # 外缘：从顶端沿外凸曲线到外侧底角
    for i in range(49):
        t = i / 48
        p0 = (inner, top_y)
        p1 = ctrl
        p2 = (0.500 + (tip_x - inner) * (0.92 + bulge * 0.05), 0.660)
        p3 = (tip_x, bot_y)
        mt = 1 - t
        x = mt**3*p0[0] + 3*mt**2*t*p1[0] + 3*mt*t**2*p2[0] + t**3*p3[0]
        y = mt**3*p0[1] + 3*mt**2*t*p1[1] + 3*mt*t**2*p2[1] + t**3*p3[1]
        pts.append((x, y))
    # 底边回到桅杆
    pts.append((inner, bot_y))
    if mirror:
        pts = [(1.0 - x, y) for (x, y) in pts]
    return [(x * size, y * size) for (x, y) in pts]


def _tapered(base, peak, sharpness, tip=0.0):
    """半宽曲线：底部 base，中段 peak，末端收成尖角（tip=0 为纯锐尖）。"""
    def f(t):
        w = base + peak * (math.sin(math.pi * (t ** 0.92)) ** 0.60)
        return w * (1.0 - t ** sharpness) + tip * (1.0 - t)
    return f


VARIANTS = {
    # M: 直边双三角帆
    "M": dict(poly="tri", bulge=0.0, slit=0.030),
    # N: 外凸帆腹
    "N": dict(poly="tri", bulge=1.0, slit=0.030),
    # O: 外凸帆腹 + 更窄桅杆缝
    "O": dict(poly="tri", bulge=1.0, slit=0.020),
}


def render(v, size=512):
    return render_variant(v, size)


def main():
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "icon-preview")
    os.makedirs(out, exist_ok=True)
    cell = 260
    sheet = Image.new("RGB", (3 * cell, cell), (245, 246, 250))
    for i, (name, v) in enumerate(VARIANTS.items()):
        img = render(v, 512)
        img.save(os.path.join(out, f"variant_{name}.png"))
        small = img.resize((cell - 20, cell - 20), Image.LANCZOS)
        sheet.paste(small.convert("RGB"), (i * cell + 10, 10))
    sheet.save(os.path.join(out, "variants.png"))
    print("变体已输出：", out)


if __name__ == "__main__":
    main()
