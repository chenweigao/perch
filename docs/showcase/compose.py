#!/usr/bin/env python3
"""Compose README showcase PNGs from native view-cache captures.

usage: docs/showcase/compose.py <capture.png> <out.png> <light|dark> [corner] [traffic]
The capture keeps the window glass underlay but not the system blur, so it is
placed over a smooth gradient (blur of a smooth field is the field itself).
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

src, out, mode = sys.argv[1], sys.argv[2], sys.argv[3]
corner = int(sys.argv[4]) if len(sys.argv) > 4 else 26
traffic = (sys.argv[5] if len(sys.argv) > 5 else "1") == "1"

win = Image.open(src).convert("RGBA")
W, H = win.size
pad_x, pad_top, pad_bottom = 72, 56, 64
CW, CH = W + 2 * pad_x, H + pad_top + pad_bottom

# Backdrop: a quiet two-stop diagonal gradient.
if mode == "dark":
    a, b = (40, 46, 58), (22, 25, 32)
else:
    a, b = (236, 240, 245), (247, 243, 236)
grad = Image.new("RGB", (CW, CH))
px = grad.load()
for y in range(CH):
    for x in range(CW):
        t = (x / CW * 0.6 + y / CH * 0.4)
        px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
base = grad.convert("RGBA")
canvas = base.copy()

mask = Image.new("L", (W, H), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=corner, fill=255)

# Shadow.
shadow = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
sm = Image.new("L", (CW, CH), 0)
ImageDraw.Draw(sm).rounded_rectangle([pad_x, pad_top + 14, pad_x + W, pad_top + H + 14], radius=corner,
                                     fill=110 if mode == "dark" else 60)
shadow.putalpha(sm.filter(ImageFilter.GaussianBlur(28)))
canvas = Image.alpha_composite(canvas, shadow)

# Window: backdrop seen through the underlay, then the capture.
region = base.crop((pad_x, pad_top, pad_x + W, pad_top + H))
body = Image.alpha_composite(region, win)
if traffic:
    d = ImageDraw.Draw(body)
    for i, color in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx, cy, r = 26 + i * 20, 26, 6
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=color + (255,))
edge = Image.new("RGBA", (W, H), (0, 0, 0, 0))
ImageDraw.Draw(edge).rounded_rectangle([0, 0, W - 1, H - 1], radius=corner,
                                       outline=(255, 255, 255, 40) if mode == "dark" else (0, 0, 0, 38), width=1)
body = Image.alpha_composite(body, edge)
canvas.paste(body, (pad_x, pad_top), mask)

# Disclosure footer.
d = ImageDraw.Draw(canvas)
font = None
for candidate in [os.environ.get("PERCH_SHOWCASE_FONT", ""), "/System/Library/Fonts/PingFang.ttc",
                  "/System/Library/Fonts/Hiragino Sans GB.ttc", "NotoSansCJK-Regular.ttc"]:
    try:
        font = ImageFont.truetype(candidate, 14)
        break
    except OSError:
        continue
font = font or ImageFont.load_default()
ink = (150, 156, 168) if mode == "dark" else (120, 120, 126)
note = "原生视图渲染 · 演示数据 · 系统玻璃以平滑底色近似 / Native view render · Demo content"
tw = d.textlength(note, font=font)
d.text((CW - pad_x - tw, CH - pad_bottom / 2 - 8), note, fill=ink, font=font)
d.text((pad_x, CH - pad_bottom / 2 - 8), "github.com/chenweigao/perch", fill=ink, font=font)
canvas.convert("RGB").save(out, optimize=True)
print(out, canvas.size)
