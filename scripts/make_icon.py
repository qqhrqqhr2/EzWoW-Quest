#!/usr/bin/env python3
"""Draws the EzWoW - Quest icon.

Outputs docs/images/icon_256.png (project logo), Media/Icon.png (256 x 256) and
Media/Icon.tga (64 x 64, 32-bit, top-left origin) used by the .toc and the windows.
The frame follows the shared EzWoW icon frame; the accent ring uses the addon accent
(0.478, 0.635, 0.969) muted like the other icons. Emblem: a parchment scroll with a
gold quest "!".

usage: python scripts/make_icon.py .   (needs Pillow)
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SS = 4                      # supersampling
N = 256 * SS

FRAME = "#344c5b"
PANEL = "#1d2831"
RING = "#6889bd"            # muted accent
DARK = "#0b1217"
DOT = "#485e70"
PARCH = "#efe2bf"
PARCH_SHADE = "#d3bd8a"
ROLL = "#c9ad74"
ROLL_HI = "#e6d3a3"
GOLD = "#ffd23f"
GOLD_SHADE = "#e0a91c"


def s(v):
    return round(v * SS)


def box(x0, y0, x1, y1):
    return [s(x0), s(y0), s(x1), s(y1)]


def mask_of(draw_fn):
    m = Image.new("L", (N, N), 0)
    draw_fn(ImageDraw.Draw(m))
    return m


def dilate(mask, width):
    """Round dilation by `width` icon pixels (blur + threshold)."""
    r = width * SS
    blurred = mask.filter(ImageFilter.GaussianBlur(r / 2))
    return blurred.point(lambda v: 255 if v > 8 else 0)


def paint(img, mask, color):
    img.paste(Image.new("RGBA", (N, N), color), (0, 0), mask)


def scroll_shapes(d, fill=255):
    # body
    d.rectangle(box(76, 70, 180, 186), fill=fill)
    # top and bottom rolls
    d.rounded_rectangle(box(62, 56, 194, 82), radius=s(13), fill=fill)
    d.rounded_rectangle(box(62, 174, 194, 200), radius=s(13), fill=fill)


def bang_shapes(d, fill=255):
    # tapered bar with rounded ends, then the dot
    d.polygon([(s(113), s(84)), (s(143), s(84)), (s(136), s(146)), (s(120), s(146))], fill=fill)
    d.ellipse(box(113, 69, 143, 99), fill=fill)
    d.ellipse(box(120, 138, 136, 154), fill=fill)
    d.ellipse(box(114, 158, 142, 186), fill=fill)


def draw():
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # shared EzWoW frame
    d.rounded_rectangle(box(4, 4, 252, 252), radius=s(60), fill=FRAME)
    d.rounded_rectangle(box(12, 12, 244, 244), radius=s(52), fill=PANEL)
    d.rounded_rectangle(box(14, 14, 242, 242), radius=s(50), fill=RING)
    d.rounded_rectangle(box(20, 20, 236, 236), radius=s(44), fill=DARK)
    d.rounded_rectangle(box(24, 24, 232, 232), radius=s(40), fill=PANEL)
    d.ellipse(box(43, 34, 61, 52), fill=DOT)

    # scroll: dark outline, parchment, shading, rolls
    scroll = mask_of(scroll_shapes)
    paint(img, dilate(scroll, 7), DARK)
    d.rectangle(box(76, 70, 180, 186), fill=PARCH)
    d.rectangle(box(164, 70, 180, 186), fill=PARCH_SHADE)
    for y0 in (56, 174):
        d.rounded_rectangle(box(62, y0, 194, y0 + 26), radius=s(13), fill=ROLL)
        d.rounded_rectangle(box(68, y0 + 4, 188, y0 + 11), radius=s(4), fill=ROLL_HI)
        # roll ends
        d.ellipse(box(62, y0, 76, y0 + 26), fill=PARCH_SHADE)
        d.ellipse(box(180, y0, 194, y0 + 26), fill=PARCH_SHADE)
        d.ellipse(box(65, y0 + 8, 73, y0 + 18), fill=DARK)
        d.ellipse(box(183, y0 + 8, 191, y0 + 18), fill=DARK)

    # gold quest mark
    bang = mask_of(bang_shapes)
    paint(img, dilate(bang, 7), DARK)
    paint(img, bang, GOLD)
    # right-side shade on the bar and the dot
    shade = mask_of(lambda dd: (dd.polygon([(s(130), s(84)), (s(143), s(84)), (s(136), s(146)), (s(128), s(146))], fill=255),
                                 dd.ellipse(box(130, 160, 142, 184), fill=255)))
    shade = Image.composite(shade, Image.new("L", (N, N), 0), bang)
    paint(img, shade, GOLD_SHADE)
    return img.resize((256, 256), Image.LANCZOS)


def main(root: Path):
    root = root.resolve()
    icon = draw()
    out = root / "docs" / "images"
    out.mkdir(parents=True, exist_ok=True)
    icon.save(out / "icon_256.png", optimize=True)
    icon.save(root / "Media" / "Icon.png", optimize=True)
    small = icon.resize((64, 64), Image.LANCZOS)
    small.save(root / "Media" / "Icon.tga", orientation=1, compression=None)
    print("wrote", out / "icon_256.png", root / "Media" / "Icon.png", root / "Media" / "Icon.tga")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "."))
