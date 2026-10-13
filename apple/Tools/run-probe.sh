#!/bin/bash
# Build, sign, and run the probe client.
#
# The signing step is not optional housekeeping. macOS grants keychain access to a specific
# code identity, and SwiftPM's default ad-hoc signature is derived from the build hash — so
# an unsigned probe can use a key it created moments ago and then be locked out of it after
# the next rebuild, with `errSecAuthFailed` and no indication of why. Signing with a stable
# identity makes that key usable across rebuilds, which is what lets the probe test the
# "already paired" path at all.
#
# usage: Tools/run-probe.sh [probe arguments]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_DIR="$HERE/PeeringProbe"

# Pick the signing identity **deterministically**, and pin it.
#
# This machine has more than one "Apple Development" identity, and `find-identity` does not
# promise an order. Taking `head -1` therefore meant the probe could be signed with a
# different identity from one run to the next — and since macOS grants keychain access to a
# specific code identity, the probe's own stored key would come back "denied". Worse, the
# denial surfaces as a *modal SecurityAgent prompt* rather than an error, so an unattended
# run hangs forever instead of failing. Pinning the hash here makes the signature stable,
# which is the whole precondition for the stored key staying usable.
#
# Override with PROBE_SIGNING_IDENTITY=<hash> when the pinned identity is unavailable.
PINNED_IDENTITY="${PROBE_SIGNING_IDENTITY:-}"
if [ -z "$PINNED_IDENTITY" ]; then
    PINNED_IDENTITY="$(security find-identity -v -p codesigning \
        | grep -oE '[0-9A-F]{40} "Apple Development: [^"]*"' \
        | cut -d' ' -f1 | sort | head -1)"
fi
IDENTITY="$PINNED_IDENTITY"

cd "$PROBE_DIR"
swift build 2>&1 | grep -E "error:|warning: " || true

BIN="$(swift build --show-bin-path)/PeeringProbe"

if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --identifier pl.dmq.maccast.probe "$BIN" 2>&1 \
        | grep -v "replacing existing signature" || true
else
    echo "warning: no codesigning identity found; keychain access may be denied after rebuilds" >&2
fi

# Exec the binary directly rather than through `swift run`, which would re-sign it ad-hoc.
exec "$BIN" "$@"
