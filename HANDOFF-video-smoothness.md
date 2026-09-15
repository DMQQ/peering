# Handoff: the streamed picture is not smooth

Written 2026-09-16. Everything below is either **measured** or marked as **reasoned**. Read the
measurements first — several plausible theories were killed by them and re-deriving them wastes
a day.

---

## 1. The symptom

The pointer, and motion generally, is choppy in the video on the iPhone.

**The single most important fact: the pointer is inside the video.** It is not drawn by the
phone. `CursorOverlay` draws it into the host's frames before encoding (or, when it is off,
macOS draws it and it is captured). So the pointer's smoothness *is* the video frame rate and
nothing else. There is no separate thing to fix.

Confirming detail from the user: **the Mac's own cursor is perfectly smooth on the Mac**, and
only the streamed one is choppy. That is exactly this — macOS draws its cursor at the display
refresh rate, the stream contains still pictures.

## 2. What has been measured

| Measurement | Value | How |
|---|---|---|
| Effective frame rate, Mac screen changing normally | 30 fps | client's fps counter |
| Effective frame rate, still screen | 2-15 fps | same |
| Effective frame rate with the idle path on and the pointer moving | **1 fps** | same |
| Encoder drops at 60 fps / 10 Mbps | **zero** | host log: `encoder dropped a frame` never appears |
| Encoder drops at 120 fps / 10 Mbps | many | host log, seven in twenty seconds |
| Full-size stream | 1512×982 | host log `capture started` |
| `CGDisplayPixelsWide` on this Mac | **1512, not 3024** | measured — it returns *points* |

**The encoder is not the bottleneck at 60 fps.** That is measured, not assumed: the host log
shows a clean stream at 60 fps and 10 Mbps with no drops and no errors. Any theory that blames
encoding has to explain that.

## 3. Architecture in play

- `MacCastHost/Capture/CaptureEngine.swift` — owns the `SCStream`. Deliveries are routed by
  status: `.complete`/`.started` become **frames** (`onFrame`); everything else (`.idle`,
  `.blank`, …) is an **idle sample** (`onIdle`).
- `MacCastHost/Capture/CapturePipeline.swift` — `ingest(_:)` for frames, `idle(_:)` for idle
  samples, both funnelling into `encode(_:)`.
- `MacCastHost/Capture/CursorOverlay.swift` — draws the enlarged pointer into a frame's luma
  plane; also holds a retained copy of the last picture.
- `MacCast/VideoRenderer.swift` (client) — decodes via `AVSampleBufferDisplayLayer`. Drops
  non-keyframe frames while `awaitingKeyframe` or when the layer is not ready.
- The client's fps counter is in `MacCast/SessionModel.swift`, `updateFrameRate(from:)`,
  surfaced in `videoStatus` and shown in the status pill.

## 4. The root of it

**ScreenCaptureKit only produces a picture when the display content changes.** A sample is
delivered on schedule regardless, but carries status `.idle` and no new picture when nothing
changed. `CaptureEngine` has always dropped those.

So on a still Mac screen the stream produces almost nothing, and the pointer — which lives in
those pictures — barely moves. This is the whole problem, and it is why the choppiness is worst
exactly when you are using the remote desktop to do something quiet.

## 5. What has been tried, and what happened

### 5.1 Drawing the cursor ourselves — done, keep it

`CursorOverlay` + `showsCursor = false`. The user asked for a bigger pointer; SCK has no
cursor-scaling API (verified against the macOS 26.5 SDK headers). The pointer is drawn into the
luma plane (frames are `420v`; luma 16/235 for video range). This works visually and is a
`Settings` toggle (`enlargePointer`, `pointerSize`).

**It did not fix smoothness and it is not the cause.** Turning it off restores `showsCursor =
true`, which is the decisive experiment in §7.

### 5.2 Synthetic frames from idle samples — built, measured beautiful, **breaks the client**

The idea: on an idle sample, redraw the pointer into the retained picture and re-encode. A
pointer moving is a tiny change; those frames are cheap and would make the pointer independent
of SCK's change detection.

It was modelled against a real `VTCompressionSession` and measured at **59.5 fps on a still
screen for one whole-picture copy in total**. On the device it does the opposite: the rate sits
near 30 until the pointer is touched, then **collapses to 1 fps**.

The signature — first synthetic frame fails, renderer resets, latches onto awaiting-keyframe,
and only the two-secondly keyframes get through — says the **client is refusing the frames this
path invents**. Something about them is wrong: a timestamp, an attachment, or a reference to a
picture the decoder never had.

**It is currently disabled**: `CapturePipeline.idleFramesEnabled = false`, with the reasoning in
the comment there. Turning it back on reproduces 1 fps. Do not turn it on to "test" without a
way to see the client's decode state — see §8.

### 5.3 Joystick cadence — a real bug, fixed, independent of all this

`JoystickView.emit` gated sending on the incoming touch samples ("has it been 1/60 s since the
last send?"), and they arrive at ~60 Hz, so they never satisfied it. Jitter meant one sample was
refused and the next burst through with double the movement: the Mac was told about the pointer
in ~30 irregular jumps a second. Sending is now on its own timer and the accumulator is flushed
on release. **This may well be a real part of the choppiness and it is independent of the video
pipeline** — judge it separately.

### 5.4 Bitrate — was half what H.264 needs

`VideoEncoder.defaultBitRate` used 0.06 bits per pixel per frame; doubled to 0.12. At 120 fps
the old figure asked for 10 Mbps for 1512×982, the encoder could not fit frames into it, and it
**dropped** them — that was the 1 fps the user saw at 120. The frame rate is back to 60 and the
setting is stored at 60.

Note the arithmetic that makes this confusing: the formula scales with frame rate, so raising
the rate does not spread the same bits thinner — it asks for twice the bits for twice the
frames. The per-frame budget is unchanged. 120 fps at this bitrate was never a smoothness
upgrade.

### 5.5 Ruled out — do not re-investigate

- **Nagle.** `noDelay = true` on both ends and on the relay tunnel.
- **The client's sample-buffer attachments.** `DisplayImmediately`, `NotSync`,
  `DependsOnOthers` are all set correctly at the sample-attachment level.
- **Main-actor contention on the phone.** `enqueue` is deliberately kept off the main actor.
- **The input rate.** Client sends at 60 Hz, host posts at ~83 Hz, deltas are time-weighted.
- **The encoder at 60 fps.** Zero drops, measured.
- **Low-latency rate control.** Already on — `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`.

## 6. Current state of the tree

**Everything is uncommitted** on branch `welcome-flow-and-fixes`. The last commit is `bc450e6`.
`git status` is the source of truth; there is a lot in there from several agents and not all of
it is about this problem.

Relevant switches:

- `CapturePipeline.idleFramesEnabled = false` — §5.2, the synthetic-frame path.
- Mac Settings pane: `captureResolution` (`full`/`half`), `captureFrameRate` (`60`/`120`),
  `enlargePointer`, `pointerSize`. All in `HostModel`, all applied at the **next** capture.
- `captureFrameRate` is currently stored as **60** via `defaults write pl.dmq.peering.host`.

## 7. The decisive experiment nobody has run

**Turn "Larger pointer" off in the Mac's Settings pane and reconnect.**

That setting does more than its name says. Off means `showsCursor = true` — the Mac's own cursor
goes back into the capture. Moving the mouse then **changes the captured content**, so SCK
delivers a real frame, so the pointer moves in the video. No synthetic frames, no new mechanism,
nothing near the decoder.

- **If the counter climbs properly**, frame production is the whole problem, the synthetic path
  is unnecessary, and the remaining work is making the pointer bigger *without* turning the
  system cursor off — which is a different and much easier problem.
- **If the counter stays low with the system cursor captured**, then SCK's dirty detection does
  not fire on cursor movement at all, the theory in §4 is wrong, and everything should be
  re-derived from the measurements in §2.

Run this before writing any code.

## 8. Diagnostics that do not exist yet and should

Both numbers are already computed and neither is visible, which is why two rounds of this were
diagnosed by deduction instead of by looking:

1. **The client's `awaitingKeyframe` state and reset count** — `VideoRenderer`'s snapshot has
   `awaitingKeyframe`, and `videoStatus` already appends "waiting for a keyframe". Worth showing
   persistently, and a reset counter alongside it.
2. **The host's encoder drop count** — `VideoEncoder.statistics` has it. It was the number that
   would have found the 120 fps problem on day one, and it was invisible because the phone only
   showed *client*-side drops.

With those two on screen, the next attempt at §5.2 can be diagnosed in one connection.

## 9. Things that are fine, do not disturb

- The Accessibility window move (`InputInjector.windowMove`) — verified with a `CGEventTap`.
- The pointer clamp to the captured content (`clamped(_:to:)`, `captureBounds(_:)`).
- The joystick cadence fix (§5.3).
- The connecting modal, the welcome flow, the FAQ, the widget, the intents, renaming.

## 10. The honest summary

The picture is produced at the rate the screen changes, and that is the whole of the problem.
Everything else — the cursor we draw, the bitrate, the frame-rate setting — is either a
contributor that has been addressed or a red herring that has been ruled out by measurement.
Two attempts at manufacturing frames from pointer movement failed; the first was aimed at the
wrong cause, the second broke the client's decoder in a way that needs the diagnostics in §8 to
see. The experiment in §7 is cheap, needs no code, and decides which half of this document the
next effort belongs to.
