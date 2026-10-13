#!/bin/bash
# Keep the screen changing for N seconds, so capture has something to encode.
#
# Compiled on demand and cached next to the source: this is a few dozen lines of
# CoreGraphics, and an SPM package for it would cost more in ceremony than the tool costs in
# build time. The cache is keyed on the source's timestamp, so an edit recompiles.
#
# usage: Tools/activity.sh [seconds] [--hz N] [--quiet]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/Activity/Activity.swift"
BIN="$HERE/Activity/.build/peering-activity"

mkdir -p "$(dirname "$BIN")"
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    swiftc -O -o "$BIN" "$SRC"
fi

exec "$BIN" "$@"
