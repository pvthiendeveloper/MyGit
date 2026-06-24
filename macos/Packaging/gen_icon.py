#!/usr/bin/env python3
"""Generate AppIcon.icns for MyGit."""
import math, os, subprocess, shutil
from PIL import Image, ImageDraw

SIZE = 1024

def draw_icon(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = size

    # --- Background: rounded rect with dark gradient ---
    radius = s * 0.22
    # Draw gradient background by stacking horizontal lines
    for y in range(s):
        t = y / s
        # top: #0E1621  bottom: #1A2744
        r = int(0x0E + (0x1A - 0x0E) * t)
        g = int(0x16 + (0x27 - 0x16) * t)
        b = int(0x21 + (0x44 - 0x21) * t)
        d.line([(0, y), (s, y)], fill=(r, g, b, 255))

    # Mask to rounded rect
    mask = Image.new("L", (s, s), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([0, 0, s - 1, s - 1], radius=int(radius), fill=255)
    img.putalpha(mask)

    # --- Git branch graph ---
    # Layout: 3 nodes in a branch shape
    # main: bottom-center  →  up  →  top-center (straight)
    # feature: branches off mid-point → top-right
    cx = s * 0.42
    node_r = s * 0.055
    lw = int(s * 0.038)

    # Node positions
    n_bottom = (cx, s * 0.72)          # base commit (main)
    n_mid    = (cx, s * 0.44)          # branch point
    n_top    = (cx, s * 0.18)          # head of main
    n_feat   = (cx + s * 0.26, s * 0.26)  # head of feature branch

    # Line color: muted blue-white
    lc = (180, 200, 230, 220)
    # Feature branch line color: accent orange
    ac = (255, 140, 60, 240)

    def line(a, b, color, width):
        d.line([a, b], fill=color, width=width)

    def circle(center, r, fill, outline=None, ow=0):
        x, y = center
        d.ellipse([x-r, y-r, x+r, y+r], fill=fill,
                  outline=outline, width=ow)

    # Draw lines (behind nodes)
    # Main trunk
    line(n_bottom, n_mid, lc, lw)
    line(n_mid, n_top, lc, lw)
    # Feature branch curve: approximate with two segments
    # control point for curve feel
    mid_x = (n_mid[0] + n_feat[0]) / 2
    mid_y = (n_mid[1] + n_feat[1]) / 2 - s * 0.04
    line(n_mid, (mid_x, mid_y), ac, lw)
    line((mid_x, mid_y), n_feat, ac, lw)

    # Draw nodes
    # Bottom (main, gray)
    circle(n_bottom, node_r, (130, 155, 185, 255), (200, 220, 245, 255), int(lw * 0.6))
    # Mid branch point (white)
    circle(n_mid, node_r, (210, 225, 245, 255), (240, 248, 255, 255), int(lw * 0.6))
    # Top main HEAD (bright white)
    circle(n_top, node_r * 1.15, (240, 248, 255, 255), (255, 255, 255, 255), int(lw * 0.6))
    # Feature HEAD (orange accent)
    circle(n_feat, node_r * 1.2, (255, 140, 60, 255), (255, 180, 100, 255), int(lw * 0.6))

    # Star on feature HEAD (current branch indicator)
    star_r = node_r * 0.55
    fx, fy = n_feat
    for i in range(5):
        angle = math.radians(-90 + i * 72)
        ox = fx + star_r * math.cos(angle)
        oy = fy + star_r * math.sin(angle)
        d.ellipse([ox-2, oy-2, ox+2, oy+2], fill=(255, 255, 255, 200))

    return img


def make_iconset(base_img, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for sz in sizes:
        img = base_img.resize((sz, sz), Image.LANCZOS)
        img.save(os.path.join(out_dir, f"icon_{sz}x{sz}.png"))
        if sz <= 512:
            img2 = base_img.resize((sz * 2, sz * 2), Image.LANCZOS)
            img2.save(os.path.join(out_dir, f"icon_{sz}x{sz}@2x.png"))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    iconset = os.path.join(here, "AppIcon.iconset")
    icns = os.path.join(here, "AppIcon.icns")

    print("Drawing icon...")
    img = draw_icon(SIZE)

    print("Building iconset...")
    make_iconset(img, iconset)

    print("Converting to .icns...")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    shutil.rmtree(iconset)
    print(f"Done: {icns}")


if __name__ == "__main__":
    main()
