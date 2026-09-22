# Nine streams: what landed, what is in flight

Written 22 September 2026, when the work was stopped so the machine could leave the network. Every
branch and every worktree below is separate: nothing here depends on another being finished, and
nothing is lost if `/tmp` is tidied, because every stream is committed on its own branch in this
repository. `git worktree list` names them; a worktree that has been cleaned away comes back with
`git worktree add /tmp/maccast-wt-<name> wt/<name>`.

## Landed on `welcome-flow-and-fixes`

Everything in this section is merged, and after each merge the two schemes were rebuilt and both
test suites were run: **178 XCTest cases and 32 swift-testing cases pass**, and the iPhone and Mac
host targets both build.

- **The pill says a word, not a millisecond figure.** A connection that is fine says nothing, a
  slightly slow one says "Slow", a properly slow one says "Very slow". `LatencyQuality` in
  `MacCastKit` holds the bands, which used to be `ColorPalette.reading`'s private opinion. The
  figure is still in the expanded pill and the Sessions tab.
- **The source you were last in comes back.** Recorded per Mac device id, restored when the
  catalogue still lists it, after any remembered mosaic and never over a default the app picked for
  itself. `ChosenSource.swift`.
- **A reconnect is one history row.** The record keeps its id and start and sums connected time;
  the relay meter counts connected seconds only. The Sessions detail shows a "Connected" row beside
  "Duration" only when the two printed figures differ.
- **The meter counts the window, not the whole record.** Each stretch is clipped to the 24-hour
  window, for finished records and live sessions alike, mirroring `Relay/src/quota.rs`.
- **How often the picture went around the relay**, in the Sessions tab: a share with its count
  behind it ("40%, 2 of the 5 sessions that left this network") and picture bytes per second direct
  against relayed.
- **A phone-shaped virtual display on the Mac**, opt-in in the host window. Verified from the probe
  by hand: a real display appears at `-1290,0` sized 1290×2796, the catalogue offers it as "Peering
  Phone Display", it streams like any display, and it goes away on release and on `kill -9`. It
  needs **no protocol change at all**: it is an ordinary `CaptureSource.display(id)`.
- **The host shows what it costs.** CPU, memory and the bytes it actually sent, in a Resources card
  on the Overview pane, this process only.

## In flight, stopped mid-work

These are on their own branches and were committed as `WIP: <name> interrupted mid-flight`. **They
are not finished and they are not merged.** The last thing each stream said is worth more than the
diff:

- **`wt/tmux`** (terminal attachments). Last words: "The iOS build caught two real errors: my
  argument order and a missing forwarder. Fixing both." **So this branch does not build yet.**
  Somewhere in it is a tmux listing, the decision not to use `attach -d`, and the intent that a
  detached client leaves the tmux session alive.
- **`wt/recording`** (session recording). Last words: "Two serious findings from the spec review.
  Let me verify one API, then fix the race and the un-hooked path." So it found at least one race
  and one path that was not wired, and had not fixed them. Treat the recorder as a draft.
- **`wt/attention`** (attention from the user's own terminals). The shell side reproduced 5 times
  out of 5 in isolation; it was chasing a condition its reproduction did not share with the test
  (keeping the write end of the socket open). This is the stream closest to finished.
- **`wt/tour`** (more onboarding pages, landscape frames). Mid-scene: drawing the terminal page.
  The landscape pages draw their feature in the app's own visual language rather than showing a
  portrait capture in a landscape frame, and the two are the same slot so a real capture can
  replace the drawing.

## What is verified, and what is not

Proven on this machine: the mosaic's Mac half end to end (a composited canvas that plays, 9 tiles
trimmed to 6, a huge canvas trimmed, 60 fps running at 30, the vertical flip by two colours); the
virtual display appearing and leaving; the resource sampler's numbers against a burning machine and
against `/usr/bin/time -l`; 178 plus 32 tests.

**Not proven, and each needs a person with a device and a free Mac:**

1. **An iOS client decoding a composited canvas.** The mosaic's whole risk sits here. Quit the
   installed host, run the new build, connect, open Mosaic in the sources panel.
2. **The virtual display switch, clicked.** The mechanism is probe-verified; nobody has flipped it
   in the running app.
3. **The host Resources card, on screen.** Its numbers are proven; its layout is compile-verified.
4. **Session recording and terminal attention**, both of which need a live session to mean
   anything.

## Findings worth carrying forward

- **`task_info(TASK_BASIC_INFO)` returns `KERN_SUCCESS` and its CPU fields never move on Darwin
  27.** Two seconds of burning four threads moved them by zero. The resource card uses `getrusage`.
  A 0.0% CPU reading is the kind of wrong that looks like good news.
- **`SCScreenshotManager` photographs only windows that are on screen, and the host offers every
  window on every Space.** An application whose windows are all on another desktop is listed,
  selectable and streamable, and its still is refused with *"Failed to start stream due to
  audio/video capture failure"* — the same error a denied permission gives, which is what makes it
  a trap. Measured with `Tools/CaptureProbe --thumbnails`: with Chrome, Mail, Notes and Terminal
  running, the only application photographed was the one whose window the window server listed as
  on screen, and the failed set changed as the user changed desktops. `isOnScreen` on every
  window is the tell, and it is **false for all of them** on a Mac showing one desktop. This is the
  same rule `captureActiveSpacePreview()` already documents from the other direction — "a desktop
  in front is the only one ScreenCaptureKit can photograph" — and the fallback is the source's
  icon, which is what a tile draws when there is no picture.
- **It is not a rate limit and not the crop.** Four concurrent captures, one at a time, and one
  per 300ms all produced the same failures and the same successes; taking `sourceRect` out of the
  configuration changed nothing. The filter shape is not the cause either: a two-window
  application on screen photographs fine through `display + including:[application] + sourceRect`.
  An application *off* screen fails through every filter, including
  `desktopIndependentWindow`.
- **`CGVirtualDisplay` has no `setTerminalID:` on macOS 27** (it is `setSerialNumber:`, and sending
  the other raises an uncatchable exception), and `hiDPI` does not make a display dense. Selectors
  were read off the class rather than copied from the header everyone copies from.
- **AppKit does not list a virtual display in `NSScreen.screens`** even though CoreGraphics does, so
  the catalogue names it through its own registry and the host refreshes the catalogue explicitly.
- **A restored `.application(pid)` can match a different app that has since been given the same
  pid.** The same exposure exists in the mosaic. Fixing it needs the bundle identifier in the
  record.
- **`AutoQualityPolicy` still tunes a punched session as though it were relayed** (item 2 of
  `HANDOFF-direct-path.md`), which is why the new direct-path card makes no claim about the cap.
- **Several doc comments are duplicated verbatim** in `SessionModel+Input.swift`,
  `HostStatusView+Session.swift` and `HostStatusView+Settings.swift`. It looks like a bad merge from
  an earlier day and it is untouched.
