#!/bin/bash
# The UI tests on an iPhone simulator, with the scheme that lists only them.
#
#   Tools/ui-tests.sh                         # every UI test
#   Tools/ui-tests.sh AgentApprovalFlowTests  # one class, or Class/testName for one test
#   UI_TEST_DEVICE=<udid> Tools/ui-tests.sh   # a specific simulator (default: iPhone 17 Pro)
#
# Private DerivedData so a second session building at the same time does not hit "database is
# locked". The log is only shown on failure, because piping a build through tail makes the exit
# code tail's.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${TMPDIR:-/tmp}/PeeringUITestBuild"
LOG="$(mktemp)"
cd "$REPO_DIR"

destination="platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
if [ -n "${UI_TEST_DEVICE:-}" ]; then
    destination="platform=iOS Simulator,id=$UI_TEST_DEVICE"
fi

only=()
if [ -n "${1:-}" ]; then
    only=(-only-testing:"MacCastUITests/$1")
fi

printf "==> UI tests on %s\n" "$destination"
if xcodebuild test -project MacCast.xcodeproj -scheme MacCastUI -destination "$destination" \
    -derivedDataPath "$DERIVED_DATA_DIR" CODE_SIGNING_ALLOWED=NO ${only[@]+"${only[@]}"} >"$LOG" 2>&1; then
    grep -E "^Test Case .* (passed|failed)|Executed [0-9]+ tests" "$LOG" | sort -u
    echo "    ok"
    status=0
else
    echo "    FAILED"
    grep -E "error:|✘|failed|\*\* TEST" "$LOG" | sort -u | head -40
    status=1
fi

rm -f "$LOG"
exit "$status"
