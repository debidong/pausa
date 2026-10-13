#!/usr/bin/env python3
"""Build the hero backdrop (2048x1280, the 1024x640 pt mock window at 2x). No UI here.

Five scenes as vertical strips, left to right: gray-white (App/backgrounds/system-base), forest,
ocean, sunset, night; neighbours cross-fade over FEATHER px. The scenes are `--hero-mock <t> --bare`
window captures (the app's own scenery). scripts/make-hero.sh then opens the mock over this backdrop
and the window capture is the final hero, so the glass is one continuous render. Needs Pillow.

usage: make-hero.py <capture-dir> <out.png>
  capture-dir holds bare-forest.png bare-ocean.png bare-sunset.png bare-night.png system-base.png
"""
import sys
from PIL import Image

W, H, FEATHER = 2048, 1280, 28
ORDER = ["system-base", "bare-forest", "bare-ocean", "bare-sunset", "bare-night"]

def cover(im):
    """Scale to cover WxH, center-crop."""
    im = im.convert("RGB")
    s = max(W / im.width, H / im.height)
    im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    x, y = (im.width - W) // 2, (im.height - H) // 2
    return im.crop((x, y, x + W, y + H))

def main():
    src = sys.argv[1]
    out = sys.argv[2]
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
