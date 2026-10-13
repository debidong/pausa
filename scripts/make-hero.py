#!/usr/bin/env python3
"""Composite docs/images/hero.png (1024x640) from the hero-mock captures.

Five scenes as vertical strips, left to right: gray-white (App/backgrounds/system-base, no UI),
forest, ocean, sunset, night. Each strip is cut from that theme's real `--hero-mock` window capture
(see scripts/make-hero.sh), so the glass clock, sentence and skip capsule are the app's own
rendering over that scene. Neighbouring strips cross-fade over FEATHER px. Needs Pillow.

usage: make-hero.py <capture-dir> [out.png]
  capture-dir holds mock-forest.png mock-ocean.png mock-sunset.png mock-night.png system-base.png
"""
import sys
from PIL import Image

W, H, FEATHER = 1024, 640, 14
ORDER = ["system-base", "mock-forest", "mock-ocean", "mock-sunset", "mock-night"]

def cover(im):
    """Scale to cover WxH, center-crop."""
    im = im.convert("RGB")
    s = max(W / im.width, H / im.height)
    im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    x, y = (im.width - W) // 2, (im.height - H) // 2
    return im.crop((x, y, x + W, y + H))

def main():
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "docs/images/hero.png"
    layers = [cover(Image.open(f"{src}/{n}.png")) for n in ORDER]
    hero = layers[0].copy()
    edges = [round(W * i / len(ORDER)) for i in range(len(ORDER) + 1)]
    for i, im in enumerate(layers[1:], 1):
        e = edges[i]
        mask = Image.new("L", (W, H), 0)
        px = [0 if x < e - FEATHER else 255 if x >= e + FEATHER else round(255 * (x - e + FEATHER) / (2 * FEATHER))
              for x in range(W)]
        mask.putdata(px * H)
        hero.paste(im, (0, 0), mask)
    hero.save(out, optimize=True)
    print(out, hero.size)

if __name__ == "__main__":
    main()
