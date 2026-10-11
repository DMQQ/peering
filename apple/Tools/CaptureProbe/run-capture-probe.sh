#!/bin/bash
# Build, sign, bundle, and run the capture probe.
#
# The bundle and the stable signature are not housekeeping — they are what makes the
# permission grant possible at all. Screen Recording is a TCC decision, and TCC keys the
# decision to a *code identity*: a bundle identifier backed by a real signature. A bare
# Mach-O produced by SwiftPM is signed ad-hoc with a hash-derived signature and has no
# bundle identifier, so the grant is attributed to whatever launched it (the terminal, or
# the shell that spawned it) instead of to the probe. The result is the state this probe
# exists to detect: `SCShareableContent` fails with -3801, or a stream starts and delivers
# nothing, and the only fix anyone can think of is granting the terminal permission too.
#
# The signature has to be stable across rebuilds for a second reason: TCC matches on the
# signing identity, so an ad-hoc signature that changes with every build loses the grant
# each time it is rebuilt. Same reasoning as `Tools/run-probe.sh`.
#
# usage: Tools/CaptureProbe/run-capture-probe.sh [probe arguments]
#   e.g. Tools/CaptureProbe/run-capture-probe.sh --request-access
#        Tools/CaptureProbe/run-capture-probe.sh --seconds 5 --output /tmp/screen.mov
#        Tools/CaptureProbe/run-capture-probe.sh --synthetic
#
# MACCAST_LAUNCH=open runs it through LaunchServices instead of exec'ing the binary. That
# is a different TCC question, not a different way of starting the same program: a process
# exec'd from a shell inherits the shell's "responsible process", while one LaunchServices
# starts is responsible for itself. When the two disagree about the permission, that is the
# reason, and this switch is how to tell which one you are looking at.
set -euo pipefail

LAUNCH="${MACCAST_LAUNCH:-exec}"
LOG="${MACCAST_PROBE_LOG:-/tmp/maccast-capture-probe.log}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/maccast-captureprobe"
APP="$BUILD_DIR/CaptureProbe.app"
BUNDLE_ID="pl.dmq.maccast.captureprobe"

cd "$HERE"
swift build 2>&1 | grep -E "error:|warning: " || true

BIN="$(swift build --show-bin-path)/CaptureProbe"
if [ ! -x "$BIN" ]; then
    echo "error: $BIN was not produced" >&2
    exit 1
fi

# Prefer the identity the host app is signed with, so both come from the same team.
IDENTITY="$(security find-identity -v -p codesigning \
    | grep -oE '[0-9A-F]{40} "Apple Development: [^"]*"' \
    | head -1 | cut -d' ' -f1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/CaptureProbe"

# A bundle needs an Info.plist before it has an identity at all. CFBundleIdentifier is the
# key TCC records; without it the app is anonymous and cannot hold a grant.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>CaptureProbe</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>CaptureProbe</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if [ -n "$IDENTITY" ]; then
    # --identifier on the bundle is what pins the grant. The signature must cover the
    # bundle, not the executable, or the plist is not part of what was signed.
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" 2>&1 \
        | grep -v "replacing existing signature" || true
    codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/codesign: /'
else
    echo "warning: no codesigning identity found — TCC will not be able to record a grant" >&2
fi

echo "running $APP ($BUNDLE_ID) via $LAUNCH"
if [ "$LAUNCH" = "open" ]; then
    # A LaunchServices launch has no terminal to inherit, so its output is connected to a
    # file explicitly. Without this the run's entire output is lost and the only symptom is
    # that nothing appeared to happen.
    rm -f "$LOG"
    open -n -W --stdout "$LOG" --stderr "$LOG" "$APP" --args "$@"
    status=$?
    echo "--- $LOG ---"
    cat "$LOG" 2>/dev/null || echo "(no output was written)"
    exit $status
fi

exec "$APP/Contents/MacOS/CaptureProbe" "$@"
