#!/bin/bash
# Build the macOS host, install it in /Applications, and launch it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# **The default DerivedData, not one of this script's own.** It used to build into
# `$TMPDIR/PeeringHostBuild`, and in that location Xcode extracts Sparkle's binary artifact
# incompletely: `Sparkle.xcframework` lands without its root `Info.plist` and the build dies with
# "Unable to resolve module dependency: 'Sparkle'". It reads like a package-resolution problem and
# is not one — the cached zip is intact and the same artifact extracts correctly here. Two other
# builds of this app already live in this DerivedData, so reusing it costs nothing and the path
# that does not work is no longer reachable.
INSTALLED_APP="/Applications/Peering.app"

cd "$REPO_DIR"

# `generic/platform=macOS` and not `platform=macOS`, and the difference is the architecture
# of what comes out. The plain form resolves to *this* Mac, so it builds one slice and an
# Intel Mac cannot open the result at all. Nothing else here decides it: the project sets no
# `ARCHS`, so this flag is the only thing standing between a universal app and an arm64-only
# one, and the failure is silent because the build succeeds either way.
xcodebuild \
    -project Peering.xcodeproj \
    -scheme PeeringHost \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates \
    build

# Resolved *after* the build: on a Mac that has never built this scheme the directory does not
# exist yet, and looking it up first would leave the variable empty and fail a build that worked.
BUILT_APP="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Peering-*/Build/Products/Release/Peering.app 2>/dev/null | head -1 || true)"
if [ -z "$BUILT_APP" ] || [ ! -d "$BUILT_APP" ]; then
    echo "No Release build of the host was found in the default DerivedData." >&2
    exit 1
fi

# Universal, proved here rather than discovered by an Intel Mac. The destination above is what
# produces both slices and this is what says so out loud: without it a regression in that flag is
# invisible, because a build for one architecture succeeds exactly like a build for two.
#
# The nested widget is checked as well. A thin appex inside a universal app still fails on Intel,
# and it is the half nobody looks at.
for binary in \
    "$BUILT_APP/Contents/MacOS/Peering" \
    "$BUILT_APP/Contents/PlugIns/PeeringHostWidgetExtension.appex/Contents/MacOS/PeeringHostWidgetExtension"
do
    archs="$(lipo -archs "$binary" 2>/dev/null || echo missing)"
    case "$archs" in
        *arm64*x86_64*|*x86_64*arm64*) ;;
        *)
            echo "$(basename "$binary") is '$archs', not universal: an Intel Mac cannot run it." >&2
            exit 1
            ;;
    esac
done

# This copy is the developer's own, and a Release build reports usage like any other, so their
# sessions and settings changes would be counted as users. Off on this Mac; the switch in Settings
# turns it back on to test the pipeline.
defaults write pl.dmq.peering.host Peering.analyticsEnabled -bool false

osascript -e 'tell application id "pl.dmq.peering.host" to quit' 2>/dev/null || true

# **Waited for, and complained about, because a quit that does nothing is the quietest way this
# script can fail.** `osascript` exits 0 whether or not an app answered, and `open` on a Mac whose
# old copy is still running activates that copy instead of launching the new one — so the build
# lands on disk, the script says "installed and opened", and the process that is running is the one
# from before. Measured on 25 September 2026: a process started at 12:35 was still serving builds
# copied over it at 12:50, and everything added in between was believed to be running and was not.
PIDS="$(pgrep -f "Peering.app/Contents/MacOS/Peering" || true)"
if [ -n "$PIDS" ]; then
    for _ in $(seq 1 20); do
        sleep 0.5
        pgrep -f "Peering.app/Contents/MacOS/Peering" > /dev/null || break
    done
fi
if pgrep -f "Peering.app/Contents/MacOS/Peering" > /dev/null; then
    echo "The running copy of $INSTALLED_APP did not quit, so opening it would only activate the old" >&2
    echo "binary. Quit Peering from its menu bar and run this script again." >&2
    exit 1
fi

/usr/bin/ditto "$BUILT_APP" "$INSTALLED_APP"

# `open` straight after the copy fails with error -600 (procNotFound) often enough to be worth a
# retry: LaunchServices has not caught up with a bundle that was replaced a moment ago, so it says
# the application could not be found — and the script would report success while nothing launched.
for attempt in 1 2 3; do
    if open "$INSTALLED_APP" 2>/dev/null; then
        break
    fi
    sleep 2
    if [ "$attempt" = 3 ]; then
        echo "Could not launch $INSTALLED_APP — run it by hand." >&2
        exit 1
    fi
done

echo "Installed and opened $INSTALLED_APP"
