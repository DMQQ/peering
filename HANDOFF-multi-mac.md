# Several Macs at once

**Why.** Owning two Macs and reaching one of them is the ordinary case today: you connect, you
work, you end the session, you connect to the other one, and the second connection pays the whole
price of the first. The handshake, the pairing, the video socket, the wait for the first keyframe.
Worse, the Mac you left is now out of session, so its screen locks and its display sleeps, and
coming back to it is a wake, a handshake, and a login at the other end.

**What is decided, and what this document argues for.** Hold a live control channel to every Mac
the user has open, and stream video for the **active one only**. Switching tabs is then a control
message and a keyframe, not a connection. The expensive parts stay singular: one decoder, one audio
player, one input path, one video pipeline, one renderer, one display layer.

**Why not two streams.** Two concurrent video streams would double the battery draw: two hardware
decoders running, two layers being composited, two audio engines, and the radio carrying twice the
bytes for one person looking at one screen. On the relay it also doubles the operator's bandwidth
for the same user, which is the one cost in this project that is real money rather than a
conversion lever, and it is the cost `PlanCapability/highBitrate` exists to sell against. The
design that gives the felt benefit without that bill is the one this document plans.

**One honest limit, stated up front.** The picture pauses on Macs you are not looking at, so the
first frame after a switch costs a capture restart on the Mac. The switch is instant in every other
sense: no handshake, no re-pairing, the Mac still awake, still unlocked, its shells still running,
its clipboard still there. It is not instant in the sense of a frame already being decoded.

## 1. Every place that assumes there is one session

This is the list the plan exists for: everywhere in the app today that reads or writes the single
session, and what it has to become. The three headings say which way each one goes.

**Moves onto the per-Mac object (split).**

- `MacCast/SessionModel.swift:118` `phase`. Becomes the active Mac's phase, and the container gains
  `activeSession` plus a derived `hasAnySession`.
- `SessionModel.swift:668` `session: ClientSession?`, the one wire client for the app's life.
- `SessionModel.swift:167` `hostName` and `:435` `currentHostID`. The container keeps only the active
  Mac's, for the status pill.
- `SessionModel.swift:205` `connectionPath`, `:214` `usedDirectPath`, `:223` `directPathStatus`,
  `:231` `datagramCounts`, `:170` `latencyMilliseconds`, `:177` `pathLatencyMilliseconds`. This is
  also what makes `videoCeiling` per Mac, which is correct: one Mac can be on the LAN while another
  is on the relay, and the plan's picture ceiling differs between them.
- `SessionModel.swift:186` `catalog`, `:564` `activeSourceID`, `:573` `picture`, `:581`
  `remoteNotice`, `:194` `videoStatus`, `:204` `videoTransport`: what the one Mac is showing.
- `SessionModel.swift:278` `audioPlayer: RemoteAudioPlayer?`, one player replaced per audio config.
  One per Mac, with the rule that only the active one plays.
- `SessionModel.swift:313` `terminals`, `:314` `selectedTerminalID`, `:338` `directories`, `:346`
  `browsingPaths`, `:349` `pendingDirectories`, `:352` `browseFailures`, `:356` `filePreview`, `:365`
  `pendingRun`, `:390` `writes`, `:398` `saveFailures`, `:399` `uploadFailures`, `:417` `changes`,
  `:426` `changeFailures`, `:263` `hostClipboard`, `:265` `clipboardPulling`. Everything keyed by a
  shell or a folder is keyed by the Mac. The Mac generates the terminal UUIDs
  (`MacCastHost/Terminal/TerminalSessionManager.swift:267`), so the keys are already globally unique.
  What is wrong today is that the deck would show two Macs' shells in one strip.
- `SessionModel.swift:189` `activeSessionHistoryID`, `:190` `activeSessionHistoryStartedAt`, `:191`
  `activeSessionBytes`, `:192` `lastBandwidthSampleBytes`, `:193` `activeSessionLogs`. The finished
  records stay app-wide: `ClientSessionRecord` already carries `hostID`, so one Sessions tab across
  all Macs is already what the data supports.
- `SessionHistory.swift:21` `relaySecondsUsedThisPeriod` and `:67` `activeSessionDuration`. It adds
  **at most one** live session to the finished records today, and that is a correctness bug the
  moment there are two: the relay charges every splice to one counter, so the estimate must sum every
  live relayed session or the bar overstates what is left.
- `SessionModel.swift:1044` `isReconnecting`, `:1057` `reconnectTask`, `:1058` `reconnectAttempt`,
  `:1069` `isResuming`. One ladder for the app today. Each Mac reconnects on its own schedule, and
  one unreachable Mac must not put the app in a connecting state.
- `SessionModel.swift:685` `userEndedSession`, read by the transition it belongs to.
- `SessionModel.swift:1011` `pendingHostID`, `:444` `remotePairingHostID`: one dial in flight.
- `SessionModel.swift:522` `sessionStartedAt`. The Live Activity's `startedAt` follows the active Mac.
- `SessionModel.swift:259` `privacyModeEnabled`, `:562` `isObserving`, `:563` `latchedModifiers`,
  `:591` `typedPreview`, `:255` `autoQualityPolicy`. State of the Mac being driven: a latched
  modifier belongs to the Mac holding it, and releasing it must be sent to that Mac.
- `MacCast/SessionModel+Events.swift:10` `apply(_:)`, the one event stream, becomes
  `apply(_:from:)` on the per-Mac object. The video-frame fast path at `:858-867` is the part that
  must not detour through the main actor, and it must also drop frames from a Mac that is no longer
  active.
- `SessionModel+Connection.swift:101` `disconnect(deliberate:)`, split into `MacSession.disconnect`
  plus a container `endAllSessions()`.
- `SessionModel+Connection.swift:281` `resumeIfNeeded`, `:314` `scheduleReconnect`, `:351`
  `stopReconnecting`. Note the guard at `:286` (`session == nil`) is also what stops a background Mac
  from re-arming on the container's timer.
- `SessionModel+Input.swift:37` `send(_:)`, through one rule: input goes to the active Mac, and
  nothing else does.

**Split between the two (both).**

- `SessionModel+Connection.swift:367` `enteringBackground` and `:432` `backgroundTimeExpired`. The
  assertion is app-wide; the teardown is per Mac. Background time running out ends **every** session.
- `SessionModel.swift:669` `videoPoll: Task?`. It polls the one renderer for fps, so it stays
  app-wide, but the auto-quality decision it feeds belongs to the Mac being watched: the policy and
  its tier move, the polling does not.
- `SessionModel.swift:604` `paywallReason`, `:620` `spentAllowance`, `:630` `relaySessionDropped`.
  One plan and one sheet, which stay app-wide, but the cut path widens: the relay drains one counter
  and cuts every splice at once.

**Stays app-wide.**

- `SessionModel.swift:653` `let renderer = VideoRenderer()`. One decoder for the app. This is the
  decision the whole design rests on.
- `SessionModel.swift:1071` `backgroundTask`, one assertion covering all sessions.
- `SessionModel.swift:595` `storeManager`, `:655` `pins`, `:656` `browser`, `:119` `hosts`, `:128`
  `relayPresence`, `:232` `pairedHostIDs`, `:433` `hostNames`, `:479` `customHostNames`, `:269`
  `hostMACAddresses`, `:447` `lastConnectedAt`, `:666` `identity`, `:667` `device`: everything about
  Macs in general.
- `SessionModel.swift:917` `clipboardHistory`, `:320` `terminalHistory`, `:1078` `customMacros`,
  `:539` `manualAddress`, `:559` `keyboardMode`, `:587` `pointerSpeed`, `:247` `streamQuality`,
  `:1033` `allowsRelay`: preferences and history rather than connections.
- `MacCastApp.swift:31` `@State private var model = SessionModel()`, which is why the container keeps
  the name.
- `ContentView.swift:20` `isRemoteScreen`, reading the container's derived question: is any Mac up.
  `RemoteScreen.swift:14` `@Environment(SessionModel.self) var model` for the same reason, with the
  per-Mac reads becoming `model.active?.x` or a forwarding property.

## 2. The shape

**One new type: `MacSession`.** An `@Observable final class`, main-actor isolated, one per Mac that
is open. It owns the `ClientSession`, the phase, the ladder, the history record in flight, the
terminals and the file browser state, the input-modifier state, and the zoom and pan for that Mac's
picture. It is the thing `SessionModel+Events.swift`, `+Connection.swift`, `+Input.swift` and
`+Terminal.swift` become extensions *of*.

**`SessionModel` stays, and stays the app-wide object.** It keeps the identity, the pins, the
browser, the store, the renderer, the preferences and every list that is about Macs rather than
about a connection. It gains:

```swift
var sessions: [MacSession]                 // open Macs, most recently activated first
var activeSessionID: String?               // the Mac's host ID
var activeSession: MacSession?             // computed, by ID
func addSession(hostID:) -> MacSession?    // the one place a second session is born, and the gate
func activate(_ id: String)
func endSession(_ id: String)
func endAllSessions()
```

**A class in an array, not a struct.** `SSHTerminal` is already this shape
(`MacCast/SSHModel.swift:21-25`) and for the same reason: output and frames arrive many times a
second, and mutating a struct held in an array invalidates every row that reads the array.

**The boundary in one sentence:** everything that dies when the connection to a Mac dies is
`MacSession`; everything that survives every connection is `SessionModel`.

**The bridge that keeps it shippable.** `SessionModel` keeps a forwarding property for every
per-Mac field the views already read, reading through to `activeSession`:

```swift
var phase: ClientSession.Phase { activeSession?.phase ?? .idle }
var hostName: String? { activeSession?.hostName }
var videoStatus: String { activeSession?.videoStatus ?? "No video stream" }
```

Because both sides are `@Observable`, reading `model.phase` in a view still tracks the underlying
change, so roughly twenty view files compile untouched and the app runs at every stage. The
forwarding properties are then retired one surface at a time, and the last stage deletes the ones
nothing reads.

**What is deliberately not done.** Not a second `SessionModel` per Mac. Every gate in the app asks
`model.storeManager` (`MacCast/SharedControls.swift:229`), the environment would need one model per
Mac or a nested environment, and the renderer, the audio session, PiP and the Live Activity are
singletons that would have to be shared anyway. The split would still happen, one boundary further
out, and the app would carry three owners of the same singletons.

**What breaks, in the compiler's terms.** `SessionModel.session` disappears in favour of
`activeSession?.session`. The four extension files convert from `extension SessionModel` to
`extension MacSession` for the split members, and `SessionModel` keeps the container members. All
of `SessionModel+Terminal.swift` (768 lines) moves. The `TerminalPanel` sheet reads the active
Mac's terminals, so its `model.terminals` becomes `model.active?.terminals ?? []` or a forwarding
property, and `selectedTerminalID` becomes per Mac.

## 3. The one wire change this needs

**There is no way today to ask a Mac to stop sending the picture while keeping the session.** That
is not an accident of the code, it is the shape of the transports themselves:

- A **direct** session's video has a socket of its own (`ClientSession.openVideoIfNeeded()`,
  `RemoteCore/Sources/RemoteCore/ClientSession.swift:1204`), and closing it does stop the Mac:
  `VideoCoordinator.videoPeerClosed` (`MacCastHost/Video/VideoCoordinator.swift:288`) detaches the
  peer and stops capture when nobody is left. But reopening it on the next switch costs a fresh TLS
  handshake, which is most of what this design is trying to avoid.
- A **relayed** session has no video socket at all. The control peer *is* the video peer
  (`HostServer.swift:431` calls `onVideoConnection?(controlPeer)`), so there is nothing to
  close that is not the session itself.
- `RemoteCommand` (`RemoteCore/Sources/RemoteCore/RemoteCommand.swift:66`) has eighteen cases and
  none of them is a pause. `MessageKind` (`RemoteCore/Sources/RemoteCore/Framing.swift:6`) ends at
  `directProbe = 0x1B`.

**So: one new command, `case setVideoEnabled(Bool)`, and it is the whole of the protocol change.**

- The phone sends `false` when a tab stops being active and `true` when it becomes active again. It
  is sent to that Mac only, on the control channel it already has.
- The Mac handles it in `VideoCoordinator`: `false` does what `videoPeerClosed` does (detach the
  peer from the streamer, `forgetTransportChoiceLocked`, stop capture if no other audience is left)
  but **does not close the connection**, so the session, its terminals and its sleep assertion all
  survive. `true` does what `handleVideoConnection` does (attach, ask for a keyframe), which is the
  same path a reconnecting client already takes.
- The host's audience logic is already per-peer, so a second phone watching the same Mac is
  unaffected by this phone pausing.
- The picture's own state survives: `activeSourceID` stays chosen on both sides, and the Mac's
  capture source is remembered (`sourceWasChosen` is cleared only on a real detach, which is why
  the pause path must go through the same function rather than around it).

**How it is versioned is a decision, and it is the one decision here that can lock users out.**

- **Option A, the repo's rule.** Add the case and bump `ProtocolInfo.version` to 13. The precedent
  is explicit (`ProtocolInfo.swift:13-16`, and every version from 7 to 12): an unknown command is a
  decode failure in the middle of a session, so the bump turns a mixed pair into "update whichever
  is older" at the handshake. The cost: a user who updates the phone cannot reach a Mac that has not
  updated, and Macs update on their own schedule.
- **Option B, a capability flag.** `ServerHello.macAddresses` is already an optional additive field
  (`Handshake.swift:40`), so `supportsVideoPause: Bool?` costs nothing and breaks nothing. The phone
  sends the command only when the Mac says it can take it. An un-updated Mac stays reachable; the
  second tab's picture simply keeps streaming on it, and that is a thing the app can say.

**Recommendation: B, with A held in reserve.** The version rule exists because the commands it was
written for are sent by every session, so a mixed pair fails at some unpredictable moment. This
command is conditional by construction and has an honest degradation. The host half still ships
first, either way, so the phone is never the only end that knows the command.

## 4. The stages

Each stage runs, ships and is testable on its own. The order is chosen so that the riskiest thing
(the picture coming back) is proved on one Mac before a second one exists.

### Stage 1: the split, with one session

`MacSession` is created and everything per-Mac moves onto it. `SessionModel.sessions` exists but can
only ever hold one. Forwarding properties keep every view compiling.

**Proves:** the seam is in the right place, and it proves it by being invisible. The acceptance test
is that nothing changes for a user: same phases, same reconnect, same terminals, same history. The
new unit tests are that a `MacSession` can be built and torn down without touching the shared
renderer, and that its record is filed with its own `hostID` and path.

### Stage 2: the Mac learns to pause

`setVideoEnabled` on the host, the `VideoCoordinator` path, and the `ServerHello` capability (or the
version bump, per the decision above). The phone does not send it yet.

**Proves:** the host half is inert until a client asks, a v12 phone still works against a v13 host,
and pausing is per-peer rather than per-Mac: two phones, one pauses, the other's picture does not
blink. Testable in `swift test` for the decision logic, and by hand for the capture restart.

### Stage 3: the active session, still alone

`activeSessionID` exists. The phone sends `setVideoEnabled(false)` then `(true)` on a switch, which
with one Mac means switching to the tab that is already active, so the whole path can be exercised
before a second Mac exists. The tab strip is drawn only when there is more than one session, so
nothing new is on screen yet.

**Proves:** the resume path, which is the risky half. How long after `true` does the first frame
arrive, is it a keyframe, does `awaitingKeyframe` latch, does the zoom answer to the new
`PictureIdentity`, does the audio player come back with the right format. **Do not start Stage 4
until the answer to "how long" is a number**, because a design whose whole promise is fast switching
cannot ship with an unmeasured switch.

### Stage 4: the second session, and its gate

`addSession(hostID:)`, the `+` on the strip, the picker's rows marked as connected, per-Mac ladders,
the relay's two splices, and the `PlanCapability` that gates all of it (section 6). The gate ships in
this stage, in the same release. Without it, the feature is free for as long as the gap lasts.

**Proves:** two control channels coexist without either starving the other; the inactive Mac stays
awake and unlocked (its sleep assertion is held by the host on client connect, `HostModel.swift:926`);
its shells keep running; its `ClientSession` pings and is answered; and the battery cost of a
background Mac is one control channel and nothing else, which is the number Stage 6 of this list is
about.

### Stage 5: the surfaces

The Live Activity, PiP, audio, notifications, the widget, Siri and Shortcuts, the allowance meter,
the relay's cut path, diagnostics, and the per-Mac zoom. Each is one section of section 5 below, and
each can ship on its own inside this stage.

**Proves:** that the app tells the truth about which Mac it is describing, everywhere.

### Stage 6: the cheap wins the survey turned up

The `CommandCoalescer` timer is started on connect and stopped only in `deinit`
(`ClientSession.swift:714` and `:562`), so a live but idle session wakes the CPU sixty times a second
for nothing. Three of them is a hundred and eighty. Start it on the active session, or start the
timer on the first `enqueue` and stop it when the queue has been empty for a beat.

**Proves:** measurable, with the battery pane, and it is the only stage whose result is a number on a
chart rather than a behaviour.

## 5. Each surface, one at a time

### The Live Activity: the active Mac wins

One `Activity`, one handle, `SessionActivity.shared` (`MacCast/SessionActivity.swift:25`), and no
session identity anywhere in `SessionActivityAttributes` (`Shared/SessionActivityAttributes.swift:107-160`).
The answer is that the card describes **the Mac on screen**, which is the active session, and that
is the only answer that does not require a second card.

- The container feeds `SessionActivity` from the active session's transitions, and calls it again on
  a tab switch so the name and the path follow the tab.
- `ContentState` gains `sessionCount: Int` so a card can say "2 Macs" when there are two, and the
  shared file means the widget target is rebuilt in the same commit.
- The drop case is the interesting one. Today a drop with a reconnect running shows "Reconnecting to
  X". With tabs, a *background* Mac dropping must not take the card away from the Mac on screen:
  the card follows the active session, and the background Mac's trouble arrives as a banner instead
  (see notifications below). **Decision:** whether a background Mac's drop is worth a banner at all.
  The recommendation is yes, because a background Mac failing is exactly the thing the user is not
  looking at, and holding the connection is supposed to be the reason they do not have to.
- `adoptOrphan()` (`SessionActivity.swift:182`) already ends any card left by a previous launch. No
  change.

### Picture in Picture: also the active Mac, and it follows the tab

`SessionPiP.shared` (`MacCast/VideoRenderer.swift:419`) holds one controller and one **weak** view,
bound to the shared renderer's layer. PiP therefore shows whatever the one layer is showing, which
is the active Mac, automatically, with no new state.

Two things must be respected for that to stay true:

1. **A tab switch must not rebuild `VideoLayerView`.** `SessionPiP.attach` stops an active PiP and
   rebuilds the controller on every rebind (`VideoRenderer.swift:498-501`), deliberately, because
   the old controller held a dead layer. If the tab strip swaps the screen rather than the session
   behind it, every switch kills the floating window. The layer view is mounted once, above the
   strip, and the tab strip changes what is fed to it.
2. **A tab switch while PiP is active changes the floating picture.** **Decision:** the
   recommendation is to allow it, and to say so, because the alternative is a second layer and a
   second decoder, which is the thing this whole design refuses.

### Session audio: the active Mac only, and it is silent for the others

One `RemoteAudioPlayer`, created per audio config and owned by the session
(`SessionModel.swift:278`), one `SessionAudio.shared` (`MacCast/SessionAudio.swift:30`). The answer
is that sound follows the picture: the Mac being watched is heard, the others are not.

This falls out of the design rather than being an extra rule: `setVideoEnabled(false)` stops the
Mac's stream, and the audio rides the video connection, so the frames stop arriving. The player for
each Mac is kept so that switching back restores the format without a re-negotiation, and the old
one is released when its Mac is ended (its `deinit` stops the `AVAudioEngine`).

**Decision, and it is a real one:** a background Mac playing music goes silent when you switch away
from it. That is the price of one player, and it is the same price the design already accepts for
video. Keeping a background Mac audible needs a second `AVAudioEngine`, a second `AVAudioSession`
category negotiation and mixing, and it is a feature in its own right rather than part of this one.

### Session history: already per Mac, and the record in flight is not

`ClientSessionRecord` already carries `hostID` and `hostName`
(`MacCastKit/Sources/MacCastKit/SessionHistory.swift`), and `sessionHistory` is one array the
Sessions tab already lists across all Macs. That part needs nothing.

What needs moving is the record **in flight**: `activeSessionHistoryID`, `activeSessionHistoryStartedAt`,
`activeSessionBytes`, `lastBandwidthSampleBytes`, `activeSessionLogs` all move onto `MacSession`, so
two live sessions file two records with two durations. `beginSessionHistory()`'s guard
(`SessionHistory.swift:73`, "already have one") becomes per session rather than per app, which is
the line that would otherwise silently drop the second Mac's entire record.

`relaySecondsUsedThisPeriod` (`SessionHistory.swift:21`) then sums the finished relay records plus
**every** live one. This is not tidiness: the relay charges each splice's elapsed seconds to one
counter, so two concurrent relayed sessions drain the allowance at twice the wall-clock rate, and an
estimate that counts one of them tells the user they have an hour when they have thirty minutes.

### Notifications: per Mac, or two Macs overwrite each other

`SessionAwareness.Kind.identifier` is fixed per kind, not per event
(`MacCastKit/Sources/MacCastKit/SessionAwareness.swift:19`), so a second Mac's "connected" banner
replaces the first's, and two Macs ending a session at the same moment produce one banner about one
of them. The identifier gains the host ID: `pl.dmq.peering.session.<kind>.<hostID>`, and
`retract(_:)` retracts by name for a Mac whose state has changed.

The pairing-code banner matters most here. It is time-limited, it is about a Mac nobody is sitting
at, and losing it to another Mac's banner is the failure that costs a pairing.

"Your Mac is waiting on a password" is `SessionNotifier.terminalNeedsAttention`
(`SessionNotifier.swift:99`), keyed by the terminal's UUID, which is already per Mac and per shell,
so it needs no identifier change. Its **body** should gain the Mac's name: two Macs can both have a
shell called `prod`, and the notification is read on a locked screen with no other context.

### The reconnect ladder and the ten-second silence rule

Both rules live in `ClientSession` and are already per session: `ControlSilence`
(`ClientSession.swift:422`) turns a silent control channel into a failure, and the ladder is five
attempts over about forty seconds (`SessionModel.swift:1053`). What is app-wide today is the ladder's
*state*, and it moves onto `MacSession`:

- One Mac being unreachable must not put another Mac's tab into a connecting state, so
  `isReconnecting` becomes a per-session read and `ContentView` asks about the active one.
- The background assertion is taken while **any** session is live or reconnecting, and released when
  none is.
- `backgroundTimeExpired()` ends **every** session, not one: iOS granted a few seconds and they are
  all about to be suspended, so ending one and leaving two to be killed unobserved is the worst of
  the three outcomes. The Live Activity and the banner say what happened.
- A background Mac going quiet now produces a banner the user never got before. That is intended,
  and it is also why the background Macs must have their **video** paused and their **control
  channel left alone**: the silence rule is measured against the one-second ping, and a Mac that has
  been muted at the application layer must still be answering at the transport layer or the ladder
  will fire on a session that is perfectly healthy.

### Siri and Shortcuts: connect opens a tab, and "stop" means stop

`ConnectToMacIntent` already takes an optional Mac and dials it
(`MacCast/PeeringIntents.swift:110`). It gains one step: with the container, it opens that Mac's
session if it is not open, and it makes it the active tab either way.

`DisconnectIntent` is the decision. Today it is "end the current session", and with tabs there are
two readings.

- **Recommended: "Disconnect" ends every session.** The phrase is "Disconnect Peering" / "Stop
  Peering", and a user saying that to their phone means stop the app, not stop one of the three
  things it is doing. It also keeps the sentence honest without a follow-up question.
- The alternative, a parameterised "Disconnect from \(mac)" added beside it and the bare phrase
  narrowed to the active tab, is more precise and is a worse spoken interface: it turns "stop" into
  a question about which Mac.

Either way `openAppWhenRun = false` stays, for the reason it already has: with the app not running
there are no sessions, and bringing it forward to say so is the opposite of what was asked.

### The widget, and "the Mac you used last"

`SharedStore` carries `lastHostName`, `knownMacs` and `knownServers`
(`Shared/SessionActivityAttributes.swift:29-87`). Two changes:

1. **"Last used" means last looked at, not last connected to.** `lastHostName` is written from
   `connect(to:)` and from the handshake (`SessionModel.swift:740`, `SessionModel+Events.swift:170`).
   With tabs, both must also be written when the **active** session changes, or the widget's small
   tile offers the Mac you connected to first rather than the one you were using.
2. **The widget should show which Macs are open.** `SharedStore` gains `connectedMacIDs: [String]`
   and `activeMacID: String?`, and the medium tile marks them. The app already reloads the timeline
   from the four moments the list changes (`publishKnownMacs`, `SessionModel.swift:506-514`); the new
   moments (a session coming up, a session ending, a tab switch) join them, or the widget shows a
   list that was true ten minutes ago.

Same file, same app group, so the widget target and its entitlement need nothing new.

### The relay's allowance accounting: one pot, drained twice as fast

The relay's side is already correct and already plural. `Registry::allocate` supersedes only a
session for the **same pair** (`Relay/src/session.rs:504`), so a client holding sessions to three
different Macs is supported today. `QuotaTracker` keeps one `(window, seconds)` per client ID
(`Relay/src/quota.rs:342`), and each splice's `Meter` charges its own elapsed seconds to that one
entry, incrementally and cumulatively (`quota.rs:705`). Two relayed sessions therefore spend one
allowance at twice the rate, which is what the design wants and what the user should be told.

Three consequences the app has to get right, and one for the operator:

1. **The app's estimate must count every live relayed session** (`relaySecondsUsedThisPeriod`).
2. **The cut is simultaneous.** Both splices read `remaining()` live off the same counter and both
   see zero within one charge period (`CHARGE_PERIOD`, `quota.rs:332`), so both sessions report
   `quotaExceeded`. `spentAllowance` and the sheet must be shown **once**: the second refusal must
   find the sheet already up and add nothing. Today's `relaySessionDropped` flag
   (`SessionModel.swift:630`, cleared on the next `.ready`) becomes per-session or a count, and the
   cut path ends **every** session rather than the one that noticed.
3. **Every Mac must be ended, not just the one on screen**, or the user is left with two dead tabs
   and a sheet over one of them.
4. For the operator: N concurrent relayed sessions from one client spend the allowance N times as
   fast, and the pre-check at `Relay/src/signalling.rs:610` is not atomic with the charge, so N
   concurrent splices can each overshoot by up to one charge period. That is N times 15 seconds of
   unbilled relay rather than 15. Small, and it scales with the session ceiling somebody should pick
   (section 7).

### The terminal collections: plural per Mac, and one number to decide

`terminals` is already an array keyed by a UUID the Mac generates
(`MacCastHost/Terminal/TerminalSessionManager.swift:267`), and the host's manager is keyed by client
ID and is per Mac, so **nothing on the host changes**. What changes:

- `terminals`, `selectedTerminalID` and every folder and preview keyed by a terminal move onto
  `MacSession`, so the deck shows the active Mac's shells only.
- `SessionModel.canOpenAnotherShell` (`SessionModel+Terminal.swift:28`) counts running shells in the
  active session. **Decision:** the free plan's one shell means one shell *per Mac*, not one shell in
  the app. The recommendation is per Mac, because a free user cannot open a second Mac at all, so
  the two readings only differ for a paid user who is being counted twice for one thing.
- A ceiling worth naming: the host caps terminals per client at 10
  (`TerminalSessionManager.swift:70`), so four Macs is up to forty PTYs and forty output buffers,
  each capped at 512 KB on the phone. Bounded, but it is a real number and it belongs in the same
  conversation as the session ceiling.

### Memory and battery with three control channels open

The design's whole claim is that the expensive parts do not multiply. What does multiply, and by
how much:

Per Mac, while it is open and not active:

- **Control TLS connection:** one socket, two buffers, and no traffic beyond the ping.
- **Control ping, once a second** (`ClientSession.swift:1122`): one small frame each way per second.
- **Video transport watchdog** (`startVideoWatch`): a task, two or three checks a second.
- **`CommandCoalescer`** (`ClientSession.swift:380`): **a 60 Hz timer, today**, started at connect and
  stopped only in `deinit` (`:562`). This is the one that matters and Stage 6 fixes it.
- **Terminal output buffers:** up to 512 KB per shell, on the phone.
- **Video, audio, decoder, layer: nothing.** Paused, singular, or both.

Singular for the whole app: the renderer and its decoder, the display layer, the audio engine, the
video poll, `SessionAudio`, `SessionPiP`, the browser, the pins. So the memory story is "one session
plus a few hundred kilobytes per extra Mac", and the battery story is "one ping per second per extra
Mac, plus the timer Stage 6 removes".

**Decision:** the ceiling on how many Macs may be open at once. The recommendation is four. Three is
the design point, four leaves room for one more before the strip becomes a scroll, and a ceiling the
container enforces with a sentence is better than one the user discovers by having a tab die.

### Rotation, and what the tab strip does on the remote screen

Rotation is app-wide: `OrientationLock` (`MacCast/MacCastApp.swift:7`) is set from
`ContentView.swift:209-232`, and it already goes to
all-but-upside-down on the remote screen. Nothing about it is per Mac.

The strip itself:

- **Drawn only when there is more than one session.** One Mac is nearly everybody, and their screen
  does not change at all.
- **Portrait:** a row above the dock, which is where the picture's bottom edge already has chrome.
- **Landscape:** under the status pill, in the row that already has a width budget
  (`RemoteScreen+Chrome.swift:61`). The rails are at the two edges and the middle is the picture, so
  the strip scrolls horizontally rather than growing.
- **It is the terminal's tab strip.** `TerminalPanel.tabStrip` (`MacCast/TerminalPanel.swift:284`)
  is the same object: a horizontal scroller of names, the selection scrolled to centre, a mark on
  the tab that wants attention. It should be lifted into a shared component rather than written a
  second time, or the two will drift.
- **The `+` on its trailing end is the gated control** (section 6).
- **`reportChromeFrame(_:into:)` is not optional.** The chrome frames are what stop a touch aimed at
  a button from reaching the Mac underneath (`RemoteScreen.swift:90`, `blockedRegions` in
  `RemoteScreen+Gestures.swift:103`). A strip that does not report its frame is a tab switch that
  also clicks something on the Mac. This is the most likely single bug in the whole feature.
- **Decision:** whether the strip hides. The recommendation is that it collapses with the status
  pill in landscape, because that is the gesture the pill already teaches, and that it stands
  permanently in portrait, because the dock below it does.

## 6. The gate

**The capability.** A new case on `PlanCapability` (`MacCastKit/Sources/MacCastKit/PlanAccess.swift:30`):

```swift
/// A second Mac held open at the same time as the first.
case concurrentSessions
```

with `minimumPlan: .pro` and a name in the same voice as the others, e.g. "Several Macs at once".
It is a concurrency gate rather than a capability gate, which is the same axis as `shellTabs` and
the same argument that moved SSH servers out of the map entirely (`PlanAccess.swift:21-29`).

**Decision, and it is a pricing decision rather than a technical one.** `extraMacs` is `.relay` and
its copy says "every Mac you own instead of one", so a Relay subscriber who owns three Macs is told
they may pair all three and will then find they can hold one at a time. The working assumption is
Pro, and the plan says so, but the owner should know that the phrase on the Relay card and the gate
are in tension, and that moving this case to `.relay` is one line if the copy wins.

**Where the check goes: in exactly one function.** `SessionModel.addSession(hostID:)` refuses when
the plan does not include the capability and a session is already open. One function because that is
where a session is born, and because the two other routes that could start one (the picker's row and
the widget's URL) all pass through it.

**What a free user sees**, following the rule the app already has (stated at
`MacCast/SharedControls.swift:174-195`): the control is drawn as itself, dimmed, with the plan badge
beside it, and tapping it opens the plans. Never a padlock, never a badge in the control's place.

The control in question is **the `+` at the end of the tab strip**, which is the one that exists in
the state where a second Mac is a thing you could ask for. It is exactly the terminal's `+`
(`MacCast/TerminalPanel.swift:182`), down to the `isIncluded` argument:

```swift
PlanLocked(
    capability: .concurrentSessions,
    title: "Another Mac",
    diameter: 26,
    isIncluded: model.canAddAnotherSession
) { … }
```

`isIncluded` is passed rather than left to the map for the reason that parameter exists
(`SharedControls.swift:220-226`): the **first** session is free on every plan, so the question is
never "is this paid" on its own. `canAddAnotherSession` is `storeManager.access.includes(.concurrentSessions) || sessions.isEmpty`.

The picker's rows need the same treatment for the case where the user is back at the list with a Mac
already open: the row is drawn as itself with its reachability dot, dimmed, with the badge at its
trailing edge, and tapping it opens the plans instead of dialling. `BadgePlacement.trailing` is that
shape and `FileBrowserPanel`'s Download row is the worked example.

**Four copies of the map move together.** The enum, `MacCastKit/Tests/MacCastKitTests/PlanAccessTests.swift:32-40`
(the `expected: [PlanCapability: RelayPlan]` table, which fails until it is edited), the feature
tables in `PLANS-AND-FEATURES.md`, and the plan cards in `Relay/site/index.html`. `PlanAccess.swift:9-11`
says the same thing and it is not a suggestion.

## 7. Risks, worst first

**1. The picture does not come back after a switch.** The failure is a black screen, or a permanent
"waiting for a keyframe", on the Mac you just switched to. This is the same family as the bug in
`HANDOFF-video-smoothness.md` §5.2, where a re-attach produced 1 fps on the device and looked
nothing like the model. Re-attaching is exactly what this design does on every switch, so this is
the risk the feature lives or dies on. The mitigation is that the two diagnostics
`HANDOFF-video-smoothness.md` §8 names as missing, `VideoRenderer`'s `awaitingKeyframe` and the
host's encoder drop count, are built **before** Stage 3 rather than after. Switching is not a new mechanism, it is the existing reconnect
path called often, and it must be instrumented like one.

**2. The wire change locks out Macs that have not updated.** The failure is a user who updates the
phone and cannot reach their Mac at all, with a message about versions, on a Mac that updates on its
own schedule or not at all. Mitigated by the `ServerHello` capability flag (Option B) and by shipping
the host half first. If the version bump is chosen instead, it needs a release note and a support
answer.

**3. The allowance meter overstates what is left.** The failure is a bar showing most of an hour
with the relay cutting both sessions in the same minute, which is the failure the user will
interpret as the app having lied to them. Caused by `relaySecondsUsedThisPeriod` counting one live
session, which is a one-line bug with a two-session precondition and so will not show up in any
testing that uses one Mac.

**4. A background Mac's session dies and nothing says so.** The failure is a tab that is dead when
you switch to it, having been dead for a minute, with no banner. Caused by leaving the ladder's
state on the container so the background Mac never re-armed, or by notifying only the active
session. This is the failure mode that makes the feature worse than reconnecting, because a reconnect
at least tells you it is happening.

**5. The Live Activity or PiP describes the wrong Mac.** The failure is a Lock Screen card naming
the Mac you are not using, or a floating window showing a picture the tab strip says is not active.
Both are one-line consequences of a surface being fed by the wrong session, and both are the kind of
wrong that erodes trust in the whole feature.

**6. Three control channels keep the radio and the CPU awake in a pocket.** The failure is a battery
complaint that arrives weeks later and is hard to attribute. The 60 Hz `CommandCoalescer` timer per
session is the concrete cause and Stage 6 is the fix; the per-second ping is the irreducible price
and should be measured before a session ceiling is chosen.

**7. The same Mac is dialled again from the picker and opens a second tab.** The failure is a tab
that is superseded by the relay (`Relay/src/session.rs:504` supersedes by pair) and dies in seconds,
or the same Mac shown twice. The container must key sessions by host ID and treat a second dial as
`activate` rather than `addSession`, and the picker's row for a Mac that is already open must switch
to it rather than connect again.

**8. The tab strip swallows a tap meant for the Mac, or lets one through.** The failure is a switch
that also clicks the Mac's desktop, because the strip is new chrome that did not report its frame
and `blockedRegions` does not know about it. Named here because it is the most likely single bug and
the least likely to be caught before shipping: it only reproduces when a tap lands on the strip.

## 8. What to test, and how

**Everything except the picture is testable without a Mac.** `MacCastKit` and `RemoteCore` both run
under `swift test`, and the split puts more of this logic where those tests can reach it:

- Two `MacSession` objects, two records, two durations, and `relaySecondsUsedThisPeriod` summing
  both. This is the allowance bug from risk 3 and it is a pure arithmetic test.
- Two ladders, one Mac unreachable, the other unaffected: the container's state is the assertion.
- The gate: one session on free, a second refused, `PlanAccessTests` extended with the new case.
- The notification identifier carries the host, so two Macs produce two banners.

**The switch itself cannot be tested here.** It needs a Mac with a screen, and the number worth
having is how long after `setVideoEnabled(true)` the first decoded frame arrives. Measure it in
Stage 3 with one Mac, before Stage 4 makes it a feature. If it is not comfortably under half a
second, the design's premise is wrong and the honest answer is to keep the inactive Macs capturing
at a low rate rather than not at all, which is a different bill and should be decided then rather
than assumed now.

**The host half is testable on loopback.** `VideoCoordinator`'s pause path is a decision about an
audience, and the audience transitions already have tests. The one to add: pause one peer, assert
capture stays up for the second peer, assert it stops when both have paused, assert the first peer's
resume asks for a keyframe.

**The field test that matters is the boring one.** Three Macs open, one on the LAN and two on the
relay, the phone in a pocket for half an hour, then switch between all three and check that each one
shows its own picture, its own shells, its own clipboard, and that the Macs' screens are all still
awake and unlocked. That is the whole promise of the feature in one walk.

---

## Decisions taken, 20 September

The calls this document flagged as open, resolved by the owner. These override anything above that
reads as undecided.

- **Protocol versioning: a capability flag in `ServerHello`, not a version bump.** An un-updated Mac
  degrades honestly rather than being locked out, which is the same argument the relay side already
  won for trusting a claimed plan while the receipts rolled out.
- **The rung: Pro.** The `extraMacs` tension is noted and accepted: a Relay subscriber pairs every
  Mac they own and holds one session at a time, which is what that card says.
- **Live Activity: yes**, a background Mac dropping is worth a banner.
- **Picture in Picture: follows the active tab.** Switching tabs changes the floating picture. The
  alternative needs a second decoder, which the one-stream rule exists to avoid.
- **Audio: a background Mac goes silent.** The price of one audio player, and audible background
  audio is a separate feature rather than a defect.
- **Siri: "Disconnect" ends everything.** No parameterised per-Mac form for now.
- **Terminals: free's one shell is per Mac, not per app.** Two Macs means two free shells.
- **Tab strip: collapses with the pill in landscape, permanent in portrait.**
- **The ceiling: four sessions**, enforced by the container with a sentence rather than silently.

Two findings from the survey are now tasks in their own right rather than notes: the missing
`setVideoEnabled` command (the host half ships first), and `relaySecondsUsedThisPeriod` counting one
live session where the relay charges every splice to one counter per client.
