# The mosaic's flicker and load time

Written 23 September 2026, at the end of a long session on this. Read `AGENTS.md` and
`HANDOFF-multi-mac.md` first, then this.

**Read this file before believing any conclusion in it.** A lot of the work below is dead ends,
and several of them were reported to the user as fixes before they were disproved. The section
"Things that were tried and did not work" is the point of the document.

## What still does not work

Two symptoms, both reported from the phone, both still reproducing at the time of writing.

1. **After a zoom out, the canvas takes a couple of seconds to fill in.** The mosaic's tiles are
   black or missing and appear over the next second or two. The user's own words: "still couple
   seconds for the canvas to render all mosaic tiles after zoomOut".

2. **After a zoom in, the tile flickers about a second after the movement finishes**, and reads
   as the wrong window being shown for a moment. "still tile flickers after zoomin, like if it was
   showing wrong window for a moment".

They may or may not be the same fault. Nothing established so far joins them, and the assumption
that they were the same cost several rebuild cycles.

## Things that were tried and did not work

### Ordering the transform against the frame swap

**The mechanism, which is real and is the root of most of this.** `AVSampleBufferDisplayLayer`
swaps its own contents on the render server's clock. The transform that scales the picture is
written by the main thread in `VideoLayerView.updateUIView`. Nothing orders the two, so around
every source change there is a moment where one of them has moved and the other has not:

- transform first, then the frame: the **outgoing** picture is drawn at the **incoming** scale.
  Measured from the phone, the whole mosaic appearing for an instant during a zoom into a tile.
- frame first, then the transform: the **incoming** picture is drawn at the **outgoing** scale.
  The user described this one exactly as "300% zoom" for the first moments of a new tile.

**Everything below was an attempt to order them, and every one of them was visible.** Do not
spend another cycle on ordering. The two writes cannot be made atomic from this side.

- Writing the transform and releasing the held frame in the same `CATransaction`, with
  `setDisableActions(true)` (`VideoLayerView.updateUIView`). Still a frame apart, because
  `enqueue` queues for the next display cycle rather than displaying.
- Enqueueing the frame synchronously on the caller's thread instead of hopping to the video
  queue, so it lands inside the caller's transaction (`VideoRenderer.releaseHeldFrame`). Kept,
  because it is strictly better than a queue hop, but it did not remove the flicker.
- Holding the first frame of a new config until the arrival is solved for
  (`heldFirstFrame`, `releaseHeldFrame`, `Snapshot/readyGeneration`, `Snapshot/displayedGeneration`).
  This is a real improvement and it is worth keeping: it removed a class of flash where the
  picture changed before its transform existed. It did **not** remove this one.
- Delaying the release until the movement has finished rather than as soon as the transform is
  written (`RemoteScreen+Picture.pictureIsPlaced` requiring `pictureGlide == nil`). This moved
  the change of sharpness from mid movement to rest, which reads better, and it is kept. It did
  not remove the flicker.

### The veil

A black cover over the one frame in which the two disagree, added to the view stack in
`RemoteScreen.body`. **It never drew a single frame**, and the reason is worth keeping: the
condition was `pendingArrival != nil && hasPictureOnScreen`, and `settleArrival` ran in the same
runloop turn that set `pendingArrival`, so no render ever happened with the condition true. A
state-based cover cannot work here unless something guarantees a render in between.

### Frames drawn around the window instead of the grid slot

`mosaicTileRect` was changed to return `MosaicTileFit.windowRect(...)` so an outline hugged the
picture rather than the slot. Reverted: a frame takes the shape of what it is drawn around, so
six windows of six shapes became six frames of six shapes, and the user reported "the frame
heights are uneven". The frames are the grid's rectangles, and there is a comment saying so.

### Drawing the arrangement while the Mac builds it

`shownMosaicLayout` was made to return `model.mosaicLayout` on the way back, so the frames went up
the moment the ask did. Reverted on the user's instruction: the frames are measured against the
client's idea of the arrangement while the picture on screen is still one window being carried
into its tile, so they shift with the movement, and the user called it "weird rebuild".

### Waiting longer for the Mac's first canvas

The first canvas used to go out as soon as one tile had a picture, which meant five black tiles
and the one tile that had a picture being the one the user had just left. Holding it for all six
tiles took 1500ms **on every build** because one tile never delivers, so the user got a longer
black period rather than a fuller canvas. Now 700ms, with never delivered tiles marked dead at the
deadline. See below.

### Two false conclusions from misread logs

Recorded because both were reported to the user as findings and both were wrong.

- "The Mac is dropping streams: some taps produce no video config." False. The trace was read
  through `sed -n '/tap tile/,/glide landed/p'`, which stops printing at `glide landed`, and the
  `picture replaced` lines were after it. **Read these traces raw, or with a filter that cannot
  drop lines between the events you are comparing.**
- "5 of 6 tiles live" was read as the bound being too short. It is one tile that never delivers.

## What is believed to be true, with the evidence

**The Mac's canvas is sent before all its tiles have a picture.** The compositor's `tick()` used
to require one live tile and now requires all of them (or the deadline). Measured from the Mac's
own log:

    first canvas: 5 of 6 tiles live after 1534ms, <deadline>
    first canvas: 6 of 6 tiles live after 412ms, all ready

The first line is the fault, the second is healthy. That log line is in `MosaicCompositor.tick()`
and is the instrument to use.

**One window of the user's six never delivers a frame.** Its capture starts and then says nothing.
It is the small one (210x80 in the captures measured). Best hypothesis: a window that is not being
rendered, hidden, minimised, or on a Space that is not showing. `SCShareableContent` lists those
deliberately, and `CaptureSourceResolver.registerObservers()` says so in a comment. Not confirmed.
`markDead(index)` at the deadline is the current answer; it draws a card, unblocks the canvas, and
triggers the catalogue invalidation that thins the arrangement.

**A second change of picture per tile selection has no cross-fade.** A lane switch re-describes
the same window at another resolution, the reduced quality stream giving way to the full quality
one. It arrives as `PictureIdentity.Change.resized`, not `.replaced`, so it did not go through
`settleArrival`. `RemoteScreen` now cross-fades it too. Unverified.

**The unconfirmed hypothesis for "the wrong window for a moment".** The frames and the tap are
resolved against the arrangement the *client* holds, and that can change under a canvas that is
still on screen: when a tile's window dies, the client thins the arrangement and re-asks, and
between the thinning and the new canvas arriving the client's idea of which window is in slot 4
and the canvas on screen disagree. Tapping slot 4 then opens the right window by the client's
reckoning while the canvas shows the old one at that rectangle for a few frames. **Never
confirmed.** The question that separates it from everything else: does it happen on any tap, or
only after something in the arrangement changed?

## The cross-fade, which is built and unproven

`VideoHostView` has a second video layer under the live one (`stillView`, `stillContentView`). On
every `configure` the renderer hands it the outgoing stream's last frame
(`VideoRenderer.outgoingFrame`, `lastEnqueued`, `attachStill`). At a swap the live layer is hidden
and given the new transform while the still keeps the outgoing picture at the outgoing transform,
then the live layer fades back in over 180ms.

It runs. The trace says so:

    picture replaced ... zoom=0.4826
    layer releases the held frame at zoom=1.0008
    layer transform zoom=1.0008  still=true

**It does not fix the reported flicker, and the reason is instructive**: the canvas being faded
*to* was black, so the cross-fade dissolved the window into black and then the tiles filled in. A
transition cannot rescue a picture that has nothing in it. Decide whether to keep it once the
canvas arrives complete; it costs one extra layer and one retained sample buffer.

It has not been wired to do the "snapshot" (holding the canvas across a whole tile visit so the
tiles are visible during a return). It refreshes on every source change, so it holds the
immediately previous picture, which is what the fade needs. Holding it for two changes is the
change that would give the snapshot.

## Instruments

- `MacCast/FlickerDiagnostics.swift`, `flickerTrace(...)`, DEBUG only, written to stdout and read
  with `xcrun devicectl device process launch --console --terminate-existing --device <udid>
  pl.dmq.peering`. **The device must be unlocked or the launch fails** with an error whose text
  does not say so. The `VideoLayerView` lines report the transform actually written
  (`layer transform zoom=... still=...`) and the moment the frame is handed over
  (`layer releases the held frame at zoom=...`). These are the only trustworthy source for what
  the picture is drawn at; do not infer it from `zoom` and `base`.
- The host's unified log, subsystem `pl.dmq.peering.host`, categories `capture`, `video`,
  `spaces`, `session`. `/usr/bin/log show --predicate 'subsystem == "pl.dmq.peering.host"' --last 15m --style compact`.
  zsh's `log` builtin shadows the command; use the full path.
- `first canvas: N of M tiles live after Xms, <all ready|deadline>` in category `capture`.
- `strings` on a Swift binary proves nothing about what is deployed; Release strips local symbols.
  Compare the binary's timestamp with the object files in DerivedData instead.

## Traps that cost time here

- **The host build.** `Tools/build-install-host.sh` builds Release into the default DerivedData and
  `ditto`s it over `/Applications/Peering.app`. A plain `xcodebuild -scheme MacCastHost` writes
  somewhere else and changes nothing about what runs. One host build failed on a type error and
  was nearly reported as installed; check the exit status and the binary's timestamp.
- **The phone install.** `Tools/install-iphone.sh`. A running app keeps the old binary until it is
  relaunched, and the console bridge dies when the app is replaced, so it has to be restarted.
- **`sed` ranges in log filters.** See the false conclusions above.
- The mosaic takes no input by design. A broken arrangement is escaped through the Apps panel,
  which picks a single source and clears the stored arrangement.

## Decided, 23 September 2026: the picker lists only windows that are on screen

`isUserFacingWindow` in `MacCastHost/Capture/CaptureSourceResolver.swift` now requires
`window.isOnScreen`, so a window that is closed but still held, minimised, or on a Space the Mac is
not showing is not offered at all. That is the item below, answered in the affirmative, and it comes
from the phone's side rather than from this file: "the apps modal sometimes displays windows that
dont exist or are closed but app is still alive, please filter the windows that are not clickable".

Measured at one moment with `Tools/CaptureProbe/run-capture-probe.sh --list` against
`CGWindowListCopyWindowInfo` for the same second: 9 sources offered, 86 layer-0 windows in the
window server, 82 of them off screen, four of those titled and therefore listed by the old rule (the
host's own window, two Terminal windows on another Space, WeatherMenu). Do that comparison again
rather than trusting this paragraph; the sets move as Spaces change.

**A window that is on screen and still useless is not covered by this**, and one exists: Chrome
keeps a 66x20 window titled "Window" at the top left of the second display, on screen by every
measure the window server offers, and it is a row in the picker. Only `uncapturable` can remove
that, and it is only ever populated from the mosaic path (`noteTileUncapturable`). The single-source
case goes through `VideoCoordinator.reportNoFrames`, which is where a mark would go if the user
reports those rows again.

## Where to look next

1. **Why does that one tile never deliver a frame?** Everything else is downstream of it. Log the
   missing tile indices and the source at the moment the first canvas goes out; if it is a window
   that is not on screen, decide whether the picker should list those at all for a mosaic. **On
   screen is now a condition of being listed**; see the section above for the measurement.
2. **Confirm or kill the wrong-window hypothesis** with the one question at the end of that
   section. If it is confirmable, the fix is to hold the frames and the tap resolution to what the
   canvas shows until the new canvas arrives, rather than to the arrangement the client has just
   changed.
3. Only then decide about the cross-fade and the snapshot.
