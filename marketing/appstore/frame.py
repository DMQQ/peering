"""Frames the raw app captures into App Store canvases, the way Epoch's pipeline does: one wide
strip, the first two canvases sharing a single large phone across their seam, then cropped.

    python3 frame.py            # English, into out/en/
"""
import json, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1320, 2868
N = 5
PW = W * 7
BG_TOP, BG_BOT = (25, 25, 27), (8, 8, 9)
TRACK = 0.0
HERE = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(7)


LANG = "en"
SERIF = {"ja": ("/System/Library/Fonts/ヒラギノ明朝 ProN.ttc", 2), "zh-Hans": ("/System/Library/Fonts/Supplemental/Songti.ttc", 1),
         "ko": ("/System/Library/Fonts/Supplemental/AppleMyungjo.ttf", 0)}
SANS = {"ja": ("/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc", 0), "zh-Hans": ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0),
        "ko": ("/System/Library/Fonts/AppleSDGothicNeo.ttc", 0)}
BLUE_TEXT = (10, 132, 255, 255)


def font(size, weight=800):
    if LANG in SERIF:
        path, idx = SERIF[LANG]
        return ImageFont.truetype(path, size, index=idx)
    f = ImageFont.truetype("/System/Library/Fonts/NewYork.ttf", size)
    f.set_variation_by_axes([36, weight, 0])
    return f


def adv(text, i, f, size):
    c = text[i]
    w = f.getlength(c + text[i + 1]) - f.getlength(text[i + 1]) if i + 1 < len(text) else f.getlength(c)
    return w + TRACK * size


def line_width(text, f, size):
    if LANG in SERIF:
        return f.getlength(text)
    return sum(adv(text, i, f, size) + 8 for i in range(len(text)))


def plain(t):
    return t.replace("*", "")


def headline(canvas, text, xy, size, right=None):
    d = ImageDraw.Draw(canvas)
    f = font(size)
    fh = font(int(size * 1.25))
    base = int(size * 0.92)
    x0, y = xy
    track = 0 if LANG in SERIF else TRACK
    for ln in text.split("\n"):
        x = x0 if right is None else right - mixed_width(ln, size)
        hl = False
        raw = plain(ln)
        i = 0
        hl_start = None
        for c in ln:
            if c == "*":
                if not hl:
                    hl_start = x
                elif hl_start is not None:
                    pass
                hl = not hl
                continue
            sw = size // 110 if hl else 0
            ff = fh if hl else f
            d.text((x, y + base), c, font=ff, fill=(255, 255, 255, 255), stroke_width=sw, stroke_fill=(255, 255, 255, 255), anchor="ls")
            x += (ff.getlength(raw[i : i + 2]) - ff.getlength(raw[i + 1 : i + 2]) if i + 1 < len(raw) else ff.getlength(c)) + track * size + sw
            i += 1
        y += int(size * (1.3 if LANG in SERIF else 1.24))


def mixed_width(ln, size):
    f, fh = font(size), font(int(size * 1.25))
    total, hl = 0.0, False
    track = 0 if LANG in SERIF else TRACK
    for c in ln:
        if c == "*":
            hl = not hl
            continue
        ff = fh if hl else f
        total += ff.getlength(c) + track * size + (size // 110 if hl else 0)
    return total


def fit(texts, start, maxw=1170):
    z = start
    while any(mixed_width(l, z) > maxw for t in texts for l in t.split("\n")):
        z -= 4
    return z


TONES = {"natural": (122, 120, 124, 255), "silver": (178, 180, 184, 255), "graphite": (62, 63, 67, 255), "titanium": (150, 148, 144, 255)}


def device(path, pw, tone="natural"):
    shot = Image.open(path).convert("RGB")
    s = pw / shot.width
    ph = int(shot.height * s)
    shot = shot.resize((pw, ph), Image.LANCZOS)
    bez = max(int(pw * 0.019), 14)
    r = int(pw * 0.142)
    pad = int(pw * 0.012)
    dw, dh = pw + 2 * bez, ph + 2 * bez
    dev = Image.new("RGBA", (dw + 2 * pad, dh), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dev)
    ti = TONES[tone]
    bw = pad + 2
    for y0, h in ((0.17, 0.035), (0.235, 0.06), (0.31, 0.06)):
        dd.rounded_rectangle((0, int(dh * y0), bw, int(dh * (y0 + h))), radius=4, fill=ti)
    dd.rounded_rectangle((dw + 2 * pad - bw, int(dh * 0.25), dw + 2 * pad, int(dh * 0.25 + dh * 0.095)), radius=4, fill=ti)
    body = Image.new("RGBA", (dw, dh), (0, 0, 0, 0))
    bd = ImageDraw.Draw(body)
    bd.rounded_rectangle((0, 0, dw - 1, dh - 1), radius=r + bez, fill=ti)
    bd.rounded_rectangle((5, 5, dw - 6, dh - 6), radius=r + bez - 5, fill=(28, 28, 31, 255))
    bd.rounded_rectangle((9, 9, dw - 10, dh - 10), radius=r + bez - 9, fill=(4, 4, 5, 255))
    m = Image.new("L", (pw, ph), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, pw - 1, ph - 1), radius=r, fill=255)
    body.paste(shot, (bez, bez), m)
    iw, ih = int(pw * 0.287), int(pw * 0.084)
    ix, iy = (dw - iw) // 2, bez + int(pw * 0.025)
    bd.rounded_rectangle((ix, iy, ix + iw, iy + ih), radius=ih // 2, fill=(0, 0, 0, 255), outline=(255, 255, 255, 38), width=2)
    sheen = Image.new("RGBA", (dw, dh), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).rounded_rectangle((bez, bez, dw - bez, dh - bez), radius=r, outline=(255, 255, 255, 26), width=3)
    body.alpha_composite(sheen)
    dev.alpha_composite(body, (pad, 0))
    return dev


def place(canvas, path, pw, center, angle, tone="natural"):
    dev = device(path, pw, tone).rotate(angle, resample=Image.BICUBIC, expand=True)
    x, y = int(center[0] - dev.width / 2), int(center[1] - dev.height / 2)
    m = 160
    patch = Image.new("RGBA", (dev.width + 2 * m, dev.height + 2 * m), (0, 0, 0, 0))
    a = dev.split()[3].point(lambda v: int(v * 0.7))
    blk = Image.new("RGBA", dev.size, (0, 0, 0, 255))
    blk.putalpha(a)
    patch.alpha_composite(blk, (m + 20, m + 60))
    patch = patch.filter(ImageFilter.GaussianBlur(55))
    canvas.alpha_composite(patch, (x - m, y - m))
    canvas.alpha_composite(dev, (x, y))


def sans(size, weight="Semibold"):
    if LANG in SANS:
        path, idx = SANS[LANG]
        return ImageFont.truetype(path, size, index=idx)
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    f.set_variation_by_name(weight)
    return f


TINTS = {
    "blue": ((24, 33, 50, 238), (96, 130, 180, 105), (130, 168, 220, 255), (170, 188, 215, 190)),
    "green": ((24, 40, 34, 238), (100, 160, 130, 105), (132, 196, 160, 255), (172, 205, 188, 190)),
    "purple": ((36, 30, 52, 238), (140, 120, 190, 105), (170, 150, 215, 255), (192, 182, 215, 190)),
    "orange": ((50, 38, 26, 238), (190, 140, 90, 105), (215, 170, 120, 255), (222, 200, 175, 190)),
    "pink": ((50, 28, 40, 238), (190, 110, 150, 105), (214, 140, 176, 255), (222, 184, 204, 190)),
    "teal": ((22, 42, 46, 238), (100, 160, 168, 105), (130, 190, 198, 255), (176, 206, 210, 190)),
}
_tint_cycle = [0]


def chip(canvas, xy, title, sub=None, dot=None, angle=0, scale=1.0, icon=None, tint=None):
    """A floating card: outlined, never filled solid, with the state dot the app uses."""
    names = list(TINTS)
    if tint is None:
        tint = names[_tint_cycle[0] % len(names)]
        _tint_cycle[0] += 1
    fill_c, line_c, icon_c, sub_c = TINTS[tint]
    ts, ss = int(46 * scale), int(34 * scale)
    tf, sf = sans(ts, "Bold"), sans(ss, "Medium")
    pad = int(34 * scale)
    dd = int(22 * scale) if dot else 0
    isz = int(ts * 1.05) if icon else 0
    tw = tf.getlength(title) + (dd + int(18 * scale) if dot else 0) + (isz + int(20 * scale) if icon else 0)
    sw = sf.getlength(sub) if sub else 0
    w = int(max(tw, sw) + 2 * pad)
    h = int(2 * pad + ts * 1.15 + (ss * 1.25 + 8 if sub else 0))
    S = 2
    card = Image.new("RGBA", (w * S, h * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(card)
    d.rounded_rectangle((0, 0, w * S - 1, h * S - 1), radius=int(h * 0.30) * S, fill=fill_c, outline=line_c, width=2 * S)
    card = card.resize((w, h), Image.LANCZOS)
    d = ImageDraw.Draw(card)
    x = pad
    if dot:
        cy = pad + int(ts * 0.58)
        d.ellipse((x, cy - dd // 2, x + dd, cy + dd // 2), fill=dot)
        x += dd + int(18 * scale)
    if icon:
        sym = Image.open(f"{HERE}/assets/sym/{icon}.png").convert("RGBA")
        k = isz / max(sym.size)
        sym = sym.resize((max(1, int(sym.width * k)), max(1, int(sym.height * k))), Image.LANCZOS)
        tint_img = Image.new("RGBA", sym.size, icon_c)
        tint_img.putalpha(sym.split()[3])
        sym = tint_img
        card.alpha_composite(sym, (x, pad + int(ts * 0.58) - sym.height // 2 + 2))
        x += isz + int(20 * scale)
    d.text((x, pad), title, font=tf, fill=(255, 255, 255, 255))
    if sub:
        d.text((pad, pad + int(ts * 1.15) + 8), sub, font=sf, fill=sub_c)
    card = card.rotate(angle, resample=Image.BICUBIC, expand=True)
    m = 90
    patch = Image.new("RGBA", (card.width + 2 * m, card.height + 2 * m), (0, 0, 0, 0))
    a = card.split()[3].point(lambda v: int(v * 0.6))
    blk = Image.new("RGBA", card.size, (0, 0, 0, 255))
    blk.putalpha(a)
    patch.alpha_composite(blk, (m + 6, m + 22))
    patch = patch.filter(ImageFilter.GaussianBlur(26))
    canvas.alpha_composite(patch, (xy[0] - m, xy[1] - m))
    canvas.alpha_composite(card, xy)
    return card.size


def chip_width(title, scale, sub=None, dot=None, icon=None):
    tf = sans(int(46 * scale), "Bold")
    pad = int(34 * scale)
    extra = (int(22 * scale) + int(18 * scale)) if dot else 0
    if icon:
        extra += int(46 * scale * 1.05) + int(20 * scale)
    return int(tf.getlength(title) + extra + 2 * pad)


def band(canvas, idx, ya, yb, a, b, icons=(None, None), scale=1.75, ang=3, left_b=False):
    """One chip under the headline on the left, the other lower down against the opposite margin."""
    sa = sb = scale
    while chip_width(a, sa, icon=icons[0]) > W - 140 and sa > 0.9:
        sa -= 0.05
    while chip_width(b, sb, icon=icons[1]) > W - 140 and sb > 0.9:
        sb -= 0.05
    chip(canvas, (idx * W + 70, ya), a, angle=-ang, scale=sa, icon=icons[0])
    bx = idx * W + (70 if left_b else W - 70 - chip_width(b, sb, icon=icons[1]))
    chip(canvas, (bx, yb), b, angle=ang, scale=sb, icon=icons[1])


def callout(canvas, path, box, scale, xy, angle=0, radius=64):
    c = Image.open(path).convert("RGB").crop(box)
    c = c.resize((int(c.width * scale), int(c.height * scale)), Image.LANCZOS)
    S = 2
    m = Image.new("L", (c.width * S, c.height * S), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, c.width * S - 1, c.height * S - 1), radius=radius * S, fill=255)
    m = m.resize(c.size, Image.LANCZOS)
    card = Image.new("RGBA", c.size, (0, 0, 0, 0))
    card.paste(c, (0, 0), m)
    ring = Image.new("L", (c.width * S, c.height * S), 0)
    ImageDraw.Draw(ring).rounded_rectangle((0, 0, c.width * S - 1, c.height * S - 1), radius=radius * S, outline=255, width=3 * S)
    ring = ring.resize(c.size, Image.LANCZOS).point(lambda v: int(v * 0.35))
    white = Image.new("RGBA", c.size, (255, 255, 255, 255))
    white.putalpha(ring)
    card.alpha_composite(white)
    card = card.rotate(angle, resample=Image.BICUBIC, expand=True)
    mg = 120
    patch = Image.new("RGBA", (card.width + 2 * mg, card.height + 2 * mg), (0, 0, 0, 0))
    a = card.split()[3].point(lambda v: int(v * 0.7))
    blk = Image.new("RGBA", card.size, (0, 0, 0, 255))
    blk.putalpha(a)
    patch.alpha_composite(blk, (mg + 10, mg + 40))
    patch = patch.filter(ImageFilter.GaussianBlur(40))
    canvas.alpha_composite(patch, (xy[0] - mg, xy[1] - mg))
    canvas.alpha_composite(card, xy)


GREEN = (48, 209, 88, 255)
BLUE = (10, 132, 255, 255)


def background(centers):
    y = np.linspace(0, 1, H)[:, None, None]
    base = np.array(BG_TOP) * (1 - y) + np.array(BG_BOT) * y
    img = np.repeat(base, PW, axis=1)
    xx, yy = np.arange(PW)[None, :], np.arange(H)[:, None]
    for cx in centers:
        img += np.exp(-(((xx - cx) / 760.0) ** 2 + ((yy - 1850) / 1150.0) ** 2))[..., None] * np.array([20, 20, 22])
    # faint grid, fading out toward the bottom where the phones are
    step = 120
    grid = np.zeros((H, PW), dtype="float")
    grid[:, ::step] = 1
    grid[::step, :] = 1
    grid *= np.linspace(1.0, 0.55, H)[:, None]
    img += grid[..., None] * 30
    # a soft halo behind each phone, wider and brighter than the old glow
    for cx in centers:
        img += np.exp(-(((xx - cx) / 520.0) ** 2 + ((yy - 1750) / 900.0) ** 2))[..., None] * np.array([52, 54, 64])
    img += rng.normal(0, 1.8, (H, PW, 1))
    return Image.fromarray(np.clip(img, 0, 255).astype("uint8")).convert("RGBA")


def lockscreen(lang, copy, out):
    cat = json.load(open(f"{HERE}/../../Peering/Localizable.xcstrings"))["strings"]
    title = lambda k: k if lang == "en" else cat[k]["localizations"][lang]["stringUnit"]["value"]
    S = 2
    wp = Image.open(f"{HERE}/assets/wp_45.png").convert("RGB")
    sc = H / wp.height
    wp = wp.resize((int(wp.width * sc), H), Image.LANCZOS)
    x0 = int(wp.width * 0.40)
    c = wp.crop((x0, 0, x0 + W, H)).convert("RGBA")
    shade = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shade)
    for yy in range(H):
        a_ = int(150 * (yy / H) ** 1.6)
        sd.line((0, yy, W, yy), fill=(0, 0, 8, a_))
    c.alpha_composite(shade)
    d = ImageDraw.Draw(c)
    d.text((W / 2, 250), copy["date"], font=sans(58, "Semibold"), fill=(255, 255, 255, 215), anchor="mm")
    d.text((W / 2, 480), "9:41", font=sans(400, "Light"), fill=(255, 255, 255, 245), anchor="mm")
    icon = Image.open(f"{HERE}/../../Peering/Assets.xcassets/AppIcon.appiconset/AppIcon-dark.png").convert("RGB").resize((116, 116), Image.LANCZOS)
    mk = Image.new("L", (116 * S, 116 * S), 0)
    ImageDraw.Draw(mk).rounded_rectangle((0, 0, 116 * S - 1, 116 * S - 1), radius=27 * S, fill=255)
    mk = mk.resize((116, 116), Image.LANCZOS)
    tf, bf, nf = sans(52, "Semibold"), sans(48, "Regular"), sans(40, "Regular")

    def wrap(text, f, maxw):
        sep = " " if " " in text else ""
        words = text.split(" ") if sep else list(text)
        lines, cur = [], ""
        for wd in words:
            t = (cur + sep + wd) if cur else wd
            if f.getlength(t) <= maxw:
                cur = t
            else:
                lines.append(cur)
                cur = wd
        return lines + [cur]

    cards = []

    def card(y0, ttl, body):
        x, w, h = 60, W - 120, 292
        layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        ld.rounded_rectangle((0, 0, w - 1, h - 1), radius=64, fill=(44, 46, 60, 215), outline=(255, 255, 255, 38), width=2)
        layer.paste(icon, (36, 40), mk)
        ld.text((180, 38), ttl, font=tf, fill=(255, 255, 255, 255))
        for li, ln in enumerate(wrap(body, bf, w - 220)[:2]):
            ld.text((180, 112 + li * 60), ln, font=bf, fill=(255, 255, 255, 220))
        ld.text((w - 40, 44), copy["now"], font=nf, fill=(255, 255, 255, 150), anchor="ra")
        c.alpha_composite(layer, (x, y0))
        cards.append(layer)

    mac = "Damian\u2019s MacBook Pro: "
    card(1840, title("Terminal needs you"), mac + copy["n1"])
    card(1840 + 322, title("Terminal finished"), mac + copy["n2"])
    for cx in (170, W - 170):
        circ = Image.new("RGBA", (176, 176), (0, 0, 0, 0))
        cd = ImageDraw.Draw(circ)
        cd.ellipse((0, 0, 175, 175), fill=(30, 32, 44, 190), outline=(255, 255, 255, 40), width=2)
        c.alpha_composite(circ, (cx - 88, 2600))
    d = ImageDraw.Draw(c)
    d.rounded_rectangle((W / 2 - 220, 2790, W / 2 + 220, 2800), radius=5, fill=(255, 255, 255, 200))
    c.convert("RGB").save(out)
    cards[0].save(out.replace("07-lock", "07-card"))


BOTTOM = {2, 4, 6}
BOTTOM_CY = {2: 905, 4: 760, 6: 1480}


def lift_pictures(raw_dir):
    """Fills the empty black under the session pill with the Mac's picture, scaled to cover.

    The picture is cropped from 02-session and scaled up like resizeMode cover (sides cut, no
    stretching). 02-session gets it just under the pill. 03-keyboard gets it from the same crop,
    ending where the key panel starts, because the keyboard hides most of the original."""
    import numpy as np
    ses = Image.open(f"{raw_dir}/02-session.png").convert("RGB")
    rows = np.asarray(ses.convert("L")).astype(float).mean(axis=1)
    ys = [y for y in range(800, 2100) if rows[y] > 6]
    top, bottom = ys[0], ys[-1] + 1
    pic = ses.crop((0, top, ses.width, bottom))

    def cover(height):
        k = height / pic.height
        big = pic.resize((round(pic.width * k), height), Image.LANCZOS)
        x = (big.width - ses.width) // 2
        return big.crop((x, 0, x + ses.width, height))

    pill_bottom, panel_top = 400, 1396
    a = ses.copy()
    a.paste(Image.new("RGB", pic.size, (0, 0, 0)), (0, top))
    a.paste(cover(1260), (0, pill_bottom))
    a.save(f"{raw_dir}/_lift-02-session.png")

    # Keyboard: the picture keeps its size and the panel and keys move up under it. The height that
    # frees at the bottom is made up by stretching the empty band between the last key row and the
    # globe row, which is plain keyboard background.
    kb = Image.open(f"{raw_dir}/03-keyboard.png").convert("RGB")
    drop = panel_top - (pill_bottom + pic.height)
    band0, band1 = 2630, 2680
    b = Image.new("RGB", kb.size, (0, 0, 0))
    b.paste(kb.crop((0, 0, kb.width, 380)), (0, 0))
    b.paste(pic, (0, pill_bottom))
    y = pill_bottom + pic.height
    b.paste(kb.crop((0, panel_top, kb.width, band0)), (0, y))
    y += band0 - panel_top
    stretched = kb.crop((0, band0, kb.width, band1)).resize((kb.width, band1 - band0 + drop), Image.BICUBIC)
    b.paste(stretched, (0, y))
    y += stretched.height
    b.paste(kb.crop((0, band1, kb.width, kb.height)), (0, y))
    b.save(f"{raw_dir}/_lift-03-keyboard.png")


def build(lang):
    global LANG, CARD_TOP, CARD_H
    LANG = lang
    # English shows two separate cards; the other languages' real lock screens collapse the older one behind the newer.
    CARD_TOP, CARD_H = (1946, 488) if lang == "en" else (2085, 352)
    copy = json.load(open(f"{HERE}/copy.json"))[lang]
    r = lambda n: f"{HERE}/raw/{lang}/{n}.png"
    out = f"{HERE}/out/{lang}"
    os.makedirs(out, exist_ok=True)
    n = 7
    lift_pictures(f"{HERE}/raw/{lang}")
    if not os.path.exists(r("07-lock")):
        lockscreen(lang, copy, r("07-lock"))
    else:
        Image.open(r("07-lock")).crop((58, CARD_TOP, 1262, CARD_TOP + CARD_H)).save(r("07-card"))
    pw = W * n
    global PW
    PW = pw
    P = background([W, 2 * W + 660, 3 * W + 640, 4 * W + 660, 5 * W + 660, 6 * W + 660])
    h0 = copy["h"]
    heads = h0[:2] + [h0[6], h0[2]] + h0[3:6]
    big = fit(heads[:2], 340)
    sizes = [big, fit([heads[1]], 520, 1090)] + [fit([t], 400, 1190) for t in heads[2:]]
    small = sizes[2]
    sizes[1] = min(fit([heads[1]], 400, 1090), sorted(sizes[2:])[len(sizes[2:]) // 2])
    # The emoji chip sits at y=740 under this headline, so a short two-line headline (CJK) must not outgrow it.
    while sizes[5] * 1.3 * (heads[5].count("\n") + 1) > 590:
        sizes[5] -= 4
    print(lang, "sizes", sizes)
    for i, t in enumerate(heads):
        hy = 120
        if i in BOTTOM:
            lines = t.count("\n") + 1
            hy = H - 160 - int(sizes[i] * 1.26 * lines)
        if i == 1:
            continue
        else:
            headline(P, t, (i * W + 80, hy), sizes[i])
    place(P, r("_lift-02-session"), 1440, (W, 2800), -6)
    # name, angle, phone width, centre x within the canvas, centre y
    layout = [("07-lock", 0, 1200, 660, 905), ("06-agents", 0, 1180, 640, 2204), ("04-shortcuts", 0, 1180, 680, 2220),
              ("_lift-03-keyboard", -3, 1120, 650, 2300), ("01-connect", 5, 1110, 680, 2380)]
    for i, (name, ang, pw_, cx, cy) in enumerate(layout, start=2):
        if i in BOTTOM:
            cy = BOTTOM_CY[i]
        place(P, r(name), pw_, (i * W + cx, cy), ang)
    for i in BOTTOM:
        fade = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        fd = ImageDraw.Draw(fade)
        f0 = {2: 1870, 4: 2080}.get(i, 1750)
        for yy in range(f0, H):
            a_ = min(250, int(250 * (yy - f0) / 450))
            fd.line((0, yy, W, yy), fill=(11, 11, 13, a_))
        P.alpha_composite(fade, (i * W, 0))
    import numpy as np
    fx0, fy0 = W - 250, 1900
    ys = np.clip((np.arange(H) - fy0) / 600, 0, 1)[:, None]
    xs = np.clip(np.arange(W + 250) / 500, 0, 1)[None, :]
    fade = Image.new("RGBA", (W + 250, H), (11, 11, 13, 0))
    fade.putalpha(Image.fromarray((95 * ys * xs).astype("uint8")))
    P.alpha_composite(fade, (fx0, 0))
    t = heads[1]
    lines = t.count("\n") + 1
    headline(P, t, (W, H - 160 - int(sizes[1] * 1.26 * lines)), sizes[1], right=2 * W - 40)
    for i in BOTTOM:
        t = heads[i]
        lines = t.count("\n") + 1
        headline(P, t, (i * W + 80, H - 160 - int(sizes[i] * 1.26 * lines)), sizes[i])
    b = copy["b"]
    x = copy["x"]

    def put(idx, y, text, scale, icon, side="left", ang=3, sub=None, tint="blue"):
        sc = scale
        while chip_width(text, sc, icon=icon) > W - 140 and sc > 0.9:
            sc -= 0.05
        w_ = chip_width(text, sc, icon=icon)
        cx = idx * W + (70 if side == "left" else W - 70 - w_)
        chip(P, (cx, y), text, angle=ang if side == "right" else -ang, scale=sc, icon=icon, sub=sub, tint=tint)

    # size follows importance: the first chip on a canvas is the headline feature
    sc_l = 2.05
    cx_l = W - chip_width(b[0], sc_l, icon="laptopcomputer") // 2
    chip(P, (cx_l, 800), b[0], angle=-3, scale=sc_l, icon="laptopcomputer", tint="green")
    put(0, 1500, b[1], 1.7, "bolt.fill", "left", tint="green")
    chip(P, (W + 80, 260), copy["e2e"], sub=copy["e2e_sub"], angle=-3, scale=1.75, icon="lock.fill", tint="purple")
    put(3, 640, b[4], 2.0, "desktopcomputer")
    put(2, 760, b[13], 2.0, "bell.badge")
    put(4, 140, b[6], 2.0, "square.grid.2x2")
    put(5, 740, b[8], 1.9, "face.smiling")
    put(6, 40, b[10], 1.9, "person.crop.circle.badge.xmark", tint="purple")
    # popover: the two real notifications, redrawn slightly larger and centred exactly over the ones in the phone
    lock_i, lock_pw, lock_cx, lock_cy = 2, 1200, 660, 905
    k = lock_pw / W
    bez_ = max(int(lock_pw * 0.019), 14)
    pad_ = int(lock_pw * 0.012)
    dev_w = lock_pw + 2 * bez_ + 2 * pad_
    dev_h = int(H * k) + 2 * bez_
    nx = lock_i * W + lock_cx - dev_w // 2 + pad_ + bez_ + int(58 * k)
    ny = lock_cy - dev_h // 2 + bez_ + int(CARD_TOP * k)
    zoom = 1.2
    cw, ch = int(1204 * k * zoom), int(CARD_H * k * zoom)
    ccx, ccy = nx + int(1204 * k) // 2, ny + int(CARD_H * k) // 2
    callout(P, r("07-card"), (0, 0, 1204, CARD_H), k * zoom, (ccx - cw // 2, ccy - ch // 2), angle=0, radius=int(60 * k * zoom))
    order = [0, 1, 2, 3, 4, 5, 6]
    for new_i, old_i in enumerate(order, start=1):
        P.crop((old_i * W, 0, (old_i + 1) * W, H)).convert("RGB").save(f"{out}/0{new_i}.png")
    strip = Image.new("RGB", (W * 7, H))
    for new_i, old_i in enumerate(order):
        strip.paste(P.crop((old_i * W, 0, (old_i + 1) * W, H)).convert("RGB"), (new_i * W, 0))
    P = strip.convert("RGBA")
    P.convert("RGB").resize((pw // 3, H // 3), Image.LANCZOS).save(f"{out}/_strip.png")


if __name__ == "__main__":
    for lang in sys.argv[1:]:
        build(lang)
