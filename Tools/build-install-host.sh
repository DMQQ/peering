#!/bin/bash
# Build the macOS host, install it in /Applications, and launch it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${TMPDIR:-/tmp}/PeeringHostBuild"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/Peering.app"
INSTALLED_APP="/Applications/Peering.app"

cd "$REPO_DIR"

# `generic/platform=macOS` and not `platform=macOS`, and the difference is the architecture
# of what comes out. The plain form resolves to *this* Mac, so it builds one slice and an
# Intel Mac cannot open the result at all. Nothing else here decides it: the project sets no
# `ARCHS`, so this flag is the only thing standing between a universal app and an arm64-only
# one, and the failure is silent because the build succeeds either way.
xcodebuild \
    -project MacCast.xcodeproj \
    -scheme MacCastHost \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -allowProvisioningUpdates \
    build

if [ ! -d "$BUILT_APP" ]; then
    echo "Built app was not found at $BUILT_APP" >&2
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
    "$BUILT_APP/Contents/PlugIns/MacCastHostWidgetExtension.appex/Contents/MacOS/MacCastHostWidgetExtension"
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

osascript -e 'tell application id "pl.dmq.peering.host" to quit' 2>/dev/null || true
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
