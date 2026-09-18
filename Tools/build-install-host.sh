#!/bin/bash
# Build the macOS host, install it in /Applications, and launch it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${TMPDIR:-/tmp}/PeeringHostBuild"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/Peering.app"
INSTALLED_APP="/Applications/Peering.app"

cd "$REPO_DIR"

xcodebuild \
    -project MacCast.xcodeproj \
    -scheme MacCastHost \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -allowProvisioningUpdates \
    build

if [ ! -d "$BUILT_APP" ]; then
    echo "Built app was not found at $BUILT_APP" >&2
    exit 1
fi

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
