"""Copies the rendered header videos and search images into upload/creative and checks each one
against the creative asset specifications before anything is uploaded.

    python3 store/stage_creative.py

Header video:  3840x1646, 30 or 60 fps, 5 to 30 seconds, .mov .m4v .mp4
Search image:  3:2, 1920x1280 up to 3840x2560, no alpha
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

APPSTORE = Path(__file__).resolve().parent.parent
VIDEOS = APPSTORE.parent / "social/motion/out"
SEARCH = APPSTORE / "out/search"
TARGET = APPSTORE / "upload/creative"

# Our video language -> the App Store Connect locale folder (the names upload/metadata uses).
LOCALES = {"en": "en-US", "de": "de-DE", "es": "es-ES", "fr": "fr-FR", "it": "it", "pt-BR": "pt-BR",
           "ru": "ru", "ja": "ja", "ko": "ko", "zh-Hans": "zh-Hans"}


def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height,r_frame_rate,codec_name:format=duration", "-of", "json", str(path)],
                         capture_output=True, text=True, check=True).stdout
    data = json.loads(out)
    stream = data["streams"][0]
    num, den = stream["r_frame_rate"].split("/")
    return stream["width"], stream["height"], int(num) / int(den), float(data["format"]["duration"]), stream["codec_name"]


def main():
    problems = []
    for lang, locale in LOCALES.items():
        video = VIDEOS / f"peering-header-{lang}.mp4"
        image = SEARCH / f"{locale}.png"
        (TARGET / "header").mkdir(parents=True, exist_ok=True)
        (TARGET / "search").mkdir(parents=True, exist_ok=True)
        if video.exists():
            width, height, fps, seconds, codec = probe(video)
            if (width, height) != (3840, 1646) or fps not in (30, 60) or not 5 <= seconds <= 30:
                problems.append(f"{locale} header: {width}x{height} {fps}fps {seconds:.1f}s")
            shutil.copy(video, TARGET / "header" / f"{locale}.mp4")
            print(f"{locale:8} header {width}x{height} {fps:g}fps {seconds:.0f}s {codec} {video.stat().st_size // 1024} KB")
        else:
            problems.append(f"{locale} header: {video.name} is missing")
        if image.exists():
            picture = Image.open(image)
            if picture.size != (3840, 2560) or picture.mode in ("RGBA", "LA"):
                problems.append(f"{locale} search: {picture.size} {picture.mode}")
            shutil.copy(image, TARGET / "search" / f"{locale}.png")
            print(f"{locale:8} search {picture.size[0]}x{picture.size[1]} {picture.mode} {image.stat().st_size // 1024} KB")
        else:
            problems.append(f"{locale} search: {image.name} is missing")
    if problems:
        sys.exit("Out of spec:\n  " + "\n  ".join(problems))


if __name__ == "__main__":
    main()
