"""Renders the App Store look (titanium phones, tinted badges, notification callout, grid and grain
background) with the pipeline's own functions, as transparent PNGs for the video to animate."""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.abspath(os.path.join(HERE, "../../appstore"))
sys.path.insert(0, APP)
import frame as F  # noqa: E402

OUT = os.path.join(HERE, "video_assets")
RAW = os.path.join(APP, "raw/en")
os.makedirs(OUT, exist_ok=True)
sizes = {}


def phone(name, src, pw, crop_h=1250):
    dev = F.device(f"{RAW}/{src}.png", pw, "natural")
    dev = dev.crop((0, 0, dev.width, min(dev.height, crop_h)))
    m = 160
    patch = Image.new("RGBA", (dev.width + 2 * m, dev.height + 2 * m), (0, 0, 0, 0))
    blk = Image.new("RGBA", dev.size, (0, 0, 0, 255))
    blk.putalpha(dev.split()[3].point(lambda v: int(v * 0.7)))
    patch.alpha_composite(blk, (m + 20, m + 60))
    patch = patch.filter(ImageFilter.GaussianBlur(55))
    patch.alpha_composite(dev, (m, m))
    patch.save(f"{OUT}/{name}.png")
    bez, pad = max(int(pw * 0.019), 14), int(pw * 0.012)
    shot = Image.open(f"{RAW}/{src}.png")
    sizes[name] = dict(w=patch.width, h=patch.height, m=m, bez=bez, pad=pad, pw=pw,
                       shot_h=int(shot.height * pw / shot.width))


def chip(name, title, icon, tint, scale, angle, sub=None, maxw=940, dot=None):
    sc = scale
    while F.chip_width(title, sc, icon=icon) > maxw and sc > 0.8:
        sc -= 0.05
    cv = Image.new("RGBA", (1500, 800), (0, 0, 0, 0))
    F.chip(cv, (220, 220), title, sub=sub, angle=angle, scale=sc, icon=icon, tint=tint, dot=dot)
    cv = cv.crop(cv.getbbox())
    cv.save(f"{OUT}/{name}.png")
    sizes[name] = dict(w=cv.width, h=cv.height)


def callout(name, k):
    path = f"{RAW}/07-card.png"
    card = Image.open(path)
    cv = Image.new("RGBA", (1400, 700), (0, 0, 0, 0))
    F.callout(cv, path, (0, 0, card.width, card.height), k, (200, 200), 0, radius=int(60 * k))
    cv = cv.crop(cv.getbbox())
    cv.save(f"{OUT}/{name}.png")
    sizes[name] = dict(w=cv.width, h=cv.height)


def background(name, w=1240, h=1510):
    rng = np.random.default_rng(7)
    y = np.linspace(0, 1, h)[:, None, None]
    img = np.repeat(np.array((15, 15, 17)) * (1 - y) + np.array((7, 7, 8)) * y, w, axis=1)
    xx, yy = np.arange(w)[None, :], np.arange(h)[:, None]
    cx = w / 2
    img += np.exp(-(((xx - cx) / 620.0) ** 2 + ((yy - 1500) / 940.0) ** 2))[..., None] * np.array([9, 9, 10])
    step = 100
    grid = np.zeros((h, w))
    grid[:, ::step] = 1
    grid[::step, :] = 1
    grid *= np.linspace(1.0, 0.55, h)[:, None]
    img += grid[..., None] * 11
    img += np.exp(-(((xx - cx) / 430.0) ** 2 + ((yy - 1050) / 740.0) ** 2))[..., None] * np.array([24, 25, 30])
    img += rng.normal(0, 1.8, (h, w, 1))
    Image.fromarray(np.clip(img, 0, 255).astype("uint8")).save(f"{OUT}/{name}.png")
    sizes[name] = dict(w=w, h=h)


background("bg")
phone("ph_session", "_lift-02-session", 720)
phone("ph_agents", "06-agents", 700)
phone("ph_keys", "_lift-03-keyboard", 700)
phone("ph_lock", "07-lock", 680, crop_h=1560)
chip("c_lid", "Works with the lid closed", "laptopcomputer", "green", 1.5, -3)
chip("c_awake", "Your Mac stays awake", "bolt.fill", "green", 1.5, 3)
chip("c_wol", "Wake on LAN", "dot.radiowaves.left.and.right", "teal", 1.5, -3)
chip("c_runs", "Runs on your Mac", "desktopcomputer", "blue", 1.6, 3)
chip("c_e2e", "End-to-end encrypted", "lock.fill", "purple", 1.4, -3, sub="Only your devices see it")
chip("c_face", "Face ID lock", "faceid", "blue", 1.5, 3)
chip("c_alert", "Lock Screen alerts", "bell.badge", "blue", 1.6, -3)
chip("c_noacct", "No account needed", "person.crop.circle.badge.xmark", "purple", 1.5, -3)
chip("c_any", "Any network", "network", "blue", 1.6, -3, sub="Home Wi-Fi or across the world")
chip("c_conn", "Connected", None, "green", 1.7, 3, dot=F.GREEN)
chip("c_kb", "A real keyboard", "keyboard", "blue", 1.6, 3)
chip("c_free", "Free on your own network", "network", "green", 1.4, 3)
callout("n_card", 680 / 1320 * 1.2)
json.dump(sizes, open(f"{OUT}/sizes.json", "w"), indent=1)
print({k: (v["w"], v["h"]) for k, v in sizes.items()})
