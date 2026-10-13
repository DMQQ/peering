# Android code review

Reviewed 2026-10-12 at the tip of `monorepo` (whole `android/` folder, not a diff). Two axes, kept separate:
standards and correctness, then spec conformance. Nothing was built or run for this review. The standards pass was a
sampled read (greps across `core` and `app/src/main`, plus targeted reads), not a read of every file. Findings are
ranked most severe first inside each axis. HARD means a documented standard or a real defect, JUDGEMENT means a smell.

## Standards and correctness

Clean results: no `!!` outside `PreviewRequestHandler`, no `GlobalScope`, no em dashes, no Android imports in
`core:wire` or `core:session`, no `infiniteRepeatable`, `usesCleartextTraffic` is false, only the launcher activity and
the two widget receivers are exported, the FileProvider is not exported.

1. **Medium, HARD (security).** `MainActivity.kt:63-68`, `AndroidManifest.xml:28-33`. The exported `peering://connect`
   and `peering://chat` filter lets another app dial a paired computer, and `onNewIntent` acts on it while the app lock is
   showing. Failure: an app fires `peering://connect?id=<paired host id>` and a session starts behind the lock. Fix: queue
   the link while locked and replay it after unlock; use explicit `PendingIntent`s for the widgets and drop the exported
   filter if nothing external needs it.
2. **Medium, HARD (crash, hostile input).** `WidgetLink.parse` calls `URLDecoder.decode`, which throws
   `IllegalArgumentException` on a malformed escape, with no catch. Failure: `peering://connect?id=%zz` crashes
   `MainActivity.onCreate` with no authentication needed. Fix: wrap the decode in `runCatching` and return null.
3. **Medium, HARD (blocking).** `PreviewRequestHandler.kt:34,59`, `PreviewBodyStream.kt:42`. `runBlocking` on
   `events.receiveCatching()` has no timeout, and up to `MAX_REDIRECTS + 1` hops can each block. Failure: the computer
   accepts a fetch and never answers, WebView loader threads block until the user leaves, the page freezes, the thread
   pool can be exhausted. Fix: `withTimeoutOrNull` for the first byte and for each chunk, answer
   `PreviewFailure.DISCONNECTED` on timeout.
4. **Medium, HARD (force unwrap).** `PreviewRequestHandler.kt:34,38`. `address!!` inside a loop over a `var`, with no line
   saying why it is safe. Fix: `var current: PreviewAddress = address` and use it.
5. **Medium, HARD (file size).** `core/session/.../controller/SessionController.kt` is 431 lines against about 300, and
   likely holds functions over 40 lines. Fix: split by responsibility into whole declarations.
6. **Medium, HARD (trust model).** `PinningTrustManager.kt:14-30`, `TlsFactory.kt`. A null pin accepts every peer.
   Failure: a stale null from a lookup miss degrades a paired connection to accept-anything, and on first pairing an
   on-path attacker is pinned unless the digits are compared. Fix: require an explicit pairing flag for `pin == null`, and
   fail when a known host id has no pin.
7. **Low, HARD (logging).** `ControlSockets.kt:35,39`, `SessionHolder.kt:44,53`, `SessionPortsFactory.kt:47`,
   `NsdDiscovery.kt:40-48`, `RemoteBridge.kt:42`. `Log` calls in release code expose peer addresses and failure causes in
   `adb logcat`. Fix: one debug-only logger, no addresses.
8. **Low, HARD (test code in main).** `app/src/main/.../testing/RemoteBridge.kt` and `ui/debug/DebugPreview.kt` ship in
   release; `DebugPreview` logs user-typed text. Fix: move to `app/src/debug` and stub in release.
9. **Low, HARD (restore crash).** `SessionScreenState.kt:72-78`. `saved[n] as String?/Boolean/Double` and
   `SessionPanel::valueOf`. Failure: a renamed panel or changed saver shape throws on launch when an old bundle restores.
   Fix: `as?` with defaults and a safe enum lookup.
10. **Low, HARD (unchecked casts).** `ClipboardPanel.kt:140,169`, `SessionCard.kt:45`. Casts that rely on a prior `when` or
    `filter`; a new sealed subtype throws in composition. Fix: smart-cast with `is`, or `filterIsInstance`.
11. **Low, HARD (WebView).** `PreviewWeb.kt:27-33`. Non-loopback https subresources load over the phone's own network, so
    a previewed page can reach the internet. Fix: also intercept and refuse non-loopback requests.
12. **Low, JUDGEMENT (Duplicated Code).** `TlsFactory.kt:17-24` and `61-68`: the trust manager and `SSLContext` setup and
    the close-and-rethrow blocks repeat. Fix: extract one `sslContext(pin)` helper.
13. **Low, JUDGEMENT (Divergent Change).** `ui/Features.kt` mixes widget opening, connect policy and screen installation.
    Fix: split `install()` from the connect policy.
14. **Low, JUDGEMENT (Primitive Obsession).** `hostId: String` travels raw through `WidgetLink` and the pin lookups. Fix: a
    `HostId` value class if it keeps spreading.
15. **Low, JUDGEMENT (naming).** `PreviewRequestHandler.refuse` builds a failure page and notifies the presenter. Fix:
    `failureReply`.

Not checked: functions over 40 lines outside the files read, `ShapeLiteralScanTest` coverage, localisation of every
string, test coverage of new logic, coroutine lifetime in `SessionHolder` and `PeeringApplication`.

## Spec conformance

Specs: `docs/plans/android-and-windows.md` and `-tasks.md`, `docs/protocol.md`, and the iPhone app as the behaviour
blueprint.

1. **High.** The network watcher is never subscribed. `NetworkWatcher` is built in `AppGraph.kt:42` and passed in
   `SessionFactory.kt:25`, but nothing collects it and `SessionController.networkChanged()` (`SessionController.kt:169`)
   has no caller. Tasks AND-058 and AND-081 are marked done. Failure: moving from Wi-Fi to cellular leaves a dead socket
   until the 60 s silence limit, and a relay session never moves to the LAN as the iPhone's does (see
   `MacSession+Resume.swift` and `NetworkChangePolicy.swift`). Fix: collect the changes in the session holder and call
   `networkChanged()`, add a dial-again path for a live relay session when the host appears on the LAN.
2. **High.** An unknown enum case from the host ends the session. `SwiftEnumException` (`SwiftEnumJson.kt:18`) is thrown
   by `AgentWireCodec.kt:34`, `SwiftEnumJson.kt:26-28` and `CaptureSource.kt:59`, but `HandshakeFrames.parsed` catches only
   `IllegalArgumentException`, and `FrameRouter` decodes agent, terminal and preview events through it. Tasks AND-030 and
   AND-087 require that an unknown case does not kill the session. Failure: one new `AgentEvent` case from a newer Mac
   drops the link, the host replays history, and it loops. The test that claims coverage (`ErrorPathsTest.kt:182-192`) never
   runs `FrameRouter`. Fix: make the exception a `SerializationException` or catch it in `parsed`, decode stream events one
   by one and skip unknown ones, add a `FrameRouter` test.
3. **Medium.** Deep links connect while locked (same defect as standards item 1). The iPhone has one gate for every way in
   (`AppSecurity.swift`). Fix: queue until unlocked.
4. **Medium.** The client declares `supportsTextFocus`, `supportsFieldState` and pointer report (`HandshakeFrames.kt:24-26`)
   but `FrameRouter` drops frames `0x1C` and `0x1D`. The plan says only agent chat is declared at first. Failure: the Mac
   sends frames that are discarded, and the keyboard never rises when a Mac text field takes focus. Fix: consume them or
   stop declaring the flags.
5. **Medium.** Reconnect is shorter than the iPhone's. `ReconnectLadder` (`Backoff.kt:25`) totals about 13.5 s and
   `SessionController.kt:210` then fails. The iPhone uses 0.25, 1, 3, 5, 8, 10 s inside a 30 s window
   (`SessionModel.swift:365-377`), long enough to outlast a Mac app restart. Fix: port the ladder and the window.
6. **Medium.** Push is missing. AND-113 is `todo`: no push token is registered, no FCM service, no
   `POST_NOTIFICATIONS`. Failure: agent approvals and terminal alerts never reach a backgrounded phone. Fix: build AND-113
   or document the absence.
7. **Low.** Features built that the plan marks SKIP or LATER: mosaic, joystick, widgets (SKIP); terminal emulator, web
   preview, invites, clipboard history (LATER). Mosaic is capability guarded, the joystick is not. Fix: gate the joystick
   on the host platform or record the scope change.
8. **Low.** `hostPlatform` is never read, and Mac-only commands go out unguarded (`LockScreen`, `SetPrivacyMode`,
   `SwitchSpace`, `LaunchApplication`, `PerformWindowAction`, `OpenNewWindow`, `JoystickMove`). Failure: a Windows host
   silently ignores them. `docs/protocol.md` section 8 names a `supportsLockScreen` field that exists in neither Swift nor
   Kotlin, a spec bug. Fix: hide Mac-only controls when the host is not a Mac, correct the doc.
9. **Low.** Dead pairing shortcut: `SessionController.kt:301` accepts without comparing the displayed code whenever a QR
   secret is set. Unreachable today (`Features.kt:159` passes none). The iPhone compares and rejects on mismatch
   (`PairingCodeEntry.swift:96-107`). Fix: delete it or compare first.
10. **Low.** `resumeSource` is sent in the hello for an unpinned host (`HandshakeFrames.kt:28`); the iPhone sends it only
    when the host is known (`ClientSession.swift:323`). Harmless today. Fix: align.
11. **Low.** App lock gaps: no notice if the screen lock is later removed, no `FLAG_SECURE` or recents thumbnail hiding.
    Failure: the remote screen shows in the recents list. Fix: set `FLAG_SECURE` while locked or in a session.
12. **Low.** No receive-side 64 KiB control payload check (`docs/protocol.md` section 1). Fix: add the cap.
13. **Low.** Verification gap: `docs/protocol/vectors/messages.json` has 24 cases and none for agent, terminal, file,
    preview or relay messages. A read by eye found them consistent with Swift. Fix: add Swift-generated vectors.

Checked, no defect found: framing and the 16 MiB cap, hello and server hello fields, the SAS transcript and proofs, TLS 1.3
only, relay token ordering, quota handling, relay JSON keys.
