# Continuing after the multi-Mac work

Written 20 September 2026. Start by reading `AGENTS.md` and `HANDOFF-multi-mac.md`, then this.

## The situation you are walking into

**Two agents work in this repository at once, in the same working tree.** One is on the network
and resource-management side (session teardown, sockets released on disconnect). If you are the
other one, do not assume `git status` is yours. A file can change under you mid-edit; that
happened repeatedly and cost real time.

- Build with a private `-derivedDataPath /tmp/maccast-dd`. The default DerivedData is a shared
  lock and the failure reads as `database is locked`, which looks like nothing to do with the
  cause.
- Run `git status` before and after every edit.
- Commit only your own files. If one of your commits will not build without a file of theirs,
  say so in the commit body rather than leaving a broken commit. That happened once already.

## Where the work stands

Branch `welcome-flow-and-fixes`, pushed to origin. Twelve commits of this work, newest first:

    48e5c29  Offer the switch that keeps a Mac reachable where people look for it
    0fa76f5  Put the iPhone app on today's build number
    884484b  Build the sound switch the session panel claimed to have
    fcd02d1  Let the card name the Mac it is actually about
    fe59b50  Bring an open Mac to the front instead of dialling it twice
    ea1e531  Make the chrome, the card and the banners tell the truth per Mac
    489643f  Silence the Mac that is not on screen
    8d593a8  Stop waking the CPU for a queue that is empty
    a45daf1  Hold several Macs open at once, and switch between them
    f912b56  Gate a second Mac at once, and say what it is
    3955e43  Let the phone ask a Mac for its picture, and time the answer
    42988bc  Give every Mac its own session, and keep it to one

**Stages 1, 3, 4 and 6 of `HANDOFF-multi-mac.md` are done. Stage 2 was already built by an earlier
session and was verified rather than rebuilt. Stage 5 is partly done.**

### What is left in stage 5

1. **The strip does not collapse with the status pill in landscape.** It is always visible when
   more than one Mac is open. The decision in the handoff was: collapses with the pill in
   landscape, permanent in portrait.
2. **`SessionTabs` is a second copy of `TerminalPanel.tabStrip`.** The handoff asks for one shared
   component; they will drift otherwise.
3. **The widget work is done**, and so are the Live Activity, notifications, audio, chrome frames,
   Siri and the teardown paths. Do not redo those.

### The two features that were asked for and not started

- **Clipboard images.** `ClipboardPayload(text:)` and `MessageKind.clipboardContent` carry a
  string and nothing else, so copying a screenshot in either direction does nothing. This wants a
  kind discriminator, a size cap (mirror `previewByteLimit` for pictures), a decision about which
  pasteboard types are worth carrying, and `NSPasteboard` image read and write on the host. It
  touches `RemoteCore`, which the other agent is also in.

- **File transfer.** Three separate things: the 64 MB `maximumUploadBytes` cap needs streaming
  rather than reading whole files into memory, folder transfer needs a recursive protocol with
  per-entry results, and drag-and-drop into Files wants time on the iPad target (the app is
  universal, `TARGETED_DEVICE_FAMILY = "1,2"`).

Microphone streaming was explicitly deferred.

## Traps that cost time here

- **Xcode cannot run this project's test action at all.** `xcodebuild test` fails to link the
  package products. Policy that can be wrong silently therefore lives in `MacCastKit` or
  `RemoteCore` and is run with `swift test` in that package. A rule left in the app target is a
  rule nobody checks.
- **`git tag` sorts lexicographically.** `v0.1.10` sorts above `v0.1.5`, so `git tag | tail` does
  not show the newest tag. Use `git tag | sort -V | tail`. This produced two wrong reports in one
  session.
- **Range deletion in these dense Swift files is unsafe.** Cutting a line range has twice taken
  neighbouring declarations with it. Verify afterwards by diffing the declaration list against
  `HEAD`.
- **The relay deploy script polls CI for a release asset.** Do not pipe it through `tail`: the
  exit code belongs to `tail` and a dead relay reports as success. Capture the status properly.
- **`kIOPMAssertionTypeNoDisplaySleep` and `PreventUserIdleSystemSleep` are different things.** A
  Mac whose display has gone dark is still fully reachable: terminals, SSH, clipboard and file
  browsing all work, and only the picture is black. What breaks everything is the *system*
  sleeping.

## What has never been verified

**Nothing has run with two Macs.** There was no second Mac to pair with. Every multi-Mac path —
the switch, the strip drawing, its chrome frame blocking a touch, paired audio, the gate in front
of a real purchase — is compile-and-test verified only. Before release, connect two Macs and walk
the strip.

The resume interval (`MacSession.lastResumeMilliseconds`, printed in the diagnostics blob) has
never produced a number, for the same reason.

## Before TestFlight

The version numbers were bumped to `202609200` and verified from a real archive. If a
`202609200` iPhone build has already been uploaded today, the next one needs `202609201`: the
scheme is date-based, one number per day. The iOS deployment target is 18.0. It was 26 because
`glassEffect` was the app's only iOS 26 API and every panel called it directly; that call now sits
behind `glassSurface(in:interactive:)` in `Theme.swift`, which falls back to a tinted material
below 26. The floor is a build setting again rather than a property of the design, and the Mac
host went the same way at 15.0 so it can ship universal.
