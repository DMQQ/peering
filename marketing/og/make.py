"""Draws the link preview images (Open Graph / Twitter, 1200x630) for getpeering.app into relay/site/assets/og/.

Each card is an HTML page rendered by headless Chrome. The Android phone, its screens and the page CSS come from
marketing/appstore/android/make.py; the iPhone and iPad screens are the App Store raw captures.

    python3 marketing/og/make.py           # every card
    python3 marketing/og/make.py home ipad # only these
"""
import html, importlib.util, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "relay", "site", "assets", "og")
BUILD = os.path.join(HERE, "build")
W, H = 1200, 630

_argv, sys.argv = sys.argv, ["make.py"]
_spec = importlib.util.spec_from_file_location("android_make", os.path.join(ROOT, "marketing/appstore/android/make.py"))
A = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(A)
sys.argv = _argv

def url(*p):
    return "file://" + os.path.join(ROOT, *p)

IOS = lambda n: url("marketing/appstore/raw/en", n)
IPAD = lambda n: url("marketing/RawScreenshots/iPad", n)
MAC_SCREEN = url("marketing/appstore/android/assets/mac.png")
PEARS = url("relay/site/assets/pears.png")

CSS = """
.og-h { position:absolute; left:50%; transform:translateX(-50%); top:58px; width:640px; text-align:center;
  font-family:NY, ui-serif, 'Hiragino Mincho ProN', 'Songti SC', AppleMyungjo, serif; font-weight:800;
  font-variation-settings:'wght' 800; font-size:58px; line-height:1.08; letter-spacing:-.5px; color:#fff; z-index:9; }
.og-h em { font-style:normal; color:var(--blue); }
.brand { position:absolute; left:36px; top:30px; display:flex; align-items:center; gap:10px; z-index:9;
  font-family:-apple-system, 'SF Pro Text', sans-serif; font-size:19px; font-weight:600; color:rgba(255,255,255,.86); }
.brand img { width:30px; height:30px; }
.domain { position:absolute; right:36px; top:34px; z-index:9; font-family:-apple-system, sans-serif; font-size:17px;
  color:rgba(255,255,255,.55); }
.laptop { position:absolute; }
.laptop .lid { border-radius:18px 18px 4px 4px; background:#0c0c0e; border:2px solid #3a3a3e; padding:12px 12px 16px; }
.laptop .lid img { display:block; width:100%; border-radius:4px; }
.laptop .base { height:14px; margin:0 -46px; border-radius:0 0 16px 16px; background:linear-gradient(#5a5a5f,#2a2a2d); }
.iph { position:absolute; border-radius:44px; padding:8px; background:#1b1b1d; border:2px solid #45454a;
  box-shadow:0 30px 60px rgba(0,0,0,.6); }
.iph img { display:block; width:100%; border-radius:36px; }
.tab { position:absolute; border-radius:30px; padding:12px; background:#151517; border:2px solid #45454a;
  box-shadow:0 30px 60px rgba(0,0,0,.6); }
.tab img { display:block; width:100%; border-radius:18px; }
.vs { position:absolute; left:0; right:0; top:262px; display:flex; justify-content:center; align-items:center; gap:22px; }
.vcard { width:300px; height:190px; border:1.5px solid var(--outline); border-radius:28px; display:flex; flex-direction:column;
  align-items:center; justify-content:center; gap:14px; font-family:NY, serif; font-weight:700; font-size:34px; text-align:center; padding:0 18px; }
.vcard.us { border-color:rgba(255,255,255,.7); }
.vcard small { font-family:-apple-system, sans-serif; font-weight:500; font-size:17px; color:var(--muted); }
.vcard img { width:52px; height:52px; }
.vword { font-family:NY, serif; font-style:italic; font-size:30px; color:var(--muted); }
.pill2 { position:absolute; z-index:8; display:flex; align-items:center; gap:10px; padding:12px 20px; border-radius:22px;
  border:1px solid var(--outline); background:#141416; font-family:Roboto, sans-serif; font-size:19px; font-weight:500; }
.pill2 .ms { color:var(--blue); font-size:24px; }
.win { position:absolute; }
.win .scr { border:10px solid #111113; outline:2px solid #3a3a3e; border-radius:14px; height:300px; position:relative; overflow:hidden;
  background:radial-gradient(ellipse at 40% 110%, #1d3f73 0%, #0d1a33 45%, #08090d 80%); }
.win .bar { position:absolute; left:0; right:0; bottom:0; height:30px; background:rgba(20,20,24,.92); display:flex; gap:7px;
  justify-content:center; align-items:center; }
.win .bar i { width:16px; height:16px; border-radius:4px; background:rgba(255,255,255,.35); }
.win .bar i:first-child { background:#0A84FF; }
.win .w1 { position:absolute; left:40px; top:30px; width:300px; height:190px; border-radius:8px; background:#1c1c20; border:1px solid #333; }
.win .w2 { position:absolute; left:220px; top:70px; width:250px; height:170px; border-radius:8px; background:#24242a; border:1px solid #3a3a40; }
.win .neck { width:60px; height:34px; margin:0 auto; background:linear-gradient(#3a3a3e,#232326); }
.win .foot { width:200px; height:10px; margin:0 auto; border-radius:6px; background:#3a3a3e; }
"""


def headline(text):
    return f'<div class="og-h">{A.headline(text)}</div>'


def chrome():
    return (f'<div class="brand"><img src="{PEARS}">Peering</div><div class="domain">getpeering.app</div>'
            '<div class="glow" style="left:150px;top:260px;width:900px;height:500px"></div>')


def laptop(left, top, width, src=MAC_SCREEN):
    return f'<div class="laptop" style="left:{left}px;top:{top}px;width:{width}px"><div class="lid"><img src="{src}"></div><div class="base"></div></div>'


def iphone(left, top, width, shot):
    return f'<div class="iph" style="left:{left}px;top:{top}px;width:{width}px;z-index:5"><img src="{IOS(shot)}"></div>'


def android(left, top, zoom, screen=None):
    return f'<div style="position:absolute;inset:0;z-index:6">{A.phone(screen or A.screen_remote(), left, top, zoom)}</div>'


def tablet(left, top, width, shot):
    return f'<div class="tab" style="left:{left}px;top:{top}px;width:{width}px"><img src="{IPAD(shot)}"></div>'


def pill(text, ic, left, top):
    return f'<div class="pill2" style="left:{left}px;top:{top}px">{A.icon(ic, "fill")}{html.escape(text)}</div>'


def versus(*names):
    cards = []
    for n in names:
        if n == "Peering":
            cards.append(f'<div class="vcard us"><img src="{PEARS}">Peering<small>Mac, iPhone, iPad, Android</small></div>')
        else:
            cards.append(f'<div class="vcard">{html.escape(n)}</div>')
    gap = '<span class="vword">vs</span>'
    if len(names) > 2:
        w = 1080 // len(names) - 30
        return '<div class="vs">' + "".join(c.replace('class="vcard', f'style="width:{w}px" class="vcard') for c in cards) + '</div>'
    return f'<div class="vs">{cards[0]}{gap}{cards[1]}</div>'


def windows(left, top, width):
    return (f'<div class="win" style="left:{left}px;top:{top}px;width:{width}px"><div class="scr"><div class="w1"></div>'
            f'<div class="w2"></div><div class="bar"><i></i><i></i><i></i><i></i><i></i></div></div><div class="neck"></div><div class="foot"></div></div>')


# Visual scenes. Devices sit below y≈240 so the headline above stays clear; the bottom edge may crop them.
def v_home():
    return laptop(330, 250, 540) + iphone(230, 300, 170, "02-session.png") + android(800, 290, 0.42)


def v_mac():
    return laptop(300, 250, 560) + iphone(780, 270, 170, "02-session.png")


def v_pair():
    return laptop(240, 260, 520) + iphone(800, 250, 175, "01-connect.png")


def v_awake():
    return laptop(320, 255, 560) + iphone(210, 290, 165, "02-session.png") + pill("Works with the lid closed", "laptop_mac", 740, 420)


def v_ipad():
    return tablet(290, 250, 560, "mosaic-four-windows.png") + iphone(820, 300, 160, "02-session.png")


def v_android_tablet():
    return tablet(290, 250, 560, "mosaic-four-windows.png") + android(830, 300, 0.4)


def v_android():
    return laptop(300, 270, 520) + android(250, 265, 0.42) + android(780, 280, 0.42, A.screen_trackpad())


def v_agents():
    card = url("marketing/appstore/raw/en/07-card.png")
    return (android(220, 255, 0.42, A.screen_agents()) + f'<img src="{card}" style="position:absolute;left:420px;top:300px;width:420px;z-index:7;border-radius:24px">'
            + iphone(830, 270, 165, "06-agents.png"))


def v_android_keys():
    return laptop(300, 270, 520) + android(250, 265, 0.42, A.screen_keyboard()) + android(780, 280, 0.42)


def v_agents_android():
    return android(330, 250, 0.44, A.screen_agents()) + android(640, 240, 0.44, A.screen_shade())


def v_windows():
    return windows(330, 260, 540) + iphone(220, 320, 150, "02-session.png") + android(830, 300, 0.4) + pill("Windows beta", "desktop_windows", 520, 230)


def v_both_phones():
    return laptop(340, 265, 520) + iphone(210, 270, 180, "02-session.png") + android(810, 260, 0.46)


CARDS = {
    "home": ("Your computer,\nin your *pocket.*", v_home),
    "generic": ("Peering", v_home),
    "download": ("Get Peering for Mac, iPhone and Android.", v_home),
    "remote-desktop-for-mac": ("Control your Mac from your iPhone.", v_mac),
    "access-your-mac-from-anywhere": ("Your Mac, from anywhere.", v_mac),
    "how-to-pair-iphone-mac": ("Pair your iPhone and Mac in seconds.", v_pair),
    "mac": ("Add a Mac to Peering.", v_pair),
    "keep-mac-awake-for-remote-access": ("Keep your Mac awake, lid closed.", v_awake),
    "best-remote-desktop-app-for-ipad": ("Your Mac, on your iPad.", v_ipad),
    "coding-agent-notifications": ("Know when Claude Code needs you.", v_agents),
    "apple-remote-desktop-alternative": ("An Apple Remote Desktop alternative.", lambda: versus("Apple Remote Desktop", "Peering")),
    "apple-remote-desktop-vs-screen-sharing": ("Remote Desktop or Screen Sharing?", lambda: versus("Apple Remote Desktop", "Screen Sharing")),
    "remote-desktop-apps-compared": ("Remote desktop apps, compared.", lambda: versus("Peering", "Screens 5", "Jump Desktop", "RustDesk")),
    "rustdesk-alternative-for-mac": ("RustDesk, minus the server.", lambda: versus("RustDesk", "Peering")),
    "screens-alternative": ("A Screens alternative, with sound.", lambda: versus("Screens 5", "Peering")),
    "screens-vs-jump-desktop": ("Screens 5 or Jump Desktop?", lambda: versus("Screens 5", "Jump Desktop")),
    "chrome-remote-desktop-alternative": ("A Chrome Remote Desktop alternative.", lambda: versus("Chrome Remote Desktop", "Peering")),
    "teamviewer-alternative": ("A TeamViewer alternative.", lambda: versus("TeamViewer", "Peering")),
    "control-mac-from-android": ("Control your Mac from Android.", v_android),
    "remote-desktop-android-to-mac": ("Remote desktop from Android to Mac.", v_android_keys),
    "android-tablet-remote-desktop": ("Your Mac, on an Android tablet.", v_android_tablet),
    "claude-code-on-android": ("Claude Code, on your Android phone.", v_agents_android),
    "remote-desktop-windows-from-phone": ("Your Windows PC, on your phone.", v_windows),
    "android-vs-iphone": ("Android or iPhone, the same Mac.", v_both_phones),
}

HOME_I18N = {"de": "Dein Mac, von überall.", "es": "Tu Mac, desde cualquier lugar.", "fr": "Votre Mac, de n'importe où.",
             "it": "Il tuo Mac, ovunque.", "ja": "どこからでも、あなたのMacを。", "ko": "어디서든 내 Mac을.",
             "pt": "Seu Mac, de qualquer lugar.", "ru": "Ваш Mac, откуда угодно.", "zh": "你的 Mac，随时随地。"}
for _lang, _h in HOME_I18N.items():
    CARDS[f"home-{_lang}"] = (_h, v_home)


def render(name, title, scene):
    os.makedirs(BUILD, exist_ok=True)
    src = os.path.join(BUILD, f"{name}.html")
    big = "font-size:84px;top:70px" if title == "Peering" else ""
    head = headline(title).replace('class="og-h"', f'class="og-h" style="{big}"') if big else headline(title)
    page = A.page(chrome() + head + scene(), W, H).replace("</style>", CSS + "</style>", 1)
    open(src, "w").write(page)
    raw = os.path.join(BUILD, f"{name}.png")
    subprocess.run([A.CHROME, "--headless=new", "--hide-scrollbars", "--force-device-scale-factor=1", "--allow-file-access-from-files",
                    f"--window-size={W},{H}", "--virtual-time-budget=8000", f"--screenshot={raw}", "file://" + src],
                   check=True, capture_output=True)
    optimise(raw, os.path.join(OUT, f"{name}.png"))


def optimise(raw, out):
    from PIL import Image
    img = Image.open(raw).convert("RGB")
    for colours in (256, 192, 128):
        img.quantize(colours, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG).save(out, optimize=True)
        if os.path.getsize(out) < 300_000:
            return
    raise SystemExit(f"{out} is still {os.path.getsize(out)} bytes")


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in sys.argv[1:] or CARDS:
        render(name, *CARDS[name])
        print(name, os.path.getsize(os.path.join(OUT, f"{name}.png")))


if __name__ == "__main__":
    main()
