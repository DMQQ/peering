#!/bin/bash
# Take the Mac host off this machine, and put the machine back the way it was.
#
#   Tools/uninstall-host.sh                # undo the sleep settings, then remove the app
#   Tools/uninstall-host.sh --keep-app     # undo the sleep settings only
#
# **Why this exists at all.** One setting the host can change outlives it: `pmset -a disablesleep 1`
# is a machine setting, not a process, so it survives the app quitting, the app crashing, a reboot,
# and the app being deleted. A Mac left holding it will not sleep with its lid shut and nothing on
# screen will say why. macOS gives an app no hook when it is deleted, so there is no code of ours
# left to undo it. This script is that code, run deliberately, and the app's own Settings pane has
# the same button for the case where the app is still here.
#
# It is deliberately loud about what it changed and what it could not, because the failure mode of
# a cleanup script is a person believing it worked.

set -euo pipefail

APP="/Applications/Peering.app"
RULE="/etc/sudoers.d/peering-sleep"
PMSET="/usr/bin/pmset"

KEEP_APP=0
[ "${1:-}" = "--keep-app" ] && KEEP_APP=1

say() { printf '%s\n' "$*"; }

# --- 1. The app has to stop, or it will put the setting back ------------------
#
# Quitting first is not tidiness: a running host restores the setting on its way out and repairs it
# at the next launch, so anything this script does while it is running is undone a second later.

if pgrep -x Peering > /dev/null 2>&1; then
    say "==> quitting Peering"
    osascript -e 'quit app "Peering"' 2>/dev/null || true
    for _ in $(seq 1 20); do
        pgrep -x Peering > /dev/null 2>&1 || break
        sleep 0.5
    done
    if pgrep -x Peering > /dev/null 2>&1; then
        say "    still running; quitting it the hard way"
        pkill -x Peering || true
        sleep 1
    fi
fi

# --- 2. Normal sleep, then the rule that let the app change it ----------------
#
# That order and not the other one. The rule is what lets the app turn the setting off later, so
# removing it first would leave a Mac that cannot sleep with nothing left to undo it with, which is
# the exact trap this script is here to close.

if $PMSET -g | grep -q "SleepDisabled[[:space:]]*1"; then
    say "==> sleep is disabled on this Mac; putting it back"
    sudo $PMSET -a disablesleep 0
else
    say "==> sleep is already normal"
fi

if [ -f "$RULE" ]; then
    say "==> removing $RULE"
    sudo /bin/rm -f "$RULE"
else
    say "==> no administrator rule to remove"
fi

# --- 3. The app --------------------------------------------------------------

if [ "$KEEP_APP" -eq 0 ] && [ -d "$APP" ]; then
    say "==> removing $APP"
    /bin/rm -rf "$APP"
elif [ -d "$APP" ]; then
    say "==> leaving $APP in place"
fi

# --- 4. Say what the machine actually looks like now, not what was attempted --

say ""
say "==> checking, rather than assuming"

FAILED=0

if $PMSET -g | grep -q "SleepDisabled[[:space:]]*1"; then
    say "    sleep is STILL DISABLED. Run: sudo $PMSET -a disablesleep 0"
    FAILED=1
else
    say "    sleep: normal"
fi

if [ -f "$RULE" ]; then
    say "    $RULE is STILL THERE. Run: sudo /bin/rm -f $RULE"
    FAILED=1
else
    say "    administrator rule: gone"
fi

if [ "$KEEP_APP" -eq 0 ] && [ -d "$APP" ]; then
    say "    $APP is STILL THERE"
    FAILED=1
else
    say "    app: gone"
fi

# The launch-at-login entry is registered with the system rather than written by us, and macOS
# clears it when the app it points at disappears. Named here because it is the one thing this
# script does not do itself, and a person deserves to know which parts were somebody else's job.
say ""
say "    'Open at login' was registered with macOS, which drops it when the app is gone."
say "    The Mac's own preferences for the app are left alone; they are a few lines in"
say "    ~/Library/Preferences and hold nothing you would miss."

if [ "$FAILED" -ne 0 ]; then
    say ""
    say "==> something did not take. The commands above are what is left to do."
    exit 1
fi

say ""
say "==> done."
