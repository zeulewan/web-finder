#!/usr/bin/env python3
"""Generate WebFinder.app icon - radar/scan aesthetic."""
import os, math
from PIL import Image, ImageDraw

def make_icon(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = size
    pad = s * 0.06

    # Background rounded rect
    r = s * 0.22
    d.rounded_rectangle([pad, pad, s - pad, s - pad], radius=r,
                         fill=(22, 28, 45, 255))

    cx, cy = s / 2, s / 2
    lw = max(1, s // 64)

    # Radar arcs (3 concentric, fading outward)
    arc_color = (64, 180, 255, 255)
    arc_faint  = (64, 180, 255, 120)
    arc_faintest = (64, 180, 255, 55)
    for i, (radius_frac, color) in enumerate([
        (0.18, arc_color),
        (0.28, arc_faint),
        (0.38, arc_faintest),
    ]):
        r2 = s * radius_frac
        box = [cx - r2, cy - r2, cx + r2, cy + r2]
        d.arc(box, start=0, end=360, fill=color, width=max(1, s // 52))

    # Sweep line
    angle = math.radians(-40)
    sweep_len = s * 0.38
    ex = cx + sweep_len * math.cos(angle)
    ey = cy + sweep_len * math.sin(angle)
    d.line([(cx, cy), (ex, ey)], fill=(64, 180, 255, 200), width=max(1, s // 48))

    # Center dot
    dot_r = s * 0.04
    d.ellipse([cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r],
              fill=(64, 180, 255, 255))

    # Blip dot on sweep tip
    blip_r = s * 0.03
    blip_x = cx + s * 0.30 * math.cos(angle)
    blip_y = cy + s * 0.30 * math.sin(angle)
    d.ellipse([blip_x - blip_r, blip_y - blip_r,
               blip_x + blip_r, blip_y + blip_r],
              fill=(120, 220, 255, 255))

    return img

iconset = "AppIcon.iconset"
os.makedirs(iconset, exist_ok=True)

sizes = [16, 32, 64, 128, 256, 512, 1024]
for sz in sizes:
    make_icon(sz).save(f"{iconset}/icon_{sz}x{sz}.png")
    # @2x versions
    if sz <= 512:
        make_icon(sz * 2).save(f"{iconset}/icon_{sz}x{sz}@2x.png")

print("Iconset generated.")
