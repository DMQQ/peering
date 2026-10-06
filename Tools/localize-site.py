#!/usr/bin/env python3
"""Wire the translated pages into the site: hreflang alternates, a language row in the footer,
and the sitemap. Idempotent, so it is safe to run after every edit of any page.

The translations themselves live in Relay/site/<dir>/<page>.html, one file per English page.
"""
from __future__ import annotations

import datetime
import pathlib
import re

SITE = pathlib.Path(__file__).resolve().parent.parent / "Relay" / "site"
ORIGIN = "https://getpeering.app"
# directory, hreflang, name in its own language
LANGS = [
    ("de", "de", "Deutsch"),
    ("es", "es", "Español"),
    ("fr", "fr", "Français"),
    ("it", "it", "Italiano"),
    ("ja", "ja", "日本語"),
    ("ko", "ko", "한국어"),
    ("pt", "pt-BR", "Português"),
    ("ru", "ru", "Русский"),
    ("zh", "zh-Hans", "简体中文"),
]
SITEMAP_PAGES = [
    "index", "download", "support", "how-to-pair-iphone-mac", "remote-desktop-for-mac",
    "access-your-mac-from-anywhere", "coding-agent-notifications",
    "keep-mac-awake-for-remote-access", "screens-alternative", "remote-desktop-apps-compared",
    "privacy", "terms",
]


def url(page: str, lang_dir: str | None) -> str:
    prefix = f"/{lang_dir}" if lang_dir else ""
    if page == "index":
        return f"{ORIGIN}{prefix}/"
    return f"{ORIGIN}{prefix}/{page}"


def path_of(page: str, lang_dir: str | None) -> str:
    return url(page, lang_dir)[len(ORIGIN):]


def process(page: str) -> None:
    present = [(None, "en", "English")] + [l for l in LANGS if (SITE / l[0] / f"{page}.html").exists()]
    if len(present) == 1:
        return
    hreflang = "".join(
        f'<link rel="alternate" hreflang="{code}" href="{url(page, d)}">\n'
        for d, code, _ in present
    ) + f'<link rel="alternate" hreflang="x-default" href="{url(page, None)}">\n'
    switcher = (
        '    <nav class="foot-links" aria-label="Languages">\n'
        + "".join(
            f'      <a href="{path_of(page, d)}" hreflang="{code}" lang="{code}">{name}</a>\n'
            for d, code, name in present
        )
        + "    </nav>\n"
    )
    for d, _, _ in present:
        file = SITE / (f"{d}/" if d else "") / f"{page}.html"
        html = file.read_text(encoding="utf-8")
        html = re.sub(r'<link rel="alternate" hreflang="[^"]*" href="[^"]*">\n', "", html)
        html = re.sub(r'    <nav class="foot-links" aria-label="Languages">.*?</nav>\n', "", html, flags=re.S)
        html, n = re.subn(r'(<link rel="canonical"[^>]*>\n)', lambda m: m.group(1) + hreflang, html, count=1)
        if n != 1:
            raise SystemExit(f"{file}: no canonical link to hang hreflang on")
        html, n = re.subn(r'(    <p class="foot-fine">)', lambda m: switcher + m.group(1), html, count=1)
        if n != 1:
            raise SystemExit(f"{file}: no foot-fine paragraph to put the language row above")
        file.write_text(html, encoding="utf-8")


def sitemap() -> None:
    today = datetime.date.today().isoformat()
    priority = {"index": "1.0", "download": "0.8", "support": "0.5", "privacy": "0.3", "terms": "0.3"}
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">']
    for page in SITEMAP_PAGES:
        variants = [(None, "en")] + [(d, c) for d, c, _ in LANGS if (SITE / d / f"{page}.html").exists()]
        links = "".join(f'<xhtml:link rel="alternate" hreflang="{c}" href="{url(page, d)}"/>' for d, c in variants)
        links += f'<xhtml:link rel="alternate" hreflang="x-default" href="{url(page, None)}"/>'
        for d, _ in variants:
            out.append(
                f"  <url><loc>{url(page, d)}</loc><lastmod>{today}</lastmod>"
                f"<priority>{priority.get(page, '0.7')}</priority>{links}</url>"
            )
    out.append("</urlset>")
    (SITE / "sitemap.xml").write_text("\n".join(out) + "\n", encoding="utf-8")


if __name__ == "__main__":
    for file in sorted(SITE.glob("*.html")):
        process(file.stem)
    sitemap()
    print("done")
