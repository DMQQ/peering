# Premium: multiple virtual displays

> Update later on 24 September 2026: this feature is now implemented in the working tree. The
> standalone `CaptureProbe --virtual-display --virtual-count 3` proof created three simultaneous
> panels at 2796×1290, found all three in the ScreenCaptureKit catalogue, removed the first without
> disturbing the other two, then removed the rest. The probe also disproved the serial-only idea
> below: separate serials produced separate IDs but reset every panel to 800×600. The working
> implementation gives every extra display a distinct product/serial pair and reapplies all chosen
> modes after an add.

Written 24 September 2026, at the end of a session that shipped two smaller things first and
scoped this one without starting it. Read `CLAUDE.md` and `AGENTS.md` first.

## What this session actually shipped

Three unrelated pieces of work landed on `welcome-flow-and-fixes`, in this order:

1. **The app picker opens apps on the display the phone is looking at.** `HostModel` used to hand
   a freshly launched app straight to `NSWorkspace`, which puts its windows on whatever desktop the
   Mac's own window server considers current — the built-in screen, not the virtual one, whenever a
   virtual display is on. The fix moves the launched app's windows onto the right display's bounds
   with `AXUIElementSetAttributeValue`: Spaces are a window/display pairing kept by the window
   server, so a window whose position crosses onto another display joins whatever Space that
   display is showing, no Space switch needed. See `HostModel+AppLaunching.swift`.

2. **The virtual display rotates live and starts landscape.** `VirtualDisplay` now registers two
   `CGVirtualDisplayMode`s at creation (portrait and landscape, the same two numbers swapped) and
   starts on landscape. The phone reports its own orientation over a new
   `RemoteCommand.reportDeviceOrientation(isLandscape:)`, gated behind
   `ServerHello.supportsDeviceOrientation` the same way `supportsSourceThumbnails` and the others
   are, and the host switches the display's active mode with the **public** `CGDisplaySetDisplayMode`
   — no teardown, no second display, nothing that touches the identity trap below. Because
   `VideoCoordinator` has no way to notice a `CGDisplayMode` switch on its own, the orientation
   handler re-asks for the same capture source afterward (`applyCaptureSource(.display(id))`),
   which is what makes the stream re-read the new pixel size. See
   `MacCastHost/Display/VirtualDisplay.swift` and `HostModel+VirtualDisplay.swift`.

3. **`HostModel.swift` went from 2034 lines to a 914-line core plus seven
   `HostModel+*.swift` files** (Port, Widget, Capture, VirtualDisplay, AppLaunching, Sessions,
   SleepPrevention), matching how `MacSession` and `RemoteScreen` are already split. The user asked
   for this mid-session after noticing the file's size; it is orthogonal to the two features above
   but touches the same file, which is why it is mentioned here.

Both targets build clean as of this writing. None of it has been run on a device — the user
deferred testing to a future session and said so explicitly, so do not read the absence of a test
report as an oversight.

## What was asked for and not started

The user's actual request, verbatim from the session: *"can we add an PREMIUM option to app, to
1) Add virtual displays from within the app 2) Add regular displays from app?"*

A round of clarifying questions got three answers:

- Orientation should **live-rotate** (done, above — this part shipped).
- "Regular displays" in the second ask was clarified as **multiple virtual displays** — the user
  picked that reading over "capture more of the Mac's own physical monitors" and over "both." Take
  this as a steer, not a spec: it was a forced choice among three options in a rushed moment mid a
  much longer session, and the original two-part phrasing ("virtual displays" and "regular
  displays" as if they were different things) was never fully reconciled with it. **Confirm with
  the user before building** rather than trusting this note alone.
- Scope for the pass was "both, fully" — but then the session's remaining time went to the
  `HostModel` refactor instead, at the user's own redirection. So: **nothing below is built.**

## What building it actually requires

### The identity trap this collides with

`VirtualDisplay.init` hardcodes `serialNumber: 1`, `productID: 0x5045`, `vendorID: 0x646D`. See
[[virtual-display-identity-is-fixed]] in memory and the type's own header comment: the window
server refuses a second `CGVirtualDisplay` sharing a vendor, product and serial outright — the
error is literally "no displayID available," which reads like a resource exhaustion failure and is
actually an identity collision. **Supporting more than one virtual display at once means giving
each instance a distinct identity** — the obvious move is a serial number per instance, keeping
vendor and product fixed, but this has not been tried and the window server's tolerance for that is
unverified. Test it standalone (a small probe like `Tools/CaptureProbe` before touching `HostModel`)
before assuming it works.

### Where the single-instance assumption lives

`HostModel+VirtualDisplay.swift` (new this session) is now the one file that would need to change
shape: `virtualDisplay: VirtualDisplay?` is a single optional, and `setVirtualDisplay`,
`confirmThroughCatalogue`, `removeVirtualDisplay` and `restoreVirtualDisplay` are all written
against exactly one. Turning that into a collection (keyed by something stable — not the
`CGDirectDisplayID`, which is assigned by the window server and not known until creation succeeds)
is the shape of the work. Two things already generalize without rework:

- **Orientation is already per-instance.** `VirtualDisplay.setOrientation(landscape:)` and the two
  registered modes live on each `VirtualDisplay` object, not on `HostModel`, so N displays each
  rotating independently costs nothing extra.
- **Naming is already keyed by display ID.** `VirtualDisplay.names` (a `DisplayNames`, lock-guarded)
  already maps `CGDirectDisplayID → String`, built for exactly this.

The capture side should need little to no change: `CaptureSourceResolver` already reads every
display off `CGGetActiveDisplayList` and offers each as an ordinary `CaptureSource.display(_:)`, so
a second virtual display should appear in the catalogue the same way a second physical monitor
does, once the window server actually has one.

### The open question this session did not resolve

**Which app surface gets the "add" button?** Virtual displays are host-only —
`MacCastHost/Display/VirtualDisplay.swift`'s own header is explicit that `CGVirtualDisplay` must
never be reached for from `MacCast`, `MacCastKit` or `RemoteCore`, because the phone build would be
rejected for it. Today the single virtual display is a local toggle in the Mac's own window
(`HostStatusView+Settings.swift` calls `HostModel.setVirtualDisplay(_:)` directly, no network
involved). Two different features are both plausible readings of "add virtual displays from within
the app":

1. **The Mac app's own window** grows a list instead of a switch — add, remove, rename, pick an
   orientation default. No wire-protocol change, no plan gating possible on the Mac side at all
   (`PlanAccess`/`PlanCapability`, in `MacCastKit/Sources/MacCastKit/PlanAccess.swift`, is read only
   by `MacCast` — grep confirms nothing in `MacCastHost` touches it), so a premium gate on this
   reading has nowhere to live except the phone refusing to *pair with* or *stay connected to* a
   Mac that has more displays than the plan allows, which is an awkward retrofit.
2. **The phone asks the host to create one**, a genuinely new `RemoteCommand` case (the pattern in
   `RemoteCommand.swift` and `ServerHello` for a capability that is a new decode surface, not an
   old Mac silently failing — see how `setCaptureSource`'s `CaptureSource` gained the mosaic case).
   This is what makes a Pro/Plus gate meaningful, because the entitlement check runs on the phone
   before the command is ever sent, exactly like every other `PlanCapability` today.

(2) is almost certainly what "premium option... from within the app" means, since gating lives on
the phone everywhere else in this codebase, but it is materially more work than (1) — a new command,
a new capability flag, a host-side handler that creates a `VirtualDisplay` with a fresh identity on
request, and UI on the phone to manage the list rather than just a Mac-side settings row. Confirm
this reading before starting; building (1) when the user meant (2) would be a wasted session.

### The rest of the mechanical work, once the above is settled

- A new case on `PlanCapability` (`MacCastKit/Sources/MacCastKit/PlanAccess.swift`) — `minimumPlan`
  is a judgment call the user should make, but `.mosaic`/`.macros`/`.highBitrate` are all `.pro`
  ("the toolbox: the rung somebody buys to have the tool rather than to run out of it"), which reads
  as the closest existing precedent.
- `PLANS-AND-FEATURES.md`'s table and `Relay/site`'s prose, in the same commit as the
  `PlanCapability` change — the type's own doc comment says so, and it is the single source of
  truth this app has for what each plan includes.
- UI: a paywall card (see `PlanFeaturesView.swift` and `PaywallView.swift` for the existing
  pattern) and whatever surface answers the open question above.

## Related handoffs and memory

[[virtual-display-identity-is-fixed]], [[virtual-display-needs-a-turning-run-loop]],
[[one-desktop-per-screen-is-physical]] (a past attempt at a related idea — "one desktop per
screen" — was built and reverted; read it before assuming a similar shape works here).
`HANDOFF-multi-mac.md` is unrelated (multiple *Macs*, not multiple *displays on one Mac*) but is
the other in-flight multi-something feature on this branch, worth knowing about so the two are not
confused.
