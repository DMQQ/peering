import json
import re

SZ = json.load(open("video_assets/sizes.json"))


def head(text, size, cls="", top=None):
    html = re.sub(r"\*(.+?)\*", r"<em>\1</em>", text).replace("|", "<br>")
    pos = "" if top is None else ";top:%dpx" % top
    return f'<h1 class="hd {cls}" data-split style="font-size:{size}px{pos}">{html}</h1>'


def chip(name, x, y, d, ph=0):
    return (f'<img class="ci" src="video_assets/{name}.png" data-d="{d}" data-ph="{ph}" '
            f'style="position:absolute;left:{x}px;top:{y}px;z-index:6">')


def right(name, margin=-20):
    return 1080 - SZ[name]["w"] - margin


def phone(name, dev_top, rot=0, extra=""):
    s = SZ[name]
    left = (1080 - s["w"]) // 2
    return (f'<div class="ph" data-rot="{rot}" style="position:absolute;left:{left}px;top:{dev_top - s["m"]}px;'
            f'width:{s["w"]}px;height:{s["h"]}px;perspective:1400px;z-index:2">'
            f'<div style="position:relative;width:100%;height:100%;transform-style:preserve-3d">'
            f'<img src="video_assets/{name}.png" style="width:100%;height:100%;display:block">{extra}</div></div>')


def ring_on(name, fx, fy):
    s = SZ[name]
    x = s["m"] + s["pad"] + s["bez"] + fx * s["pw"]
    y = s["m"] + s["bez"] + fy * s["shot_h"]
    return (f'<div id="ring" style="position:absolute;left:{x:.0f}px;top:{y:.0f}px;width:76px;height:76px;'
            f'margin:-38px 0 0 -38px;border-radius:50%;border:5px solid #fff;opacity:0;z-index:5"></div>')


fade = '<div class="fade"></div>'
slides = []

slides.append(f'''<section class="slide" id="s1">
  {head("That's my *Mac*.|I'm not *home*.", 118)}
  {phone("ph_session", 640)}
  {fade}
  {chip("c_conn", right("c_conn", 20), 520, 1.0, 0)}
  {chip("c_any", -10, 940, 1.4, 2)}
</section>''')

slides.append(f'''<section class="slide" id="s2">
  {head("Start agents|in *one tap*.", 118)}
  {phone("ph_agents", 600, 0, ring_on("ph_agents", 0.857, 0.328 * 0.97))}
  {fade}
  {chip("c_runs", right("c_runs", 10), 470, 1.9, 1)}
</section>''')

slides.append(f'''<section class="slide" id="s3">
  {head("The Mac|*keeps going*|while you don't.", 112)}
  {chip("c_lid", -10, 560, 0.9, 0)}
  {chip("c_awake", right("c_awake", -10), 830, 1.15, 1)}
  {chip("c_wol", 30, 1090, 1.4, 2)}
</section>''')

slides.append(f'''<section class="slide" id="s4">
  {head("Auto mode can't|type my *password*.", 100)}
  <div class="card blk" style="left:80px;right:80px;top:520px;padding:38px 42px;height:210px"><div class="term"><div><span class="p">$</span> <span id="cmd"></span></div><div class="warn" id="pw" style="visibility:hidden">Password: <span id="dots"></span><span class="cursor" id="cur" style="margin-left:6px"></span></div><div class="ok" id="okline" style="visibility:hidden">✓ added 1 package in 2s</div></div></div>
  {chip("c_kb", right("c_kb", 20), 800, 1.6, 0)}
  {chip("c_e2e", 20, 1060, 1.9, 1)}
</section>''')

LK = SZ["ph_lock"]
LK_TOP = -250
KL = LK["pw"] / 1320
card_cx = (1080 - LK["w"]) // 2 + LK["m"] + LK["pad"] + LK["bez"] + (58 + 602) * KL
card_cy = LK_TOP + LK["bez"] + (1946 + 244) * KL
slides.append(f'''<section class="slide" id="s5">
  {phone("ph_lock", LK_TOP)}
  {fade}
  {head("Then get back|to your *day*.", 104, top=1030)}
  {chip("c_alert", 0, 90, 1.1, 0)}
  {chip("n_card", int(card_cx - SZ["n_card"]["w"] / 2), int(card_cy - SZ["n_card"]["h"] / 2), 1.5, 1)}
</section>''')

slides.append(f'''<section class="slide" id="s6">
  <img id="pears" src="img/pears.png" alt="" style="position:absolute;left:455px;top:150px;width:170px;z-index:5">
  {head("I built it.|It's called *Peering*.", 110, "c", 400)}
  <div id="btn" style="position:absolute;left:0;right:0;margin:0 auto;top:790px;width:fit-content;padding:28px 56px;border-radius:999px;background:#fff;color:#000;font-size:38px;font-weight:600;letter-spacing:-.3px;z-index:5">getpeering.app</div>
  {chip("c_noacct", 60, 930, 2.0, 0)}
  {chip("c_free", right("c_free", 0), 1110, 2.3, 1)}
</section>''')

html = open("video.tpl.html").read().replace("<!--SLIDES-->", "\n".join(slides))
open("video.html", "w").write(html)
