"""Draws the Google Play screenshots: each canvas is an HTML page (headline, badges and a Pixel-style phone whose
screen is painted from the Android app's Compose layout), rendered to PNG by headless Chrome.

    python3 make.py          # English, into out/en/
    python3 make.py de       # any language present in copy.json
"""
import html, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
LANG = sys.argv[1] if len(sys.argv) > 1 else "en"
C = json.load(open(os.path.join(HERE, "copy.json")))[LANG]
U, B = C["ui"], C["b"]
ASSETS = "file://" + os.path.join(HERE, "assets")


def e(s):
    return html.escape(s)


def headline(text):
    out = []
    for line in text.split("\n"):
        parts = re.split(r"\*(.+?)\*", e(line))
        out.append("".join(f'<em>{p}</em>' if i % 2 else p for i, p in enumerate(parts)))
    return "<br>".join(out)


def icon(name, cls=""):
    return f'<span class="ms {cls}">{name}</span>'


CSS = """
@font-face { font-family: NY; src: url(file:///System/Library/Fonts/NewYork.ttf); }
:root { --blue:#0A84FF; --ink:#fff; --muted:rgba(235,235,245,.6); --faint:rgba(255,255,255,.46);
  --hair:rgba(255,255,255,.08); --outline:rgba(255,255,255,.24); --sheet:#141416; --high:#1B1B1E; }
* { box-sizing:border-box; margin:0; padding:0; }
html,body { width:WPX; height:HPX; overflow:hidden; background:#0A0A0B; }
body { font-family:Roboto, sans-serif; color:#fff; position:relative;
  background:linear-gradient(#19191B, #080809); }
.grid { position:absolute; inset:0; background-image:linear-gradient(rgba(255,255,255,.035) 1px,transparent 1px),
  linear-gradient(90deg,rgba(255,255,255,.035) 1px,transparent 1px); background-size:60px 60px; }
.glow { position:absolute; width:900px; height:700px; border-radius:50%; filter:blur(120px);
  background:rgba(255,255,255,.07); }
h1 { position:absolute; left:64px; font-family:NY, serif; font-variation-settings:'wght' 800; font-weight:800;
  font-size:118px; line-height:1.12; letter-spacing:-1px; }
h1 em { font-style:normal; color:var(--blue); font-size:1.18em; }
.ms { font-family:'Material Symbols Rounded'; font-weight:normal; font-style:normal; line-height:1; display:inline-block;
  font-variation-settings:'FILL' 0,'wght' 400; -webkit-font-feature-settings:'liga'; }
.fill { font-variation-settings:'FILL' 1,'wght' 400; }
.badge { position:absolute; z-index:5; display:flex; align-items:center; gap:24px; padding:30px 40px; border-radius:36px;
  background:rgba(24,25,28,.94); border:1.5px solid rgba(255,255,255,.12); font-size:46px; font-weight:600;
  box-shadow:0 30px 70px rgba(0,0,0,.6); white-space:nowrap; }
.badge .ms { font-size:54px; color:var(--blue); }
/* phone, in dp, zoomed */
.phone { position:absolute; zoom:Z; width:432px; height:935px; border-radius:50px; padding:10px;
  background:#0d0d0e; border:2px solid #3a3a3e; box-shadow:0 0 0 1px #000, 0 50px 120px rgba(0,0,0,.7); }
.phone::before { content:''; position:absolute; right:-5px; top:190px; width:4px; height:60px; background:#2c2c2f; border-radius:2px; box-shadow:0 100px 0 #2c2c2f; }
.screen { position:relative; width:412px; height:915px; border-radius:40px; overflow:hidden; background:#000; }
.sb { position:absolute; top:0; left:0; right:0; height:40px; display:flex; align-items:center; padding:6px 26px 0;
  font-size:14px; font-weight:500; z-index:3; }
.sb .r { margin-left:auto; display:flex; gap:4px; } .sb .r .ms { font-size:17px; }
.hole { position:absolute; top:12px; left:50%; margin-left:-12px; width:24px; height:24px; border-radius:50%; background:#000;
  box-shadow:inset 0 0 0 3px #111, 0 0 0 1px #1a1a1a; z-index:4; }
.gbar { position:absolute; bottom:8px; left:50%; margin-left:-54px; width:108px; height:4px; border-radius:2px; background:#fff; opacity:.9; z-index:3; }
.round { width:48px; height:48px; border-radius:24px; border:1px solid var(--outline); display:flex; align-items:center; justify-content:center; background:#0f0f10; }
.round .ms { font-size:22px; }
.pill { flex:1; height:56px; border-radius:28px; border:1px solid var(--outline); background:#0f0f10; padding:7px 16px; position:relative; }
.pill .t { font-size:15px; font-weight:500; display:flex; align-items:center; gap:7px; }
.dot { width:7px; height:7px; border-radius:4px; background:#30D158; display:inline-block; }
.pill .s { font-size:12.5px; color:var(--muted); margin-top:3px; display:flex; align-items:center; gap:7px; }
.chip { font-size:10px; font-weight:700; letter-spacing:.8px; padding:2px 7px; border-radius:8px; background:rgba(255,255,255,.14); color:rgba(255,255,255,.75); }
.mac { position:absolute; left:0; width:412px; }
.ctrl { position:absolute; left:0; right:0; display:flex; align-items:center; justify-content:center; gap:14px; }
.circ { border-radius:50%; border:1px solid var(--outline); background:#0f0f10; display:flex; flex-direction:column; align-items:center; justify-content:center; font-size:12px; font-weight:500; }
.dock { position:absolute; left:14px; right:14px; height:76px; border-radius:35px; border:1px solid var(--outline); background:#0f0f10;
  display:flex; align-items:center; justify-content:space-around; padding:0 8px; }
.dock div { display:flex; flex-direction:column; align-items:center; gap:4px; font-size:11.5px; color:rgba(255,255,255,.85); }
.dock .ms { font-size:24px; }
.dots { position:absolute; left:0; right:0; display:flex; justify-content:center; gap:9px; }
.dots i { width:6px; height:6px; border-radius:3px; background:rgba(255,255,255,.3); } .dots i:first-child { background:#fff; }
.serif { font-family:'Source Serif 4', NY, serif; font-weight:700; }
.card { border:1px solid var(--outline); border-radius:28px; padding:16px; }
.lbl { font-size:13px; color:var(--muted); display:flex; align-items:center; gap:7px; margin:20px 4px 10px; font-weight:500; }
.lbl .ms { font-size:17px; }
.state { font-size:11px; padding:3px 9px; border-radius:10px; border:1px solid var(--outline); color:var(--muted); }
.key { height:42px; border-radius:7px; background:#2b2b2f; display:flex; align-items:center; justify-content:center; font-size:19px; flex:1; }
"""

FONTS = ('<link href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;600;700&family=Roboto+Mono:wght@400;500'
         '&family=Source+Serif+4:opsz,wght@8..60,700&family=Material+Symbols+Rounded:opsz,wght,FILL,GRAD@24,400,0..1,0" rel="stylesheet">')


def statusbar(light=True):
    return (f'<div class="hole"></div><div class="sb"><span>9:41</span><span class="r">{icon("wifi","fill")}'
            f'{icon("signal_cellular_alt","fill")}{icon("battery_full","fill")}</span></div>')


def topbar(chip="RELAY", y=46):
    return f'''<div style="position:absolute;top:{y}px;left:14px;right:14px;display:flex;gap:10px;align-items:center">
      <div class="round">{icon("lock","fill")}</div>
      <div class="pill"><div class="t"><span class="dot"></span>{e(U["host"])}</div>
        <div class="s">{e(U["doc"])}<span class="chip">{e(chip)}</span></div>
        <span class="ms" style="position:absolute;right:14px;top:17px;font-size:20px;color:var(--muted)">expand_more</span></div>
      <div class="round">{icon("terminal")}</div></div>'''


def mac(top):
    return f'<img class="mac" style="top:{top}px" src="{ASSETS}/mac.png">'


def remote_controls(top=640):
    return f'''<div class="ctrl" style="top:{top}px">
      <div style="width:54px;height:150px;border-radius:24px;border:1px solid var(--outline);display:flex;flex-direction:column;align-items:center;justify-content:space-between;padding:12px 0;margin-right:16px;background:#0f0f10">
        {icon("keyboard_arrow_up")}<div style="width:26px;height:70px;background:repeating-linear-gradient(transparent 0 9px,rgba(255,255,255,.5) 9px 10px)"></div>{icon("keyboard_arrow_down")}</div>
      <div class="circ" style="width:70px;height:70px">{icon("chevron_left")}{e(U["back"])}</div>
      <div class="circ" style="width:126px;height:126px"><div style="width:58px;height:58px;border-radius:50%;background:#e9e9ea"></div></div>
      <div class="circ" style="width:70px;height:70px">{icon("keyboard_return")}{e(U["enter"])}</div></div>'''


def dock(top=820, dots=True):
    items = [("select_window", U["apps"]), ("keyboard", U["keyboard"]), ("content_paste", U["clipboard"]),
             ("keyboard_command_key", U["shortcuts"]), ("keyboard_tab", U["tab"])]
    inner = "".join(f'<div>{icon(i)}<span>{e(t)}</span></div>' for i, t in items)
    d = f'<div class="dots" style="top:{top + 84}px"><i></i><i></i><i></i><i></i><i></i></div>' if dots else ""
    return f'<div class="dock" style="top:{top - 12}px">{inner}<div>{icon("expand_more")}</div></div>{d}'


def screen_remote(chip="RELAY"):
    return statusbar() + topbar(chip) + mac(250) + remote_controls(590) + dock(808) + '<div class="gbar"></div>'


def session_card(agent, title, folder, state, needs=False, glyph="auto_awesome"):
    st = f'<span class="state" style="{"color:#fff;border-color:var(--blue);background:rgba(10,132,255,.18)" if needs else ""}">{e(state)}</span>'
    return f'''<div class="card" style="margin-bottom:10px;display:flex;gap:12px;align-items:center">
      <div style="width:40px;height:40px;border-radius:12px;border:1px solid var(--outline);display:flex;align-items:center;justify-content:center">{icon(glyph)}</div>
      <div style="flex:1;min-width:0"><div style="font-size:15px;font-weight:500">{e(agent)} · {e(title)}</div>
      <div style="display:flex;gap:8px;align-items:center;margin-top:6px">{st}<span style="font-size:12px;color:var(--faint)">{icon("folder")} {e(folder)}</span></div></div></div>'''


def screen_agents():
    review = f'''<div class="card" style="margin-top:22px"><div style="display:flex;align-items:center;gap:10px">
      <span style="color:var(--faint);letter-spacing:2px">•••</span><div><div style="font-size:15px;font-weight:500">{e(U["to_review"])}</div>
      <div style="font-size:12px;color:var(--muted)">{e(U["to_review_sub"])}</div></div>
      <span style="margin-left:auto;font-family:Roboto Mono;font-size:13px;color:#5CD182">+148 <span style="color:#FA7366">−32</span></span></div>
      <div style="font-family:Roboto Mono;font-size:12.5px;color:var(--muted);margin-top:12px;line-height:1.6">
      src/routes/orders.ts<br>src/models/pricing.ts<br>tests/orders.test.ts<br><span style="color:var(--faint)">+3 more</span></div></div>'''
    body = f'''<div style="position:absolute;top:48px;left:16px;right:16px">
      <div style="display:flex;align-items:center;gap:10px"><div class="round" style="width:42px;height:42px">{icon("arrow_back")}</div>
      <div style="flex:1;text-align:center;font-size:15px;font-weight:500;margin-right:52px">{e(U["host"])}</div></div>
      <div style="display:flex;gap:8px;margin-top:14px">
        <span style="padding:8px 14px;border-radius:20px;background:#fff;color:#000;font-size:13.5px;font-weight:500">{icon("auto_awesome")} {e(U["agents"])}</span>
        <span style="padding:8px 14px;border-radius:20px;border:1px solid var(--outline);font-size:13.5px">{icon("terminal")} Terminals</span>
        <span style="padding:8px 14px;border-radius:20px;border:1px solid var(--outline);font-size:13.5px">{icon("folder")} Files</span></div>
      <div class="serif" style="font-size:40px;margin-top:22px;letter-spacing:-1px">{e(U["agents"])}</div>
      <div style="color:var(--muted);font-size:14px">{e(U["agents_sub"])}</div>
      {review}
      <div class="lbl">{icon("chat_bubble")}{e(U["chats"])}</div>
      {session_card("Claude Code", "orders-service", "orders-service", U["needs_you"], True)}
      {session_card("Codex", "pricing tests", "orders-service", U["working"], glyph="code")}
      <div class="lbl">{icon("laptop_mac")}{e(U["on_computer"])}</div>
      {session_card("OpenCode", "site copy", "site", U["idle"], glyph="data_object")}</div>
      <div style="position:absolute;bottom:34px;left:40px;right:40px;height:54px;border-radius:27px;background:#fff;color:#000;display:flex;align-items:center;justify-content:center;gap:10px;font-size:16px;font-weight:600">
        {icon("add")}{e(U["choose_agent"])}</div>'''
    return '<div style="position:absolute;inset:0;background:#0A0A0B"></div>' + statusbar() + body + '<div class="gbar"></div>'


def notif(title, body, when, actions, step=None, expanded=True):
    acts = "".join(f'<span style="padding:9px 16px;border-radius:20px;background:{"rgba(10,132,255,.25)" if i == 0 else "rgba(255,255,255,.1)"};font-size:14px;font-weight:500">{e(a)}</span>' for i, a in enumerate(actions))
    st = f' · {e(step)}' if step else ""
    return f'''<div style="background:#1E1F22;border-radius:26px;padding:16px 16px 16px;margin-bottom:6px">
      <div style="display:flex;gap:12px"><img src="{ASSETS}/icon.png" style="width:36px;height:36px;border-radius:18px">
      <div style="flex:1"><div style="font-size:12px;color:var(--muted)">Peering · {e(U["host"])} · {e(when)}{st}</div>
      <div style="font-size:16px;font-weight:500;margin-top:3px">{e(title)}</div>
      <div style="font-size:14px;color:rgba(255,255,255,.75);margin-top:2px;line-height:1.35">{e(body)}</div>
      {f'<div style="display:flex;gap:8px;margin-top:12px;flex-wrap:wrap">{acts}</div>' if actions else ''}</div>
      {icon("expand_less") if expanded else icon("expand_more")}</div></div>'''


def screen_shade():
    tiles = [("wifi", "Home Wi-Fi", True), ("bluetooth", "Bluetooth", True), ("do_not_disturb_on", "Do Not Disturb", False), ("flashlight_on", "Torch", False)]
    t = "".join(f'<div style="height:64px;border-radius:32px;background:{"#D6E3FF" if on else "#2A2B2F"};color:{"#0A1A33" if on else "#fff"};display:flex;align-items:center;gap:10px;padding:0 18px;font-size:14px;font-weight:500">{icon(i, "fill")}{e(n)}</div>' for i, n, on in tiles)
    return f'''<div style="position:absolute;inset:0;background:linear-gradient(#0d0e11,#121317)"></div>
      <div class="hole"></div>
      <div style="position:absolute;top:44px;left:22px;right:22px">
        <div style="display:flex;align-items:flex-end"><span style="font-size:44px;font-weight:400">9:41</span>
        <span style="margin-left:12px;margin-bottom:8px;color:var(--muted);font-size:15px">{e(U["date"])}</span>
        <span style="margin-left:auto;margin-bottom:8px;display:flex;gap:4px">{icon("wifi","fill")}{icon("signal_cellular_alt","fill")}{icon("battery_full","fill")}</span></div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:16px">{t}</div>
        <div style="margin:14px auto 18px;width:220px;height:6px;border-radius:3px;background:#2A2B2F"><div style="width:60%;height:6px;border-radius:3px;background:#D6E3FF"></div></div>
        {notif(U["n_title1"], U["n_body1"], U["now"], [U["allow"], U["deny"]])}
        {notif(U["n_title2"], U["n_body2"], U["now"], [U["opt1"], U["opt2"], U["opt3"]], step=U["n_step"])}
        {notif(U["n_title3"], U["n_body3"], U["min"], [], expanded=False)}
      </div><div class="gbar"></div>'''


def keyboard_bar(top):
    keys = ["esc", "tab", "ctrl", "alt", "cmd", "⇧", "←", "↑", "↓", "→"]
    k = "".join(f'<span style="flex:1;height:36px;border-radius:9px;border:1px solid var(--outline);display:flex;align-items:center;justify-content:center;font-size:13px;{"background:rgba(10,132,255,.22);border-color:var(--blue)" if x == "cmd" else ""}">{x}</span>' for x in keys)
    return f'<div style="position:absolute;top:{top}px;left:8px;right:8px;display:flex;gap:5px;padding:6px;border-radius:20px;border:1px solid var(--outline);background:#0f0f10">{k}</div>'


def gboard(top):
    rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    nums = "1234567890"
    out = []
    for r, row in enumerate(rows):
        ks = "".join(f'<div class="key" style="position:relative">{c}<span style="position:absolute;top:2px;right:5px;font-size:9px;color:var(--faint)">{nums[i] if r == 0 else ""}</span></div>' for i, c in enumerate(row))
        if r == 1:
            ks = f'<div style="flex:.5"></div>{ks}<div style="flex:.5"></div>'
        if r == 2:
            ks = f'<div class="key" style="flex:1.5;background:#3b3d44">{icon("shift")}</div>{ks}<div class="key" style="flex:1.5;background:#3b3d44">{icon("backspace")}</div>'
        out.append(f'<div style="display:flex;gap:6px;margin-bottom:10px">{ks}</div>')
    out.append(f'''<div style="display:flex;gap:6px"><div class="key" style="flex:1.5;background:#3b3d44;font-size:14px">?123</div>
      <div class="key" style="background:#3b3d44">,</div><div class="key" style="background:#3b3d44">{icon("mood")}</div>
      <div class="key" style="flex:4.5"></div><div class="key" style="background:#3b3d44">.</div>
      <div class="key" style="flex:1.5;background:#AEC6FF;color:#002E69">{icon("keyboard_return")}</div></div>''')
    tools = "".join(icon(i) for i in ["apps", "sentiment_satisfied", "gif_box", "content_paste", "settings", "mic"])
    return f'''<div style="position:absolute;top:{top}px;left:0;right:0;bottom:0;background:#1B1C20;padding:8px 6px 0">
      <div style="display:flex;justify-content:space-around;color:var(--muted);padding:6px 0 12px">{tools}</div>{"".join(out)}</div>'''


def screen_keyboard():
    return statusbar() + topbar("LAN") + mac(120) + keyboard_bar(392) + f'''<div style="position:absolute;top:448px;left:8px;right:8px;display:flex;gap:5px">
      {"".join(f'<span style="flex:1;height:34px;border-radius:9px;background:#1B1B1E;display:flex;align-items:center;justify-content:center;font-size:12.5px;color:var(--muted)">F{n}</span>' for n in range(1, 9))}</div>''' + gboard(498) + '<div class="gbar"></div>'


def screen_trackpad():
    dotfield = ("background-image:radial-gradient(rgba(255,255,255,.16) 1.2px, transparent 1.6px);background-size:18px 18px;")
    bar = [("desktop_windows", U["screen"]), ("keyboard", U["keyboard"]), ("select_window", U["apps"]), ("keyboard_command_key", U["shortcuts"]), ("tune", U["mode"])]
    b = "".join(f'<div>{icon(i)}<span>{e(t)}</span></div>' for i, t in bar)
    return statusbar() + f'''<div style="position:absolute;top:50px;left:16px;right:16px;display:flex;align-items:center;gap:10px">
      <span class="dot"></span><span style="font-size:15px;font-weight:500">{e(U["host"])}</span>
      <span class="chip" style="margin-left:auto">{e(U["relay"])}</span></div>
      <div style="position:absolute;top:92px;left:16px;right:16px;bottom:270px;border-radius:28px;border:1px solid rgba(255,255,255,.14);{dotfield}overflow:hidden">
        <div style="position:absolute;left:150px;top:250px;width:120px;height:120px;border-radius:50%;background:radial-gradient(rgba(255,255,255,.28),transparent 70%)"></div>
        <div style="position:absolute;left:186px;top:286px;width:48px;height:48px;border-radius:50%;border:1.5px solid rgba(255,255,255,.7)"></div>
        <span class="ms" style="position:absolute;top:12px;right:12px;font-size:22px;color:var(--muted)">open_in_full</span>
        <div style="position:absolute;bottom:18px;left:0;right:0;text-align:center;color:var(--faint);font-size:13px">{e(U["trackpad"])}</div></div>
      <div style="position:absolute;bottom:196px;left:16px;right:16px;height:54px;border-radius:27px;border:1px solid var(--outline);display:flex;align-items:center;padding:0 18px;color:var(--faint);font-size:15px">{e(U["type_hint"])}<span class="ms" style="margin-left:auto">mic</span></div>
      <div class="ctrl" style="top:742px;gap:12px">{"".join(f'<div class="circ" style="width:52px;height:52px">{icon(i)}</div>' for i in ["chevron_left", "keyboard_arrow_up", "keyboard_arrow_down", "chevron_right", "space_dashboard"])}</div>
      <div class="dock" style="top:810px;height:72px">{b}</div><div class="gbar"></div>'''


def host_row(name, status, glyph, beta=False, live=True):
    bt = f'<span class="chip" style="margin-left:8px">{e(U["beta"])}</span>' if beta else ""
    return f'''<div class="card" style="display:flex;align-items:center;gap:14px;margin-bottom:10px;border-radius:20px">
      <div style="width:44px;height:44px;border-radius:12px;border:1px solid var(--outline);display:flex;align-items:center;justify-content:center">{icon(glyph)}</div>
      <div style="flex:1"><div style="font-size:16px;font-weight:500;display:flex;align-items:center">{e(name)}{bt}</div>
      <div style="font-size:13px;color:var(--muted);display:flex;align-items:center;gap:6px;margin-top:3px"><span class="dot" style="{"" if live else "background:var(--blue)"}"></span>{e(status)}</div></div>
      {icon("more_vert")}</div>'''


def screen_pair():
    digits = "".join(f'<div style="width:46px;height:58px;border-radius:14px;border:1px solid {"var(--blue)" if i == 4 else "var(--outline)"};display:flex;align-items:center;justify-content:center;font-size:26px;font-weight:500">{d}</div>' for i, d in enumerate("4829  "))
    return '<div style="position:absolute;inset:0;background:#0A0A0B"></div>' + statusbar() + f'''<div style="position:absolute;top:60px;left:18px;right:18px">
      <div class="serif" style="font-size:38px;letter-spacing:-1px">Peering</div>
      <div style="color:var(--muted);font-size:14px;margin-top:2px">{e(U["tagline"])}</div>
      <div class="lbl">{e(U["trusted"])}</div>
      {host_row(U["host"], U["online"], "laptop_mac")}
      {host_row(U["pc"], U["nearby_status"], "desktop_windows", beta=True)}
      <div class="lbl">{e(U["nearby"])}</div>
      {host_row("Mac mini", U["nearby_status"], "desktop_mac", live=False)}</div>
      <div style="position:absolute;left:0;right:0;bottom:0;height:400px;background:var(--sheet);border-radius:36px 36px 0 0;border-top:1px solid var(--hair);padding:14px 26px">
        <div style="width:36px;height:4px;border-radius:2px;background:rgba(255,255,255,.3);margin:0 auto 26px"></div>
        <div class="serif" style="font-size:28px;letter-spacing:-.5px">{e(U["code_title"])}</div>
        <div style="color:var(--muted);font-size:14.5px;margin-top:6px">{e(U["code_body"])}</div>
        <div style="display:flex;gap:9px;margin-top:28px;justify-content:center">{digits}</div>
        <div style="margin-top:34px;height:52px;border-radius:26px;background:#fff;color:#000;display:flex;align-items:center;justify-content:center;font-weight:600;font-size:16px;opacity:.35">{e(U["pair"])}</div>
      </div><div class="gbar"></div>'''


def phone(inner, left, top, zoom, rot=0):
    return (f'<div class="phone" style="left:{left / zoom}px;top:{top / zoom}px;zoom:{zoom};transform:rotate({rot}deg)">'
            f'<div class="screen">{inner}</div></div>')


def badge(text, ic, left, top):
    return f'<div class="badge" style="left:{left}px;top:{top}px">{icon(ic, "fill")}{e(text)}</div>'


def page(body, w=1080, h=1920):
    css = CSS.replace("WPX", f"{w}px").replace("HPX", f"{h}px").replace("zoom:Z;", "")
    return f'<!doctype html><html><head><meta charset="utf-8">{FONTS}<style>{css}</style></head><body><div class="grid"></div>{body}</body></html>'


def top_h(text, size=118):
    return f'<h1 style="top:90px;font-size:{size}px">{headline(text)}</h1>'


Z = 1.9
H = C["h"]
SHOTS = [
    top_h(H[0]) + '<div class="glow" style="left:200px;top:700px"></div>' + phone(screen_remote(), 130, 700, Z)
    + badge(B["awake"], "bolt", 360, 600) + badge(B["lid"], "laptop_mac", 40, 1660),
    top_h(H[1]) + '<div class="glow" style="left:100px;top:600px"></div>' + phone(screen_remote("RELAY"), 130, 560, Z)
    + badge(B["e2e"], "lock", 300, 840) + badge(B["anynet"], "public", 40, 1340),
    top_h(H[2]) + '<div class="glow" style="left:100px;top:600px"></div>' + phone(screen_agents(), 130, 560, Z)
    + badge(B["runs"], "laptop_mac", 380, 450),
    f'<h1 style="top:1510px;font-size:118px">{headline(H[3])}</h1>' + phone(screen_shade(), 194, -60, 1.6)
    + badge(B["multi"], "checklist", 330, 1300),
    top_h(H[4]) + phone(screen_keyboard(), 130, 560, Z) + badge(B["keys"], "keyboard_command_key", 400, 470)
    + badge(B["fkeys"], "function", 40, 1080),
    top_h(H[5]) + phone(screen_trackpad(), 130, 560, Z) + badge(B["gestures"], "swipe", 300, 1300),
    top_h(H[6]) + phone(screen_pair(), 130, 560, Z) + badge(B["platforms"], "devices", 330, 470)
    + badge(B["noaccount"], "person_off", 470, 1455),
]


def feature(w, h):
    s = h / 1080
    return (f'<div class="glow" style="left:{900 * s}px;top:{100 * s}px"></div>'
            f'<h1 style="left:{110 * s}px;top:{300 * s}px;font-size:{112 * s}px">{headline(C["feature"])}</h1>'
            f'<div style="position:absolute;left:{112 * s}px;top:{640 * s}px;width:{760 * s}px;font-size:{40 * s}px;color:var(--muted);line-height:1.35">{e(C["feature_sub"])}</div>'
            + phone(screen_remote(), 1080 * s, 80 * s, 1.65 * s, -6) + phone(screen_agents(), 1430 * s, 200 * s, 1.65 * s, 6))


def render(markup, out, w, h):
    src = os.path.join(HERE, "build", os.path.basename(out).replace(".png", ".html"))
    open(src, "w").write(page(markup, w, h))
    subprocess.run([CHROME, "--headless=new", "--hide-scrollbars", "--force-device-scale-factor=1", "--allow-file-access-from-files",
                    f"--window-size={w},{h}", "--virtual-time-budget=8000", f"--screenshot={out}", "file://" + src],
                   check=True, capture_output=True)


def main():
    out = os.path.join(HERE, "out", LANG)
    os.makedirs(out, exist_ok=True)
    os.makedirs(os.path.join(HERE, "build"), exist_ok=True)
    for i, m in enumerate(SHOTS, 1):
        render(m, os.path.join(out, f"{i:02d}.png"), 1080, 1920)
    render(feature(1920, 1080), os.path.join(out, "feature-1920.png"), 1920, 1080)
    render(feature(1024, 500), os.path.join(out, "feature-graphic.png"), 1024, 500)


if __name__ == "__main__":
    main()
