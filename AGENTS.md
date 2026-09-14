# MacCast — agent working notes

Everything a fresh agent needs that is **not** derivable from reading the source. Written
2026-09-14 by the agent that built the bulk of the system. If you are picking this up cold,
read this top to bottom before touching anything — several of the traps below cost hours.

---

## 1. What this is

A cross-platform remote desktop system:

- **`MacCastHost`** — a macOS app that captures the screen, encodes it, and injects synthetic
  input. Non-sandboxed on purpose (a sandboxed app cannot post `CGEvent`s into other apps,
  which is the entire function of the app — so the Mac App Store is not a target).
- **`MacCast`** — an iOS app that renders the stream and sends gestures/keystrokes back.
- **`RemoteCore`** — a local Swift package with everything shared: framing, protocol,
  crypto, coordinate mapping.

Communication is over local Wi-Fi. The design goal that drives most decisions: **the Mac is
recognised across networks with no user interaction after the first pairing.**

### Targets

`xcodebuild -list -project MacCast.xcodeproj`:

```
Targets: MacCast (iOS), MacCastTests, MacCastUITests, MacCastHost (macOS)
Schemes: MacCast, MacCastHost, RemoteCore
Packages: swift-certificates 1.20.0, swift-crypto 4.5.2, swift-asn1 1.7.2, RemoteCore (local)
```

The project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77), so **new `.swift`
files under a synced folder need zero pbxproj edits.** Do not hand-write file entries into
build phases.

---

## 2. Commands that actually work

```bash
# Build the iOS client for the physical device
xcodebuild -project MacCast.xcodeproj -scheme MacCast \
  -destination 'id=8A51FAD5-A897-57CD-9C09-395D9F2C258A' build

# Build/run the host
xcodebuild -project MacCast.xcodeproj -scheme MacCastHost -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/MacCast-*/Build/Products/Debug/MacCastHost.app

# RemoteCore unit tests (100 tests, 14 suites, all green as of 2026-09-14)
cd RemoteCore && swift test

# Install + launch on the connected iPhone
xcrun devicectl device install app --device 8A51FAD5-A897-57CD-9C09-395D9F2C258A \
  ~/Library/Developer/Xcode/DerivedData/MacCast-*/Build/Products/Debug-iphoneos/MacCast.app
xcrun devicectl device process launch --device 8A51FAD5-A897-57CD-9C09-395D9F2C258A \
  pl.dmq.maccast.MacCast

# Read the host log  (NOTE: /usr/bin/log explicitly — see trap #1)
/usr/bin/log show --last 5m --style compact \
  --predicate 'subsystem == "pl.dmq.maccast.host"'
```

**Always build with `-scheme`, never `-target`.** With `-target` the build settings that make
the targets work (notably `INFOPLIST_KEY_*`) are not applied.

Log subsystem is `pl.dmq.maccast.host`, categories `session`, `video`, `capture`, `encoder`.

---

## 3. Verification tooling

This project has a script client that can prove almost everything without the iOS UI. **Use
it.** Phases 1–5 of the plan were all verified with it before any iOS UI existed.

### `Tools/run-probe.sh`

Builds, **signs**, and runs `Tools/MacCastProbe`. The signing step is load-bearing, not
housekeeping — read the comment at the top of the script before you change it.

```bash
Tools/run-probe.sh --drive --accept --id probe-client-2
Tools/run-probe.sh --hold-drop 55 --accept --id probe-client-2
Tools/run-probe.sh --video-recv --video-recv-seconds 5 --accept --id probe-client-2
Tools/run-probe.sh --browse                    # Bonjour discovery only
Tools/run-probe.sh --reset --id probe-client-3 --accept   # force a fresh identity + pairing
```

Full flag list: `Tools/run-probe.sh --help`. Highlights: `--drive` (moves the real cursor and
verifies it lands), `--type` / `--key` / `--combo` / `--space` (injection), `--flags LABEL`
(prints held modifiers — use it to prove nothing is stuck), `--video` / `--video-only` /
`--video-recv`, `--switch-to src@seconds`, `--catalog`, `--find`.

### `Tools/activity.sh [seconds]`

Drives the cursor in a Lissajous path (incommensurate axes, so the picture never settles into
a loop the encoder compresses away) and restores it on exit. **Any test of frame ordering,
frame rate, or queue depth needs the screen moving** — see trap #7. Run it in the background
across the measurement:

```bash
Tools/activity.sh 20 & sleep 2; Tools/run-probe.sh --video-recv --accept --id probe-client-2
```

### The regression sweep

The full sweep that was green at the end of the build:

```bash
ID="--accept --id probe-client-2"     # NOTE: see trap #3 about shell quoting
Tools/run-probe.sh $ID --drive
Tools/run-probe.sh $ID --hold-drop 55
Tools/run-probe.sh $ID --hold-button-drop 0
Tools/run-probe.sh $ID --type "hello" --combo cmd:0 --space right --flags AFTER
Tools/run-probe.sh $ID --catalog
Tools/run-probe.sh $ID --video-recv --video-recv-seconds 5
Tools/run-probe.sh $ID --video-only          # expects refusal
Tools/run-probe.sh $ID --switch-to window:NNNN@1 --switch-to application:NNNN@2 ...
```

---

## 4. Architecture

### Wire protocol (`RemoteCore`)

**Framing — built first, because every command depends on it:**

```
┌──────────────┬─────────┬─────────────────────┐
│ u32 length   │ u8 kind │ payload (length-1)  │
│ big-endian   │         │                     │
└──────────────┴─────────┴─────────────────────┘
```

`FrameDecoder` accumulates bytes and emits whole frames. Hard 16 MiB length cap enforced
**before allocating** — otherwise a corrupt length field is an instant memory-exhaustion DoS.

**Two TCP connections, not one** — control and video. Sharing one stream causes head-of-line
blocking: a 200 KB keyframe sits in front of the next mouse move. Control latency is what a
user feels. One `NWListener` on **port 51515** accepts both; the first frame declares the role.

**Handshake:** `clientHello` → `serverHello` → TLS → SAS pairing (unpaired) or pin check
(paired). Then sealed.

### Security design (all of this is deliberate; don't "simplify" it)

- **TLS 1.3 with a runtime-generated self-signed identity**, minted on the host and pinned by
  the client. Self-signed is not weaker than CA-signed *provided the client pins* — if
  anything stronger, since there is no CA to coerce.
- **TLS-PSK was considered and rejected**, and the reason is worth keeping: the only workable
  PSK suite is TLS 1.2-only and is plain PSK with **no (EC)DHE**, so no forward secrecy. A
  passive eavesdropper recording one handshake could brute-force a 6-digit PIN offline (10⁶
  HMACs is instant). That disqualifies it for a PIN-based scheme.
- **Pairing is SAS / numeric comparison** (the Bluetooth LE model), *not* a typed PIN. A typed
  6-digit PIN used as a client→host proof is offline-brute-forceable by an active attacker
  during first pairing: the attacker substitutes their own identity, receives the PIN-derived
  MAC over *their* transcript, and grinds all 10⁶ candidates offline. With SAS the two screens
  show 6 digits derived from the handshake transcript and the user confirms they match — an
  active MITM now succeeds with probability 10⁻⁶ per attempt and cannot grind offline.
- After pairing the host's long-term identity key is pinned in the **iOS Keychain** with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; later connections need no interaction.
- Post-pairing client→host auth is **mTLS** (`sec_protocol_options_set_challenge_block`), not
  an app-layer bearer token.
- Client pins the server's **SPKI**, not leaf bytes, so the cert can rotate without re-pairing.
- Transcript hashing must be in a **fixed agreed order** and cover every exchanged field, or
  the comparison is meaningless. Comparisons are **constant-time** (Swift's `Data ==`
  short-circuits). Both are pinned by unit tests.

**The SAS pairing is automatable from the client side** — `handlePairConfirm` on the client
acts on the *client's* `pairConfirm` frame; the host merely displays its code. That is why the
probe's `--accept` works, and it is not a hole (the client is the one being asked to confirm).

### Capture sources

```swift
public enum CaptureSource: Codable, Sendable, Hashable {
    case display(UInt32)       // CGDirectDisplayID raw value
    case application(Int32)    // pid_t — all that app's windows, composited
    case window(UInt32)        // CGWindowID raw value
}
```

Platform-neutral raw values **on purpose** — `CGDirectDisplayID`/`CGWindowID` live in
macOS-only headers; using them directly breaks the iOS build. Same reason `RemoteCore` speaks
`UInt16` keycodes and `UInt` modifiers rather than `CGKeyCode`/`NSEvent.ModifierFlags`.

One `CaptureSourceResolver` owns the translation to `SCContentFilter`, so the rest of the
pipeline never switches on source kind. The catalogue is **live** — re-enumerated on
`NSWorkspace` launch/terminate and `didChangeScreenParametersNotification`.

### Streaming pipeline

- **Capture (host):** `SCShareableContent` → `SCDisplay` by `CGDirectDisplayID` →
  `SCContentFilter(display:excludingWindows:)`. `queueDepth` **2–3** (default 8 is the primary
  latency knob). `captureResolution = .nominal`. `pixelFormat = '420v'` (the encoder's native
  input, skips a colour conversion). Do **not** use `scalesToFit`.
- **Encode:** `VTCompressionSessionEncodeFrameWithOutputHandler` — the only variant whose
  callback is `CM_SWIFT_SENDABLE`, which is the crux of making it work under Swift 6 strict
  concurrency. `AllowFrameReordering` **defaults to `true` and must be set `false`** (B-frames
  add latency). Plus `EnableLowLatencyRateControl`, `RealTime`, `ExpectedFrameRate`,
  `PrioritizeEncodingSpeedOverQuality`. H.264 to start; codec is behind an enum.
- **Parameter sets** live in the format description attached to the output sample buffer, not
  in the sample data. Keep **AVCC** (4-byte length-prefixed NALUs) — that is what VideoToolbox
  emits and what the client needs.
- **Decode/render (client):** `AVSampleBufferDisplayLayer.sampleBufferRenderer`. No separate
  `VTDecompressionSession` — the renderer decodes in hardware internally. Build `CMSampleBuffer`s
  with `CMSampleBufferCreateReady` (`decodeTimeStamp = .invalid`, valid because reordering is
  off). Use `renderer.enqueue/flush/isReadyForMoreMediaData` (the *renderer's*, not the layer's).
- **Force a keyframe the moment a client connects** — never by tearing down the session.

Reference for the directory layout: `RemoteCore/Sources/RemoteCore/` holds `Framing`,
`Handshake`, `PairingSAS`, `TLSConfig`, `SelfSignedIdentity`, `PeerPinning`, `DeviceIdentity`,
`ClientSession`, `ClientTransport`, `RemoteCommand`, `InputTransform`, `InputEncoding`,
`CaptureSource`, `VideoWire`, `ServiceDiscovery`, `ConstantTime`, `ProtocolInfo`.

---

## 5. Traps — read this section twice

These are the ones that cost real time. Each was hit at least once.

### Environment / tooling traps

1. **zsh's `log` builtin shadows `/usr/bin/log`.** Writing `log show ...` silently invokes the
   zsh builtin and produces nothing useful, which looks exactly like "the app isn't logging".
   **Always write `/usr/bin/log`.**

2. **`security find-generic-password -w` triggers a modal keychain prompt and hangs forever.**
   Do not use it in an unattended script. It was hit once and had to be backgrounded and killed.

3. **zsh does NOT word-split unquoted parameter expansions.** `ID="--id probe-client-2";
   Tools/run-probe.sh $ID` passes `--id probe-client-2` as **one argument**. Either inline the
   arguments or use an array (`ID=(--id probe-client-2); cmd "${ID[@]}"`).

4. **A bare `swift build` breaks the probe.** SwiftPM's default ad-hoc signature is derived
   from the build hash, so rebuilding without signing changes the probe's code identity →
   keychain ACL mismatch → `errSecAuthFailed`. Always go through `Tools/run-probe.sh`.
   *(This trap was hit a second time by the agent that wrote this file, which had recorded it
   in memory and still violated it. Go through the script.)*

5. **`/Users/dmq/Desktop/projects/MacCast` and `/Users/dmq/Desktop/projects/maccast` are the
   same directory** (inode 256522752) — case-insensitive filesystem, not a duplicate. Both are
   registered as working directories; don't be confused by tooling that reports both.

6. **There is a stray `./build/` at the repo root** holding a second DerivedData
   (`Index.noindex`, `SourcePackages`) from an earlier `-derivedDataPath ./build` run. It is
   gitignored. Harmless, but it can make "which build is current" confusing.

7. **Building steals focus, so injected keys miss.** A build that brings Xcode to the front
   means synthetic keystrokes land in Xcode, not the intended target. Sequence probe runs so
   nothing rebuilds mid-injection.

### Swift / Xcode traps

8. **SourceKit diagnostics are not compiler errors.** After a Clean, `.swiftmodule`s are
   deleted, `RemoteCore` becomes unresolvable, and *every* file importing it cascades into
   unrelated-looking errors (`Cannot find type 'ClientSession' in scope`, `Cannot call value of
   non-function type 'Binding<Subject>'`, …). This looks catastrophic and is not. Decisive
   check: look at Xcode's own `*.xcactivitylog` in
   `~/Library/Developer/Xcode/DerivedData/MacCast-*/Logs/Build/` — a "Build succeeded" next to
   a "Clean succeeded" means you are chasing ghosts. Rebuild to repopulate.

9. **Swift 6: a C callback's closure infers `MainActor` isolation and SIGTRAPs.** Needs explicit
   `@Sendable`. (See also trap #11 for the ScreenCaptureKit variant.)

10. **`CGDisplayPixelsWide` returns POINTS, not pixels.** It reports 1512×982 on a Retina
    panel, not 3024×1964. A wrong pair here *cancels out* in coordinate maths, so it hides.

11. **SCK frame info is sample-level.** `CMGetAttachment` returns nil for it. Reading it wrong
    looks *exactly* like denied Screen Recording permission — a silent black stream. This is
    the single worst failure mode in the app.

12. **`CGEvent` flags bit 29 is always set.** Raw `flagsState` is never zero, so compare through
    a modifier mask, never against zero.

13. **`CGEvent(mouseEventSource:)` does not exist** — the label is `source:`. The original spec
    sample had three calls that do not compile.

14. **`SCDisplay.width`/`height` are in points, not pixels.** Use `CGDisplayPixelsWide(_:)` or
    `SCContentFilter.pointPixelScale`.

15. **`sourceRect` is in points while `destinationRect` is in pixels** — an easy off-by-scale bug.

16. **`SCContentFilter.backgroundColor` defaults to clear, not black.** App and window capture
    must set it explicitly or the client shows a transparent-onto-garbage surface.

17. **`CGPreflightScreenCaptureAccess()` only checks — it never prompts.** Using it as a gate
    creates a deadlock where the app never asks and therefore never receives permission. Call
    `CGRequestScreenCaptureAccess()` to prompt.

18. **`NSScreenCaptureUsageDescription` does not exist** and is inert. Adding it is cargo cult.
    The prompt uses a system string that cannot be customised.

19. **`INFOPLIST_KEY_NSBonjourServices` is silently inert.** It must go in the real Info.plist
    (`Config/MacCast-Info.plist`), even though `INFOPLIST_KEY_NSLocalNetworkUsageDescription`
    and friends work fine as build settings. Missing Bonjour services makes browse fail
    *quietly* — no prompt, no error.

20. **Sign stably.** Ad-hoc or per-build signing changes app identity, so TCC treats every build
    as a new app and re-prompts — the usual cause of "it asks for permission on every run".
    After granting Screen Recording, a **full quit-and-relaunch** is usually needed because
    consent is evaluated at process start.

21. **There is no multi-display `SCContentFilter`.** Every initializer takes a single `SCDisplay`.
    The plural `includedDisplays`/`includedApplications`/`includedWindows` are read-only
    introspection (macOS 15.2+), not construction inputs. One stream at a time is the natural
    model, not a compromise.

22. **Dropped frames are not reported by ScreenCaptureKit.** There is no "dropped" `SCFrameStatus`;
    `.idle` means *the display did not change*, which is not loss. Real drops show up as
    `VTEncodeInfoFlags.frameDropped` on the encode callback. Don't conflate the two.

23. **`NSEvent.ModifierFlags` and `CGKeyCode` are absent from the iOS SDK.** (Bit *values* line
    up with `kCGEventFlagMask*` — shift `1<<17`, control `1<<18`, option `1<<19`, command
    `1<<20` — but they are an AppKit bit layout and must not live in shared code.)

### Testing-methodology traps

24. **A deterministic failure is a mapping problem, not noise.** When `--drive` failed with all
    four moves 20–54pt off, **byte-identical across runs**, the byte-identical part was the
    signal: timing jitter cannot produce identical offsets. Fit `actual = a·expected + b` per
    axis from the sample points and you get the exact wrong rectangle in one step. A *scale*
    error and a *rect* error are indistinguishable until you do this fit.

25. **A `settle`'s pong proves only that the command was received, not that its effect landed.**
    The host applies a source switch in a **detached `Task`**, so waiting for an async host
    effect requires polling its observable consequence.

26. **Probe checks must *establish* host state, not assume it.** Two checks failed
    deterministically with the host behaving perfectly, because each silently assumed a state
    an earlier check had changed:
    - `--drive` computed expectations from `CGDisplayBounds` (the display) while the host maps
      input through *whatever it is currently capturing* — and it deliberately keeps capturing
      the last client's source after that client leaves. `input.transform` starts correct
      (`HostModel.swift:113`) and is only reset by `ensureCapturing()`, which runs **only on a
      video connection** — and `--drive` is control-only. Now self-correcting: it asks for the
      main display and polls until the mapping actually changes.
    - The switch check needs the **catalogue**'s declared `pixelSize` to know how many
      `videoConfig` updates the host owes (two sources compositing to the same size owe none).
      The catalogue is pushed unsolicited ~3 ms after connect and can land *after* the probe's
      last control-channel read; a `--video-recv` run reads only the video channel for the whole
      window, so it can miss it and fall back to guessing. Now it awaits the catalogue first.

    **Both were test defects, not product defects.** When a check fails, the first question is
    "what did this check assume?"

27. **The catalogue is pushed unsolicited and is not guaranteed to beat the pong.** See above.

28. **A quiet screen hides capture races.** Seven attaches with a static screen gave
    `0 discarded awaiting a keyframe` every time; four attaches with the screen actively
    changing gave 1, 2, 2, 3. Use `Tools/activity.sh`.

29. **Keychain ACL denial is indistinguishable from "no key".** `loadOrCreateKey`
    (`SelfSignedIdentity.swift:187-222`) mints a **second** key when `SecItemCopyMatching`
    fails: application tags are not a uniqueness constraint for keys, so
    `SecKeyCreateRandomKey` with the same tag succeeds. The probe then presents a new public
    key and the host refuses with *"a client claiming to be X presented a different key"* —
    which reads like an attack, not like a local signing problem. The fix is
    `--reset --id <new-id> --accept`.

---

## 6. Current status (as of 2026-09-14)

### Working and verified

All of the following was green in the regression sweep:

| Check | Result |
|---|---|
| `--drive` | `cursor control verified` |
| `--hold-drop 55` | `HOLD AND DROP OK` |
| `--hold-button-drop 0` | `BUTTON HOLD AND DROP OK` |
| Input actions (keycode, cmd-combo, space switch, Unicode text) | all sent, no stuck modifiers |
| 3-source switch | `2 config update(s) (2 owed)` |
| Video accept / refusal | ✓ / ✓ |
| `--catalog` | `CATALOGUE OK · 38 source(s) offered` |
| Source lifecycle | A left on `window:24454` 600×500 → B got `1512×982` display |
| Keyframe gate under motion | counters 4→8 across 6 attaches, `dropped 0` |
| `RemoteCore` tests | **100 tests in 14 suites pass** |
| iOS device build | `BUILD SUCCEEDED` |

### End-to-end on hardware — **it works**

Verified on a real iPhone 15 Pro Max on 2026-09-14:

```
08:42:16  iPhone connected · TLS 1.3 · 65-byte key
08:42:16  Pairing code for iPhone: 057369
08:42:21  Paired with iPhone                      <- user confirmed the SAS match
08:42:22  encoder ready · ... 1800×1168 @ 60 fps 7 Mbps
08:42:22  video client attached · 1800×1168 h264
08:42:42  video client detached · sent 439, 11 keyframe(s), dropped 2
```

**20 seconds of live video, 439 frames, on the phone.** The whole vertical slice works.

### Open issue: reconnect loop (under investigation)

Immediately after that 20-second session ended, the iPhone entered an endless
connect→disconnect loop:

```
08:42:42.478  iPhone disconnected
08:42:43.534  iPhone connected · TLS 1.3 · 65-byte key
08:42:43.627  iPhone disconnected          <- ~90ms
08:42:45.933  iPhone connected
08:42:45.945  iPhone disconnected          <- ~12ms
...continues indefinitely, every 0.6–3s...
```

TLS succeeds every time and the host logs the client as connected, then it dies within
10–100 ms. The iOS app stays in the foreground and keeps retrying. **This is the current
front-burner bug** — a diagnosis was in flight when this file was written; check the repo's
recent commits/notes for the outcome before re-investigating from scratch.

---

## 7. Product behaviours worth knowing before "fixing" them

- **`forgetChosenSourceIfIdle()`** (`VideoCoordinator.swift:180`) exists so the next client does
  not inherit a departed client's source choice. Clearing the *choice* is synchronous and
  needs no ordering; it deliberately does **not** stop the capture stream, because a stop
  landing second can black out a client that has already arrived.
- **`ensureCapturing()`** (`VideoCoordinator.swift:259`) is deliberately **not** "is anything
  being captured" — a stream left running on a departed client's source is still running, and
  answering the narrow question is what let it be shown to the next client.
- **Switching sources rebuilds the `SCStream`** rather than calling `updateContentFilter(_:)`.
  That is a deliberate trade: an in-place swap still owes a fresh keyframe and still leaves the
  encoder holding a surface of the old size, so it saves the stream setup and nothing else while
  adding a second code path whose failure mode is frames in the wrong shape. The client sees no
  reconnect either way.
- **The catalogue suppression lives per-`HostSession`, not host-wide.** A host-wide "last
  catalogue" could not tell *which* client already had it, so the first client suppressed the
  push for all the others and every later client got an empty source picker.
- **The capture watchdog covers the start window only.** A static screen also produces no
  frames, but a static screen still delivers its *first* frame — so "no frame has **ever**
  arrived" distinguishes a dead stream from a still one, and later silence is left alone.
- **Video frames are droppable; keyframes are not.** `mouseDown`/`mouseUp`/`keyDown`/`keyUp` are
  never coalesced or reordered — a dropped `mouseUp` leaves a stuck button.
  `mouseMove`/`joystickMove` are coalesced to ~60 Hz (iOS emits up to 120 Hz).
- **`--video-only` is expected to be refused** — a video connection with no authorized control
  session must be rejected.
- **Clicking a captured app/window cannot defeat window stacking.** If the app is behind
  another window the injected click lands on whatever is actually frontmost. The mitigation is
  to raise the app on selection, not to synthesize around it.
- **`coordinator.onGeometry` is wired but nothing consumes it** — input mapping from the
  frame's content rect is deliberately deferred. This is where subtle drift bugs will live.

---

## 8. Working agreements

- The user's standing instruction is **"continue all work until you are done and i can verify"**
  — carry work through to a verifiable state rather than stopping to check in at each step.
- The user has authorised **spawning subagents to parallelise** work.
- **Keep explanations plain and short.** Direct feedback: *"i dont understand what did you just
  wrote."* No jargon dumps, no long recaps. Say what happened and what to do next.

---

## 9. Reference

- Approved plan: `/Users/dmq/.claude/plans/partitioned-dancing-lightning.md` — contains the full
  design rationale and a list of **verified defects in the original spec's sample code**
  (message framing missing entirely, three `CGEvent` calls that don't compile, a `CGSize`/`Data`
  mismatch, a leaked connection, etc.). Worth reading before assuming the spec is correct.
- iOS device id (iPhone 15 Pro Max): `8A51FAD5-A897-57CD-9C09-395D9F2C258A`
- Bundle ids: `pl.dmq.maccast.MacCast`, host keychain pin service `pl.dmq.maccast.pins`
- Port: **51515**
