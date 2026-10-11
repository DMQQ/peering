"""Frames the seeded agent chat capture (raw/chat.png) as one extra canvas per language.

    python3 frame_chat.py            # all ten
"""
import os, sys
from PIL import Image, ImageDraw
import frame

HERE = os.path.dirname(os.path.abspath(__file__))
HEADS = {
    "en": "Chat with\nyour *agents*.",
    "de": "Chatte mit\ndeinen *Agenten*.",
    "es": "Chatea con\ntus *agentes*.",
    "fr": "Discute avec\ntes *agents*.",
    "it": "Chatta con\ni tuoi *agenti*.",
    "pt-BR": "Converse com\nseus *agentes*.",
    "ru": "Общайся с\nсвоими *агентами*.",
    "ja": "*エージェント*と\nチャット。",
    "ko": "*에이전트*와\n대화하세요.",
    "zh-Hans": "与你的\n*智能体*对话。",
}
FOLDERS = {"en": ("en-US", "en"), "de": ("de-DE", "de"), "es": ("es-ES", "es"), "fr": ("fr-FR", "fr"), "it": ("it", "it"),
           "pt-BR": ("pt-BR", "pt-BR"), "ru": ("ru", "ru"), "ja": ("ja", "ja"), "ko": ("ko", "ko"), "zh-Hans": ("zh-Hans", "zh-Hans")}


def cleaned(src, dst):
    """The Mac does not know the seeded chat and says so in red under the transcript; that line is painted out."""
    im = Image.open(src).convert("RGB")
    ImageDraw.Draw(im).rectangle((0, 2050, im.width, 2135), fill=(4, 6, 3))
    im.save(dst)


def build(lang):
    frame.LANG = lang
    raw = f"{HERE}/raw/chat.png"
    cleaned(f"{HERE}/debug/09-chat.png", raw)
    frame.PW = frame.W
    canvas = frame.background([frame.W // 2])
    text = HEADS[lang]
    size = frame.fit([text], 296)
    size = min(size, 296)
    frame.headline(canvas, text, (80, 120), size)
    frame.place(canvas, raw, 1000, (frame.W // 2, 1760), 0)
    out = canvas.convert("RGB")
    os.makedirs(f"{HERE}/out/{lang}", exist_ok=True)
    out.save(f"{HERE}/out/{lang}/08.png")
    folder, code = FOLDERS[lang]
    dest = f"{HERE}/upload/screenshots/{folder}"
    os.makedirs(dest, exist_ok=True)
    out.save(f"{dest}/08_{code}.png")
    print(lang, "ok", size)


if __name__ == "__main__":
    for lang in (sys.argv[1:] or HEADS):
        build(lang)
