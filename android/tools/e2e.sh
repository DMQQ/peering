#!/usr/bin/env bash
# End to end run of the debug build on a real phone. Usage: android/tools/e2e.sh <adb-serial> [output-dir]
# Installs nothing: put the debug build on the phone first, unlock it and open the app once. See android/tools/README.md.
set -u

SERIAL="${1:-}"
[ -n "$SERIAL" ] || { echo "usage: $0 <adb-serial> [output-dir]" >&2; exit 2; }
OUT="${2:-${TMPDIR:-/tmp}/peering-e2e-$(date +%Y%m%d-%H%M%S)}"
PKG=pl.dmq.peering
RECEIVER="$PKG/.debug.DebugCommandReceiver"
ADB=(adb -s "$SERIAL")
mkdir -p "$OUT"

RESULTS=()
FAILED=0
SHOT=0
LAST=""

record() { # status name detail
  RESULTS+=("$1|$2|${3:-}")
  [ "$1" = FAIL ] && FAILED=1
  printf '%-5s %s %s\n' "$1" "$2" "${3:-}"
}

cmd() { # name [arg]: one broadcast, the same handlers the buttons run
  local name="$1" arg="${2:-}"
  "${ADB[@]}" shell "am broadcast -a pl.dmq.peering.debug.CMD -n $RECEIVER --es cmd '$name' --es arg '$arg'" >/dev/null 2>&1
}

dump_count() { "${ADB[@]}" logcat -d -s PEERTEST:I 2>/dev/null | grep -c '"framesReceived"'; }

dump() { # prints the newest state line, waiting for a fresh one
  local before i
  before=$(dump_count)
  cmd dump
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    if [ "$(dump_count)" -gt "$before" ]; then
      "${ADB[@]}" logcat -d -s PEERTEST:I 2>/dev/null | grep '"framesReceived"' | tail -1 | sed 's/^.*PEERTEST: *//'
      return 0
    fi
  done
  echo '{}'
}

jget() { # key (dotted for nested); prints null when missing
  python3 -c '
import sys, json
try:
    value = json.loads(sys.stdin.read())
    for part in sys.argv[1].split("."):
        value = value.get(part) if isinstance(value, dict) else None
except Exception:
    value = None
print("null" if value is None else str(value).lower() if isinstance(value, bool) else value)' "$1"
}

get() { dump | jget "$1"; }

# wait_for key regex timeout: polls the dump until key matches ^(regex)$
wait_for() {
  local key="$1" regex="$2" timeout="${3:-15}" end now
  end=$(( $(date +%s) + timeout ))
  while :; do
    LAST=$(get "$key")
    printf '%s' "$LAST" | grep -Eq "^($regex)$" && return 0
    now=$(date +%s)
    [ "$now" -ge "$end" ] && return 1
    sleep 0.7
  done
}

shot() {
  SHOT=$((SHOT + 1))
  "${ADB[@]}" exec-out screencap -p > "$OUT/$(printf '%02d' "$SHOT")-$1.png" 2>/dev/null
}

# step name command-args... ; key regex timeout : runs a command, then expects the state to follow
step() { # name cmd arg key regex [timeout]
  local name="$1" c="$2" a="$3" key="$4" regex="$5" timeout="${6:-15}"
  cmd "$c" "$a"
  if wait_for "$key" "$regex" "$timeout"; then
    record PASS "$name" "$key=$LAST"
    return 0
  fi
  record FAIL "$name" "expected $key in ($regex), got $LAST"
  shot "fail-$name"
  return 1
}

# --- run ---------------------------------------------------------------------------------------
"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "no device with serial $SERIAL" >&2; exit 2; }
START=$("${ADB[@]}" shell "date '+%m-%d %H:%M:%S.000'" | tr -d '\r')

"${ADB[@]}" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
if wait_for tab 'connect|sessions|faq|settings' 30; then
  record PASS launch "tab=$LAST"
else
  record FAIL launch "no state from the app (locked, not a debug build, or not started): $LAST"
  printf '\nOutput: %s\n' "$OUT"; exit 1
fi
cmd onboarding skip
cmd tab connect
shot launch

for tab in connect sessions faq settings; do
  step "tab-$tab" tab "$tab" tab "$tab" 8 && shot "tab-$tab"
done
cmd tab connect

if step connect-trusted connect trusted phase 'Ready' 60; then
  RESULT_PATH=$(get routePath)
  if [ "$RESULT_PATH" = RELAY ]; then record FAIL route-lan "session is on RELAY, expected LAN"; else record PASS route-lan "routePath=$RESULT_PATH"; fi
  if wait_for picture 'LIVE' 30; then
    record PASS picture-live "picture=$LAST"
    first=$(get framesReceived); sleep 3; second=$(get framesReceived)
    if [ "$second" -gt "$first" ] 2>/dev/null; then record PASS frames-increase "$first -> $second"
    else record FAIL frames-increase "$first -> $second (a still screen sends few frames: change something on the Mac)"; fi
    shot session
  else
    record FAIL picture-live "picture=$LAST"
  fi

  sleep 3
  step pill-open pill open pillExpanded true 8
  step pill-close pill close pillExpanded false 8
  for panel in apps keyboard clipboard shortcuts settings; do
    if [ "$panel" = keyboard ]; then key=keyboardShown; want=true; else key=openPanel; want=$panel; fi
    step "panel-$panel-open" panel "$panel" "$key" "$want" 8 && shot "panel-$panel"
    cmd panel close
    wait_for openPanel none 8 && wait_for keyboardShown false 8 \
      && record PASS "panel-$panel-close" "closed" || record FAIL "panel-$panel-close" "openPanel=$(get openPanel) keyboardShown=$(get keyboardShown)"
  done

  step dock-expand dock expand dockExpanded true 8 && shot dock-expanded
  step dock-collapse dock collapse dockExpanded false 8
  pages=$(get dockPages)
  if [ "$pages" != null ] && [ "$pages" -gt 1 ] 2>/dev/null; then step dock-page dock 'page 1' dockPage 1 8
  else record SKIP dock-page "dockPages=$pages"; fi

  step hub-agents hub agents hubTab agents 15 && shot hub-agents
  record PASS hub-agents-list "atRoot=$(get hubAtRoot.agents) sessions=$(get agentSessions) resumable=$(get agentsResumable)"
  step hub-terminals hub terminals hubTab terminals 15 && shot hub-terminals
  record PASS hub-terminals-list "cards=$(get terminalCards) atRoot=$(get hubAtRoot.terminals)"
  step hub-files hub files hubTab files 15
  cmd files-open '~'
  if wait_for filesEntries '[0-9]+' 20; then record PASS files-home "entries=$LAST path=$(get filesPath)"; shot files-home
  else record FAIL files-home "filesEntries=$LAST failure=$(get filesFailure)"; fi

  home=$(get filesPath); found=""
  for name in README.md README.txt README readme.md notes.txt; do
    cmd files-preview "$home/$name"
    if wait_for previewComplete true 6 && [ "$(get previewPath)" = "$home/$name" ]; then found="$name"; break; fi
  done
  if [ -n "$found" ]; then
    record PASS files-preview "$found"; shot files-preview
    cmd back
    if wait_for previewPath null 8; then record PASS back-preview-to-list "preview closed"; else record FAIL back-preview-to-list "previewPath=$LAST"; fi
  else
    record SKIP files-preview "no README or text file in the home folder"
  fi

  backs=0
  while [ "$(get sessionRoute)" != REMOTE ] && [ "$backs" -lt 8 ]; do cmd back; backs=$((backs + 1)); sleep 1; done
  if [ "$(get sessionRoute)" = REMOTE ]; then record PASS back-to-closed "$backs backs from the hub to the remote screen"
  else record FAIL back-to-closed "still $(get sessionRoute) after $backs backs"; fi

  before=$(get clipboardHistory)
  cmd clipboard-send "peertest-$(date +%s)"; sleep 1
  if [ "$before" = null ]; then record SKIP clipboard-history "this build reports no clipboardHistory"
  elif wait_for clipboardHistory "$((before + 1))|$((before + 2))" 8; then record PASS clipboard-history "$before -> $LAST"
  else record FAIL clipboard-history "was $before, now $LAST"; fi


  cmd disconnect
  if wait_for connectStage 'Hosts|FirstConnection' 15; then record PASS disconnect "connectStage=$LAST"
  else record FAIL disconnect "connectStage=$LAST"; fi
  shot after-disconnect
fi

crashes=$("${ADB[@]}" logcat -d -b all -T "$START" 2>/dev/null | grep -Ec "Process: $PKG|AndroidRuntime.*$PKG")
"${ADB[@]}" logcat -d -b all -T "$START" > "$OUT/logcat.txt" 2>/dev/null
if [ "$crashes" = 0 ]; then record PASS no-crash "none for $PKG"; else record FAIL no-crash "$crashes crash lines, see $OUT/logcat.txt"; fi

printf '\n%-5s %-24s %s\n' RESULT CHECK DETAIL
for row in "${RESULTS[@]}"; do IFS='|' read -r status name detail <<<"$row"; printf '%-5s %-24s %s\n' "$status" "$name" "$detail"; done
printf '\nOutput: %s\n' "$OUT"
exit "$FAILED"
