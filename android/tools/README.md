# Debug test harness

A debug build can be driven and read from a shell, so a run on a real phone needs no taps at pixel coordinates. The
harness is not in release builds: the receiver lives in `app/src/debug` only, and the bridge it reads (`TestBridge`)
stays empty unless `BuildConfig.DEBUG`.

## Commands

```
adb -s SERIAL shell "am broadcast -a pl.dmq.peering.debug.CMD -n pl.dmq.peering/.debug.DebugCommandReceiver --es cmd tab --es arg sessions"
```

Each command runs the same handler the matching button runs. Acknowledgements go to logcat tag `PEERCMD`
(`ran ...`, `unsupported ...` when no screen on display offers the action, `rejected ...`).

| cmd | arg |
| --- | --- |
| `tab` | `connect`, `sessions`, `faq`, `settings` |
| `connect` | `trusted` (first trusted computer) or a host id |
| `disconnect` | none |
| `back` | none (system back) |
| `hub` | `agents`, `terminals`, `files`, `close` |
| `panel` | `apps`, `keyboard`, `clipboard`, `shortcuts`, `settings`, `close` |
| `pill` | `open`, `close` |
| `dock` | `expand`, `collapse`, `page N` |
| `terminal-list` | none (opens the Terminals tab) |
| `files-open` | a path, or none for the home folder |
| `files-preview` | a path |
| `clipboard-send` | text, up to 500 characters (pushes it to the computer's clipboard) |
| `clipboard-history` | none (offered once the clipboard history lands) |
| `mosaic` | `start`, `stop` (offered once the mosaic lands) |
| `onboarding` | `reset`, `skip` |
| `dump` | none |

`dump` logs one JSON line under tag `PEERTEST`. Keys: `tab`, `connectStage`, `onboarding`, `sessionRoute`, `phase`,
`failure`, `hostName`, `routePath`, `picture`, `framesReceived`, `lastFrameAgeMs`, `openPanel`, `pillExpanded`,
`dockExpanded`, `dockPage`, `dockPages`, `immersive`, `keyboardShown`, `hubTab`, `hubOffered`, `hubAtRoot`,
`filesPath`, `filesEntries`, `filesLoading`, `filesFailure`, `previewPath`, `previewComplete`, `terminalCards`,
`agentSessions`, `agentsResumable`. A key is missing or null while the screen that owns it is not on display.
`framesReceived` counts frames the session delivered to the picture, not frames the decoder drew.

A new screen joins by calling `BridgeRegistration(name) { TestBridge.Slot(state = ..., actions = ...) }`; an action
name that `DebugCommand` allows is then reachable from the shell.

## Safety rules

- There is no command that sends a key or mouse input, starts a shell or an agent, or deletes, renames or writes a
  file on the computer. Add none. `DebugCommand.parse` is the whitelist; anything else is rejected.
- `dump` reports the host name, the home folder path and counts, never file contents, names, terminal output, chat text
  or clipboard text.
- Screenshots show whatever is on the phone. The run does not unlock the phone or the app lock; do that first.
- Run only against a debug build you installed yourself. The receiver is exported so that `adb` can reach it.

## End to end run

```
./gradlew :app:installDebug          # or install the debug APK another way; the script installs nothing
android/tools/e2e.sh SERIAL [output-dir]
```

Unlock the phone and open the app once. The script launches it, skips the tour, then checks in order: launch, each root
tab, connect to the first trusted computer (picture live, frames rising, route not relay), pill, the five panels, the
dock, the hub's three tabs, a README preview in the home folder, back out to the remote screen, a clipboard send,
disconnect, and no crash for the package in logcat. It polls the `PEERTEST` dump with timeouts, saves screenshots and
`logcat.txt` to the output folder (default under `$TMPDIR`), prints a PASS/FAIL/SKIP table and exits 1 on any FAIL. SKIP
means the build or the home folder lacks what the check needs (no README, no clipboard history yet, one dock page).

## Not testable this way

Real touch, gestures and drag (joystick, pinch, swipe, scroll wheel); the system pickers and permission dialogs;
biometric unlock and the app lock; keystrokes and terminal or agent sessions (deliberately absent); the video's pixels
(only frame counters and the picture state are read, screenshots need a person or a model to judge); relay and direct
paths other than the one the phone picks; anything on a screen that is not composed.
