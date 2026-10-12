#!/bin/bash
# Everything that can fail before a phone is involved: the string catalogs, package tests, then a compile of both apps.
#
#   Tools/check.sh           # tests and both builds
#   Tools/check.sh --quick   # package tests only
#
# The builds use a private DerivedData so a second session building at the same time does not
# hit "database is locked". Output goes to a log and is only shown on failure, because piping a
# build through tail makes the exit code tail's.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${TMPDIR:-/tmp}/PeeringCheckBuild"
LOG="$(mktemp)"
cd "$REPO_DIR"

failed=0

step() {
    local name="$1"
    shift
    printf "==> %s\n" "$name"
    if "$@" >"$LOG" 2>&1; then
        echo "    ok"
    else
        echo "    FAILED"
        grep -E "error:|✘|failed" "$LOG" | sort -u | head -20
        failed=1
    fi
}

step "String catalogs are fully translated" python3 Tools/check-localization.py

for package in MacCastKit RemoteCore SSHCore; do
    step "$package tests" swift test --package-path "$package"
done

if [ "${1:-}" != "--quick" ]; then
    step "iPhone app builds" xcodebuild -project MacCast.xcodeproj -scheme MacCast \
        -configuration Debug -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED_DATA_DIR" CODE_SIGNING_ALLOWED=NO build
    step "Mac host builds" xcodebuild -project MacCast.xcodeproj -scheme MacCastHost \
        -configuration Debug -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA_DIR" CODE_SIGNING_ALLOWED=NO build
fi

rm -f "$LOG"
exit "$failed"
