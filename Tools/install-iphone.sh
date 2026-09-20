#!/bin/bash
# Build the iPhone app and install it on the connected phone.
#
# Written because the alternative is two long commands nobody remembers, and because the second
# one fails in a way that misleads: `devicectl` reports a phone as `unavailable` whenever it is
# locked or asleep, and the install then fails with error 4016, whose text ("the device is not
# able to fulfill the requested usage assertion requirements") says nothing about the phone being
# in a pocket. This script says so instead.
#
#   Tools/install-iphone.sh                    # the only iPhone attached
#   Tools/install-iphone.sh <udid-or-name>     # a particular one
#   Tools/install-iphone.sh --simulator        # a booted simulator, for a check without a phone
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${TMPDIR:-/tmp}/PeeringPhoneBuild"

TARGET="${1:-}"

cd "$REPO_DIR"

if [ "$TARGET" = "--simulator" ]; then
    DESTINATION="platform=iOS Simulator,name=iPhone 17 Pro"
    BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Debug-iphonesimulator/MacCast.app"
    PRODUCTS="Debug-iphonesimulator"
else
    DESTINATION="generic/platform=iOS"
    BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Debug-iphoneos/MacCast.app"
    PRODUCTS="Debug-iphoneos"
fi

echo "==> building for $DESTINATION"
# `-allowProvisioningUpdates` because a fresh clone has no profile for this team yet, and without
# it the failure is a signing error that reads like a code problem.
xcodebuild \
    -project MacCast.xcodeproj \
    -scheme MacCast \
    -configuration Debug \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -allowProvisioningUpdates \
    build

# Asked for rather than assumed: `-derivedDataPath` keeps builds out of the shared Xcode cache
# where several agents and this script would otherwise overwrite each other's products, and the
# path is derived from that, so a missing app here means the build did something unexpected.
if [ ! -d "$BUILT_APP" ]; then
    echo "The build produced no app at $BUILT_APP" >&2
    exit 1
fi

if [ "$TARGET" = "--simulator" ]; then
    # The most recently booted one, because that is the one somebody is looking at.
    DEVICE="$(xcrun simctl list devices booted 2>/dev/null \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)"
    if [ -z "$DEVICE" ]; then
        echo "No simulator is booted." >&2
        exit 1
    fi
    echo "==> installing on simulator $DEVICE"
    xcrun simctl install "$DEVICE" "$BUILT_APP"
    echo "==> installed. Relaunch the app in the simulator."
    exit 0
fi

# The UDID is pulled out by shape rather than by column, because a device name and a hostname can
# both contain spaces and awk would then be counting the wrong things. `physical` excludes the
# simulators, which devicectl lists in the same table.
if [ -z "$TARGET" ]; then
    TARGET="$(xcrun devicectl list devices 2>/dev/null \
        | grep 'physical' \
        | grep -iE 'iphone|ipad' \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' \
        | head -1)"
fi

if [ -z "$TARGET" ]; then
    echo "No iPhone is attached. Plug one in, or unlock the one you have." >&2
    echo >&2
    echo "What devicectl can see:" >&2
    xcrun devicectl list devices 2>/dev/null | grep -iE 'iphone|ipad' >&2 || echo "  (nothing)" >&2
    exit 1
fi

echo "==> installing on $TARGET"
# `unavailable` is the common failure and the least self-explanatory, so it is caught rather than
# passed through: the fix is to wake the phone, not to touch the build.
if ! xcrun devicectl device install app --device "$TARGET" "$BUILT_APP"; then
    echo >&2
    echo "The install failed. On a phone that is locked or asleep this is error 4016, and the" >&2
    echo "answer is to wake it and keep it near the Mac, then run this again." >&2
    exit 1
fi

echo "==> installed. Relaunch the app on the phone so it picks up the new build."
echo "    (A running app keeps the old binary until it is relaunched.)"
