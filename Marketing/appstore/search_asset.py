"""Builds the 3:2 App Store search-result asset from the first three framed screenshots.

The three canvases already read as one panorama (one backdrop, one phone crossing the first seam),
so the asset is those three side by side, trimmed top and bottom to 3:2 and scaled to 3840x2560.

    python3 search_asset.py          # every locale in upload/screenshots into out/search/<folder>.png
"""
import os
import sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(HERE, "upload/screenshots")
OUT = os.path.join(HERE, "out/search")
W, H = 1320, 2868
ASSET = (3840, 2560)
TRIM_TOP = 100


def build(folder):
    names = sorted(name for name in os.listdir(os.path.join(SHOTS, folder)) if name.endswith(".png"))[:3]
    panorama = Image.new("RGB", (W * 3, H))
    for index, name in enumerate(names):
        panorama.paste(Image.open(os.path.join(SHOTS, folder, name)).convert("RGB"), (index * W, 0))
    height = W * 3 * ASSET[1] // ASSET[0]
    crop = panorama.crop((0, TRIM_TOP, W * 3, TRIM_TOP + height))
    return crop.resize(ASSET, Image.LANCZOS)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    folders = sys.argv[1:] or sorted(name for name in os.listdir(SHOTS) if os.path.isdir(os.path.join(SHOTS, name)) and name != "ipad")
    for folder in folders:
        build(folder).save(os.path.join(OUT, f"{folder}.png"))
        print(folder)
