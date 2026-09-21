#!/bin/bash
# Regenerate the social card, `Relay/site/assets/og.png`.
#
# Written because the card had no generator, and a card with no generator is a card that goes
# stale: the one that was here showed an iPhone running a build of the app from before the
# Connect screen was redesigned, and nothing in the repo said how to make another one. The site
# it is supposed to be a picture of had moved on and the picture had not.
#
# **It is a picture of the site, rendered rather than composed.** The card is the page's own hero
# at the size a scraper wants, so it cannot drift from the site the way a hand-built layout in an
# image editor can: change the hero, run this, and the card agrees with it again.
#
# The two sizes are the whole trick. Rendering straight into 1200x630 cuts the hero off above the
# buttons, because the hero is laid out for a browser window and a browser window is taller than
# 1.9:1. Rendering at 1600x840 and scaling down keeps the same 1.905 proportion with a window the
# hero actually fits in, so the buttons that are the card's call to action survive the crop.
#
#   Tools/make-og.sh
#
# Requires Google Chrome. Serves the site on a loopback port for the length of the render, because
# the stylesheet and the screenshots are absolute paths from the site root.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_DIR="$REPO_DIR/Relay/site"
OUT="$SITE_DIR/assets/og.png"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if [ ! -x "$CHROME" ]; then
    echo "Google Chrome is not at $CHROME. Set CHROME= to wherever it is." >&2
    exit 1
fi

PORT="${OG_PORT:-8765}"
TMP="$(mktemp -d)"
SERVER_PID=""

cleanup() {
    # The kill is waited on, because a background job still running when the trap returns makes
    # bash print "Terminated: 15" over the last line of a run that succeeded.
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> serving $SITE_DIR on 127.0.0.1:$PORT"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SITE_DIR" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

# Waited for rather than slept on: a fixed sleep is either slower than it needs to be or, on a
# loaded machine, shorter than the server takes to bind, and the failure then reads as Chrome
# rendering a blank page.
for _ in $(seq 1 50); do
    if curl -sf "http://127.0.0.1:$PORT/" -o /dev/null 2>/dev/null; then break; fi
    sleep 0.2
done

echo "==> rendering 1600x840"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=1 --window-size=1600,840 \
    --screenshot="$TMP/og-1600.png" "http://127.0.0.1:$PORT/" 2>/dev/null

if [ ! -s "$TMP/og-1600.png" ]; then
    echo "Chrome produced no screenshot. Its output:" >&2
    cat "$TMP/server.log" >&2
    exit 1
fi

# `sips -Z` fits the longest side, which is the width here, so 1200 across lands on 630 down.
echo "==> scaling to 1200x630"
sips -Z 1200 "$TMP/og-1600.png" --out "$OUT" >/dev/null

# Asked for rather than assumed: the whole point of this script is that the last card was the
# wrong size for long enough that nobody noticed, and every scraper crops to this shape.
DIMS="$(sips -g pixelWidth -g pixelHeight "$OUT" | awk -F': ' '/pixel/{printf "%s ", $2}')"
if [ "$DIMS" != "1200 630 " ]; then
    echo "The card came out $DIMS rather than 1200 630." >&2
    exit 1
fi

echo "==> wrote $OUT ($(stat -f %z "$OUT") bytes, ${DIMS% })"
