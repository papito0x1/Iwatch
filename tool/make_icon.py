#!/usr/bin/env python3
"""Generate the Iwatch app icon at all sizes.

Iwatch watches a wallet's value move, so the mark is a live rising area-chart
with a glowing "now" node, set on an Ubuntu orange -> aubergine squircle —
modern, legible down to 16px, and at home next to Yaru/Adwaita icons.
"""
import os
from PIL import Image, ImageDraw

OUT_HICOLOR = "linux/packaging/icons/hicolor"
OUT_ASSET = "assets/icon"
SS = 4  # supersample factor for crisp anti-aliasing

# Ubuntu brand colours (no Solana palette).
ORANGE = (233, 84, 32)      # Ubuntu Orange  #E95420
AUBERGINE = (119, 33, 111)  # Ubuntu aubergine #77216F
NODE_INNER = (233, 84, 32)  # orange dot inside the white "now" node


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def squircle_mask(size, radius):
    """Rounded-rectangle alpha mask."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def diagonal_gradient(size):
    """Diagonal purple -> green gradient."""
    g = Image.new("RGB", (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = lerp(ORANGE, AUBERGINE, t)
    return g


def render(size):
    s = size * SS
    icon = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # gradient body clipped to a squircle
    grad = diagonal_gradient(s).convert("RGBA")
    radius = int(s * 0.235)  # Yaru-ish corner radius
    mask = squircle_mask(s, radius)
    icon.paste(grad, (0, 0), mask)

    draw = ImageDraw.Draw(icon)

    # subtle top sheen — smooth vertical fade (no hard seam)
    sheen = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sp = sheen.load()
    for y in range(s):
        t = y / (s - 1)
        a = int(36 * max(0.0, 1.0 - t / 0.6) ** 1.5)
        if a:
            for x in range(s):
                sp[x, y] = (255, 255, 255, a)
    icon = Image.alpha_composite(icon, Image.composite(
        sheen, Image.new("RGBA", (s, s), (0, 0, 0, 0)), mask))
    draw = ImageDraw.Draw(icon)

    # --- the rising area-chart mark -------------------------------------
    # control points across the lower-middle band
    pts_norm = [
        (0.18, 0.66), (0.30, 0.58), (0.40, 0.69),
        (0.52, 0.45), (0.63, 0.55), (0.74, 0.34), (0.82, 0.40),
    ]
    pts = [(x * s, y * s) for x, y in pts_norm]

    # translucent fill under the line
    base_y = 0.82 * s
    poly = pts + [(pts[-1][0], base_y), (pts[0][0], base_y)]
    fill_layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(fill_layer).polygon(poly, fill=(255, 255, 255, 60))
    icon = Image.alpha_composite(icon, Image.composite(
        fill_layer, Image.new("RGBA", (s, s), (0, 0, 0, 0)), mask))
    draw = ImageDraw.Draw(icon)

    # the line itself
    lw = max(2, int(s * 0.045))
    draw.line(pts, fill=(255, 255, 255, 255), width=lw, joint="curve")
    # round the line caps
    r = lw / 2
    for p in (pts[0], pts[-1]):
        draw.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r],
                     fill=(255, 255, 255, 255))

    # glowing "now" node at the latest point
    nx, ny = pts[-1]
    glow_r = int(s * 0.085)
    for i in range(glow_r, 0, -1):
        a = int(120 * (1 - i / glow_r) ** 2)
        draw.ellipse([nx - i, ny - i, nx + i, ny + i],
                     fill=(255, 255, 255, a))
    node_r = int(s * 0.05)
    draw.ellipse([nx - node_r, ny - node_r, nx + node_r, ny + node_r],
                 fill=(255, 255, 255, 255))
    inner = int(node_r * 0.5)
    draw.ellipse([nx - inner, ny - inner, nx + inner, ny + inner],
                 fill=NODE_INNER + (255,))

    return icon.resize((size, size), Image.LANCZOS)


def main():
    os.makedirs(OUT_ASSET, exist_ok=True)
    for size in (16, 24, 32, 48, 64, 128, 256, 512):
        img = render(size)
        d = os.path.join(OUT_HICOLOR, f"{size}x{size}", "apps")
        os.makedirs(d, exist_ok=True)
        img.save(os.path.join(d, "io.github.papito0x1.iwatch.png"))
    # master assets for in-app use
    render(512).save(os.path.join(OUT_ASSET, "iwatch.png"))
    render(1024).save(os.path.join(OUT_ASSET, "iwatch@2x.png"))
    print("icons written")


if __name__ == "__main__":
    main()
