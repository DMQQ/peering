import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// What a movement of the picture is carrying, and for which picture.
///
/// **Both directions of the movement carry a window between two rectangles.** Opening a tile
/// carries the window out of its tile and onto the fit it will have as the whole picture; going
/// back carries the same window from the fit into the tile it will hold. Either way there is a
/// part of the *arriving* picture that has a place on screen already, and a part of the picture
/// being *left* that it is travelling through — which is the whole of what is needed to keep the
/// picture still when it changes part-way through. See ``MosaicZoom/placing(pixelSize:anchor:at:bounds:scale:)``.
///
/// It is kept as fractions of each picture rather than as rectangles on screen because the
/// rectangles move: the movement is still going when the new stream arrives, and where the window
/// is *now* is a question that can only be answered at the instant it is asked.
struct PictureAim: Equatable {
    /// The picture that is arriving.
    let sourceID: String
    /// Whether the movement is lifting a window *out of* an arrangement, as opposed to carrying an
    /// arrangement back around one.
    ///
    /// **The direction decides whether anything is hidden.** Going out, the picture on screen is
    /// the arrangement and the window is a piece of it: the rest of it has to be hidden while that
    /// piece grows, or every other window flies across the screen with it. Coming back, the window
    /// is the whole picture and there is nothing to hide it among — a scrim there would black out
    /// the arrangement that is on its way in, which is what a return that flickers is made of.
    let carriesOutOfArrangement: Bool
    /// The part of it the movement is carrying, as a fraction of that picture: all of it for a
    /// window arriving on its own, and one tile's worth of it for an arrangement coming back.
    let anchor: NormalizedRect
    /// Where that part sits inside the picture being left, as a fraction of that one, and that
    /// picture's size. Together these say where the movement has the window at any instant.
    let departedAnchor: NormalizedRect
    let departedSize: CGSize
}

/// A movement of the picture, in flight.
///
/// **Kept as values rather than as the task alone.** A movement can be overtaken by the thing it
/// was for — the Mac builds a stream faster than the journey takes — and the answer cannot be a
/// second movement: the picture that arrives is put exactly where this one already has it, and
/// this one's aim is changed to where the picture now belongs, keeping the clock and the starting
/// values it already had. The curve then goes on being evaluated from where it is, so a picture
/// crossing the screen does not stop, and set off again, halfway.
struct PictureGlide {
    /// Where the movement is going. Changed in place when the picture changes under it.
    var target: (zoom: CGFloat, pan: CGSize)
    /// The state the curve is measured from. Re-solved when the aim changes, so that the value the
    /// curve gives *now* is the state the picture is drawn at now — see ``reaim(_:progress:)``.
    var startZoom: CGFloat
    var startPan: CGSize
    let startedAt: ContinuousClock.Instant
    var task: Task<Void, Never>?

    /// Aims the movement at `target` **through the state the picture is in**, keeping the curve.
    ///
    /// The curve is `start + (target − start) × progress`, and the progress it has reached is not
    /// ours to change — so the *target* is set first and the start is then solved, backwards, for
    /// the state the picture has to be in right now. Both halves matter, and leaving the target
    /// alone is what made this worse than not doing it at all: the movement went on towards the
    /// state it was aimed at *before* the picture changed, which belonged to the arrangement the
    /// window had just left — so the window was drawn at the arrangement's zoom, kept going to it,
    /// and nothing afterwards put it back.
    ///
    /// With progress near 1 there is nothing left to solve for, and the caller finishes instead.
    mutating func reaim(
        to target: (zoom: CGFloat, pan: CGSize),
        through state: (zoom: CGFloat, pan: CGSize),
        progress: Double
    ) {
        guard progress < 0.995 else { return }
        self.target = target
        let remaining = 1 - progress
        startZoom = (state.zoom - target.zoom * progress) / remaining
        startPan = CGSize(
            width: (state.pan.width - target.pan.width * progress) / remaining,
            height: (state.pan.height - target.pan.height * progress) / remaining
        )
    }
}

/// Touches, mapped through the picture.
///
/// An extension rather than a file of its own type: state and its gestures have to
/// agree about what the picture is, and the view is easier to read in pieces than as
/// one file of two thousand lines. Members are `internal` here because Swift's
/// `private` is file-scoped — see the note in `RemoteScreen`.
extension RemoteScreen {
    // MARK: - Gestures

    var gestures: some View {
        CanvasGestureView(
            onTouchDown: { point in
                guard let normalized = normalized(point) else { return }
                remoteCursor = normalized
                model.send(.mouseMove(to: normalized))
                model.send(.mouseDown(button: .left))
            },
            onTouchMove: { point in
                guard let normalized = normalized(point) else { return }
                remoteCursor = normalized
                model.send(.mouseMove(to: normalized))
            },
            onTouchUp: { point in
                guard let normalized = normalized(point) else { return }
                remoteCursor = normalized
                model.send(.mouseMove(to: normalized))
                model.send(.mouseUp(button: .left))
            },
            onSecondaryClick: { point in
                guard let normalized = normalized(point) else { return }
                remoteCursor = normalized
                model.send(.mouseMove(to: normalized))
                model.send(.mouseDown(button: .right))
                model.send(.mouseUp(button: .right))
            },
            onScroll: { translation in
                // Pixels, which is the unit the host's wheel event is built in (`units: .pixel`),
                // at the one scale this screen moves content by — see `ScrollNotch`. Doubling a
                // point of finger travel into two pixels is where that scale came from (one would
                // make scrolling a page take several swipes), and the wheel's notches are built on
                // the same figure rather than a second one of their own.
                model.send(.scroll(
                    dx: Double(translation.width) * ScrollNotch.pixelsPerPoint,
                    dy: Double(translation.height) * ScrollNotch.pixelsPerPoint
                ))
            },
            onZoom: { factor, centre in
                // **A hand on the picture takes it from any movement in flight.** A correction
                // glide is the app putting the picture where it thinks it belongs; a pinch is the
                // user saying where it belongs, and two writers with different answers is a picture
                // that fights the fingers. Cancelled here and in the pan below, which are the two
                // gestures that move the picture.
                cancelPictureGlide()
                let before = zoom
                let after = min(max(zoom * factor, minimumZoom), maximumZoom)
                // Anchored on the fingers rather than on the middle of the screen, which is the
                // whole reason the recogniser reports where it is centred. Zooming about the
                // centre walks the part being looked at out from under the hand looking at it, and
                // the user's next move is always the same: drag it back.
                //
                // Worked out from the scale actually *applied* rather than the one asked for. At
                // either end of the range the zoom is clamped, and a pan that went on moving for a
                // zoom that did not happen would slide the picture sideways while nothing grew.
                let applied = before > 0 ? after / before : 1
                pan = CGSize(
                    width: pan.width * applied
                        + (centre.x - canvasSize.width / 2) * (1 - applied),
                    height: pan.height * applied
                        + (centre.y - canvasSize.height / 2) * (1 - applied)
                )
                zoom = after
                // Do not clamp while the pinch is still producing samples. The available pan
                // range changes as zoom changes; clamping here silently rewrites the user's
                // offset mid-gesture and looks like the picture snapping to a new position.
                // Pan gestures are clamped when the user explicitly drags the picture instead.
            },
            onPanCanvas: { translation in
                cancelPictureGlide()
                pan = clampedPan(
                    CGSize(width: pan.width + translation.width,
                           height: pan.height + translation.height)
                )
            },
            onSizeChange: { size in
                canvasSize = size
            },
            interactionMode: interactionMode,
            // The drawn scale, not the user's zoom alone: `scalesToFill` enlarges the picture
            // without `zoom` moving, and a cropped picture is exactly the one with somewhere to
            // pan to. A hundredth of slack, so a floating-point return to 1.0 still counts as
            // fitted and gives the two-finger drag back to the Mac.
            isZoomed: effectiveZoom > 1.01,
            blockedRegions: blockedRegions,
            isMosaicShowing: model.isShowingMosaic,
            onMosaicTap: { point in
                // The point is turned into canvas coordinates by the same helper every other
                // gesture uses, so the zoom and the pan are accounted for exactly once, in the
                // one place that knows about both. Then the arrangement says which tile it is,
                // and a tap in a gap between tiles is a tap on nothing: that does nothing, which
                // is the honest answer for a place that is neither window.
                //
                // **The arrangement that is being *drawn*.** The borders and names on screen are
                // what the user aimed at, and a reorder leaves the Mac's answer naming the
                // arrangement the user has just left: resolved against that, a tap opens the
                // window the label above it no longer says. See ``shownMosaicLayout``.
                guard let layout = shownMosaicLayout,
                      let normalized = normalized(point),
                      let index = MosaicGrid.tileIndex(at: normalized, in: layout)
                else { return }
                openMosaicTile(index, in: layout)
            },
            onMosaicLift: { point in
                guard let index = mosaicSlot(at: point) else { return }
                withAnimation(Motion.tap) {
                    heldTile = index
                    targetTile = index
                    heldPoint = point
                }
            },
            onMosaicDrag: { point in
                guard heldTile != nil else { return }
                // The held frame follows the finger every step — it is the whole feedback of the
                // gesture — while the slot underneath only changes when it moves to another tile.
                // A drag over a gap between tiles keeps the last slot it was over: the alternative
                // is a highlight that blinks out whenever the finger crosses a seam, and a finger
                // being dragged across a grid crosses seams the whole way.
                heldPoint = point
                guard let index = mosaicSlot(at: point), index != targetTile else { return }
                withAnimation(Motion.tap) { targetTile = index }
            },
            onMosaicDrop: { dropHeldTile() },
            isPanelOpen: openPanel != nil,
            onDismissPanel: { withAnimation(Motion.settle) { openPanel = nil } },
            isStatusBarExpanded: statusBarExpanded,
            onCollapseStatusBar: { collapseStatusBar() },
            isKeyboardOpen: model.showKeyboard,
            onDismissKeyboard: { model.showKeyboard = false }
        )
        .ignoresSafeArea()
    }

    /// Which tile of the arrangement a point on the screen is over, or `nil` for a gap.
    ///
    /// The hit test the tap uses, which is the same one the borders are drawn with: a press that
    /// lands on the seam between two tiles picks up neither, because a slot that could be either is
    /// a slot the user did not mean. See ``MosaicGrid/tileIndex(at:in:)``.
    func mosaicSlot(at point: CGPoint) -> Int? {
        guard let layout = shownMosaicLayout, let normalized = normalized(point) else {
            return nil
        }
        return MosaicGrid.tileIndex(at: normalized, in: layout)
    }

    /// Lets go of the held tile: the arrangement takes the order it was dropped in.
    ///
    /// **One ask at the end rather than a rearrangement per slot.** Moving the tile under the
    /// finger would re-ask the Mac on every seam it crossed — six windows torn down and rebuilt,
    /// or re-composited, several times in a second of dragging. What the user is arranging is the
    /// order, and the order is only settled when they let go.
    func dropHeldTile() {
        let from = heldTile
        let to = targetTile

        // **The new arrangement in the same breath as letting go, and that is the whole of the
        // feedback.** The outline being carried is drawn where the finger is; the arrangement it
        // is dropped into is the client's own, known the instant the user lets go, and drawing it
        // at once means the outline travels from the thumb into the slot it was put in and every
        // window it displaced travels into its own. Asked of the Mac and *then* drawn — which is
        // what this did, because the borders were drawn from the Mac's answer — the outline simply
        // vanished and the arrangement under it reordered itself a moment later, with the names in
        // the old places the whole time. See ``shownMosaicLayout``.
        //
        // A spring rather than the tap's short curve, because this is a thing landing: the give at
        // the end is what says the tile has been put down rather than that the drawing changed.
        // The veil over the arrangement is on the same value, so it clears over the same movement.
        withAnimation(Motion.settle) {
            heldTile = nil
            targetTile = nil
            heldPoint = nil
            // The same call the panel's reordering used, so the two cannot disagree about what
            // moving a window up the arrangement means: the held one goes to that place and the
            // rest shift.
            if let from, let to, from != to {
                model.moveMosaicTile(from: from, to: to)
            }
        }
    }

    /// Opens one tile of the arrangement: the picture scales until that window fills the screen,
    /// and the Mac is asked for it at the tap.
    ///
    /// **The picture moves, and nothing is drawn over it.** This was a black scrim with a hole in
    /// it that opened out to the whole screen, on the reading that what a tap means is "this one,
    /// not the others". It could not work, twice over. The hole was a `Path`, and a `Path` has no
    /// animatable data — so the rectangle it was cut with could only ever jump, and what the user
    /// saw was the dimming and then a flash. And even animated, the window inside the tile was
    /// not the thing growing: black closed in around a picture that stayed exactly the size it
    /// was.
    ///
    /// So the zoom is real. Every tile is a fraction of one picture — the canvas the Mac
    /// composited — which means scaling the picture until the tile's rectangle is the screen *is*
    /// the window growing to fill it, with the other tiles leaving the edges on their own. That
    /// is the same sentence said with the picture instead of around it, and it is the only
    /// version of it that can be said with a live video layer.
    ///
    /// The transform is left where the movement put it: the Mac takes a moment to build the new
    /// stream, and until it does the last canvas frame is what is on screen — at the zoom that was
    /// asked for, which is what the user is looking at. What ends the movement is the new picture
    /// arriving, and the two ends of it are the same rectangle, so nothing moves when it does: the
    /// window is drawn at the fit the moment its own stream is the picture. See
    /// ``MosaicZoom`` for why that is true by construction rather than by luck, and ``resetPicture()``
    /// for the reset that expresses it.
    func openMosaicTile(_ index: Int, in layout: MosaicLayout) {
        guard layout.tiles.indices.contains(index) else { return }

        // **A tile whose window is not in the catalogue is a card, and a card is not a window.**
        // The Mac draws one for every source it can no longer capture — a window closed while the
        // arrangement was up is the ordinary way that happens — and there is nothing behind it to
        // open. Tapping it used to send the ask anyway, and the Mac, whose catalogue is the
        // authority on this, refuses to capture a window that is not there: no picture ever
        // arrives, so the movement that had already run left the arrangement magnified with
        // nothing selected and no answer coming to put it back. Saying nothing is the whole of
        // what this can do about it, and it is the honest answer for a tile that is a card.
        guard model.catalog?.descriptor(for: layout.tiles[index].source) != nil else { return }

        cancelPictureGlide()

        // **What the movement is carrying, recorded before it starts.** The window, whole, is
        // arriving; inside the arrangement it is leaving, it is the piece of one tile that the
        // movement is lifting out — and the two together are what keeps the picture still if the
        // Mac's stream arrives before the movement has finished, and what says which part of the
        // picture is the one thing the user should be watching. See ``pictureAim``.
        let sourceID = layout.tiles[index].source.stableID
        pictureAim = windowAnchor(in: layout, sourceID: sourceID).map {
            PictureAim(
                sourceID: sourceID,
                carriesOutOfArrangement: true,
                anchor: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                departedAnchor: $0,
                departedSize: layout.canvas
            )
        }

        // **The ask goes out at the tap, and the movement is only ever how it is shown.** Deferring
        // the ask to the end of the movement — which the closure this used to be handed did —
        // makes the switch depend on the movement finishing, and the movement is cancelled by
        // anything that interrupts it: a pinch, a drag, another tap, or the very config that
        // answers it. Every one of those was a tap that zoomed the arrangement in and then did
        // nothing at all, with the picture left magnified over an arrangement it had not left.
        //
        // It also costs the Mac the length of the movement before it starts building the stream,
        // which is time the two can spend at once: the movement describes where the window is
        // going, so a stream that arrives part-way through is drawn at the rectangle it already
        // occupies. See ``MosaicZoom``.
        model.focusMosaicTile(layout.tiles[index].source)

        guard let target = tileOpeningTransform(index, in: layout) else {
            // No transform to travel with — a tile the arrangement cannot place, which is a
            // window the catalogue has no size for. The switch is already on its way; only the
            // movement is skipped, and with it any promise about where the picture would land.
            // See ``MosaicZoom/opening(layout:index:sourceSize:bounds:effectiveZoom:pan:scale:)``.
            pictureAim = nil
            return
        }

        glidePicture(to: target)
    }

    /// Goes back to the whole arrangement, the window shrinking into the tile it will occupy.
    ///
    /// **The way out of an arrangement is the way in, backwards**, and it is not a nicety: a
    /// movement that describes what a tap did and then nothing on the way back says the app has
    /// two different ideas of what the two states are. The window shrinks to exactly the place it
    /// held in the canvas, which is also the place it is about to hold again, so the arrangement
    /// arrives around it rather than replacing it. See ``mosaicReturnTransform()``.
    ///
    /// **The ask goes out at the tap**, like a tile opening, and for the same reason: what is
    /// being shown is the user's decision and the movement is only how it is shown, so an
    /// interrupted movement must not be a tap that did nothing. It is also the entire wait — the
    /// Mac tears down one stream and builds six, and it is doing that while the window is still
    /// shrinking into its tile.
    func animateBackToMosaic() {
        cancelPictureGlide()

        // **The same thing carried, the other way round.** The window is what the movement has
        // hold of, and the arrangement that is coming is where it belongs — so the piece of the
        // arriving canvas that has to stay still is the tile this window will hold, and the piece
        // of the picture being left is the window itself, whole. See ``pictureAim``.
        let sourceID = model.activeSourceID
        let departedSize = model.capturePixelSize ?? .zero
        pictureAim = {
            guard let sourceID, let layout = model.mosaicLayout,
                  let anchor = windowAnchor(in: layout, sourceID: sourceID)
            else { return nil }
            return PictureAim(
                sourceID: CaptureSource.mosaic(layout).stableID,
                carriesOutOfArrangement: false,
                anchor: anchor,
                departedAnchor: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                departedSize: departedSize
            )
        }()

        // The ask, for the reason ``openMosaicTile(_:in:)`` gives: the arrangement is what the
        // user asked for, and a movement that is interrupted must not take the ask with it. Here
        // it also buys the whole of the wait: the Mac tears down one stream and builds the canvas,
        // and it is doing that while the window is still shrinking into its tile.
        model.returnToMosaic()

        guard let target = mosaicReturnTransform() else {
            // Nothing to travel to — the picture is not one of an arrangement's tiles. The switch
            // is already on its way; only the movement is skipped, and with it any promise about
            // where the picture would land.
            pictureAim = nil
            return
        }

        glidePicture(to: target)
    }

    /// Walks the picture from where it is to `target`.
    ///
    /// **The one animation in this app that drives the picture rather than a drawing over it.**
    /// The zoom and the pan reach the screen as a layer transform on a `UIView`, written frame by
    /// frame, so there is no SwiftUI value in an animation of them for `withAnimation` to
    /// interpolate — the curve is evaluated a step at a time instead, from the same two numbers
    /// the animation system is given. See ``Motion/settleProgress(at:)``.
    ///
    /// **Nothing is carried out when it lands, and that is deliberate.** The movement used to own
    /// the source switch: it ran the switch only if it got there, so a movement that was
    /// interrupted — by a pinch, by a drag, by the config answering it — was a tap that did
    /// nothing but leave the picture magnified. What is being shown and how it is shown are two
    /// decisions now, and the caller makes the first one before it starts the second.
    ///
    /// **Everything the loop reads is read from ``pictureGlide`` every step**, which is what lets
    /// a movement be re-aimed while it runs instead of being cancelled and restarted. See
    /// ``PictureGlide``.
    @discardableResult
    func glidePicture(to target: (zoom: CGFloat, pan: CGSize)) -> Task<Void, Never> {
        lockedPixelSize = model.capturePixelSize ?? .zero
        let glide = PictureGlide(
            target: target,
            startZoom: zoom,
            startPan: pan,
            startedAt: ContinuousClock().now,
            task: nil
        )
        let task = Task { @MainActor in
            let clock = ContinuousClock()
            while true {
                guard let glide = pictureGlide else { return }
                let seconds = (clock.now - glide.startedAt) / .seconds(1)
                let progress = Motion.settleProgress(at: seconds)
                // **Written only where it changes.** A movement can be aimed at the state it is
                // already in — a correction that has nothing to correct, the tail of a movement
                // that has finished travelling — and a write of the value a `@State` already holds
                // is still a write: the whole screen is rebuilt, sixty times a second, to draw
                // exactly what it drew before. See ``RemoteScreen/pictureAim`` for the one that
                // holds a hole open after the picture has arrived.
                let next = (
                    zoom: glide.startZoom + (glide.target.zoom - glide.startZoom) * progress,
                    pan: CGSize(
                        width: glide.startPan.width + (glide.target.pan.width - glide.startPan.width) * progress,
                        height: glide.startPan.height + (glide.target.pan.height - glide.startPan.height) * progress
                    )
                )
                if zoom != next.zoom { zoom = next.zoom }
                if pan != next.pan { pan = next.pan }
                // A little over one and a half times the spring's response, by which point it is
                // within a ten-thousandth of where it is going — a twentieth of a point of
                // travel. Waiting out the rest of it would be holding the user on a frozen canvas
                // to watch the last pixel arrive.
                if seconds >= Motion.settleResponse * 1.6 { break }
                // **Once per frame the screen can show, not more often.** Each step writes two
                // pieces of view state, and every write re-evaluates this whole screen — the
                // picture, the borders, the chrome — so a rate above the display's is work the
                // user cannot see done twice over, on the main thread, in the middle of the one
                // thing that has to stay smooth. The curve is read from the clock rather than
                // accumulated, so a late step shows the right place rather than drifting.
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
            }
            // Landed exactly, rather than wherever the last step happened to fall: the margin
            // above is invisible, and a picture left a fraction of a point from where it was
            // aimed would be a transform the next reset is measured against.
            guard let glide = pictureGlide else { return }
            if zoom != glide.target.zoom { zoom = glide.target.zoom }
            if pan != glide.target.pan { pan = glide.target.pan }
            pictureGlide = nil
        }
        pictureGlide = PictureGlide(
            target: glide.target,
            startZoom: glide.startZoom,
            startPan: glide.startPan,
            startedAt: glide.startedAt,
            task: task
        )
        return task
    }

    /// Stops the movement in flight, if there is one. The state stays where the picture is.
    ///
    /// **The promise goes with it.** What a movement is carrying is only true while it is running —
    /// a pinch that takes the picture over, or a tap on another tile, is a movement that will never
    /// arrive — and a promise left standing is a picture clipped to a rectangle nothing is
    /// travelling towards. Callers that mean to start a movement set a new one straight after.
    func cancelPictureGlide() {
        pictureGlide?.task?.cancel()
        pictureGlide = nil
        pictureAim = nil
    }

    /// The regions a touch must not reach the Mac through.
    var blockedRegions: [CGRect] {
        var regions = Array(chromeFrames.values)
        // A modal owns the whole screen while it is up. A tap meant for the pairing prompt must
        // not also land wherever the Mac's cursor happens to be sitting behind it.
        switch model.phase {
        case .connecting, .handshaking, .confirming:
            regions.append(CGRect(origin: .zero, size: canvasSize))
        default:
            break
        }
        return regions
    }

    /// How far the picture can move before one of its edges would leave the canvas.
    ///
    /// Zooming makes this reachable: without a limit the picture can be flung off the screen
    /// altogether, and the only thing that brings it back is the zoom reset, which is hidden
    /// while the zoom is at 100%. Losing the Mac with no visible way back is not a mode anyone
    /// would keep using.
    /// How far past the edge the picture may be dragged.
    ///
    /// The clamp used to stop exactly where the picture's edge met the screen's, which sounds
    /// right and is not: at that limit a corner of the desktop sits in the screen's own corner —
    /// underneath the rail, and in landscape underneath the notch as well. The corner the user is
    /// dragging towards to *look at* is the one thing they cannot see.
    ///
    /// How far past the edge the picture may be dragged: the thickness of the chrome, measured
    /// from where it actually is.
    ///
    /// Measured rather than calculated, and that is the whole point. Both earlier attempts worked
    /// the number out from the rail's nominal width — once as the width itself, once as the width
    /// plus its edge inset — and both were short by the same thing neither knew about: the rails
    /// sit *inside the safe area*, which in landscape is a wide inset on the side the sensor
    /// housing is on. On this phone the rail's inner edge is 121 points from the screen's edge,
    /// not the 62 the metrics describe, so a corner dragged towards it came to rest underneath it
    /// either way. Reading the frames the chrome reports cannot be wrong about this.
    ///
    /// The larger of the two sides on each axis, because the clamp is symmetric. Taking the
    /// larger rather than averaging costs a little slack on the narrower side and buys a picture
    /// that behaves the same whichever way it is pushed.
    ///
    /// Only ever added to an axis that already overflows: with the picture fitted there is nothing
    /// to reveal, and a margin there would let a drag pull the picture away from its own edges and
    /// show the backdrop.
    var panMargin: CGSize {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        var leading: CGFloat = 0, trailing: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0
        for (region, rect) in chromeFrames where region != .panel {
            // How far this piece of chrome reaches in from the edge it actually sits against:
            // the *smaller* of its two distances to the sides, because chrome hugs one.
            //
            // Taking `rect.minX` as the measure from the left and `width - rect.maxX` as the
            // measure from the right reads correctly for a single rect and is wrong for every
            // rect in the set. A rail down the left edge then reports `width - railMaxX` —
            // most of the screen — as the margin on the *right*, the max over both sides came
            // out at most of the screen, and a zoomed picture could be dragged a full screen
            // past its edge. Which is the one thing this clamp exists to prevent.
            let horizontal = min(rect.minX, canvasSize.width - rect.maxX)
            let vertical = min(rect.minY, canvasSize.height - rect.maxY)
            leading = max(leading, horizontal)
            trailing = max(trailing, horizontal)
            top = max(top, vertical)
            bottom = max(bottom, vertical)
        }
        // Plus a gap, so the picture's edge comes to rest beside the chrome rather than touching
        // it — the point is to see the edge, and an edge flush against a button is still an edge
        // that is hard to make out.
        let gap = ChromeMetrics.edgeInset * 2
        return CGSize(
            width: max(leading, trailing) + gap,
            height: max(top, bottom) + gap
        )
    }

    var panLimit: CGSize {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let rect = CanvasGeometry.videoRect(bounds: canvasSize, pixelSize: model.capturePixelSize)

        let margin = panMargin
        func limit(_ extent: CGFloat, _ canvas: CGFloat, _ margin: CGFloat) -> CGFloat {
            let slack = (extent * effectiveZoom - canvas) / 2
            if slack > 0 { return slack + margin }

            // When zoomed below fit, the picture is intentionally smaller than the canvas. Keep
            // a modest, zoom-proportional amount of travel instead of forcing it to the exact
            // centre; this lets the user place the reduced picture slightly off-centre without
            // allowing it to disappear completely.
            let underfitProgress = max(0, min(1, (1 - effectiveZoom) / (1 - minimumZoom)))
            return 80 * underfitProgress
        }
        return CGSize(
            width: limit(rect.width, canvasSize.width, margin.width),
            height: limit(rect.height, canvasSize.height, margin.height)
        )
    }

    func clampedPan(_ proposed: CGSize) -> CGSize {
        let limit = panLimit
        return CGSize(
            width: min(max(proposed.width, -limit.width), limit.width),
            height: min(max(proposed.height, -limit.height), limit.height)
        )
    }

    func normalized(_ point: CGPoint) -> NormalizedPoint? {
        CanvasGeometry.normalized(
            point: point,
            bounds: canvasSize,
            pixelSize: model.capturePixelSize,
            zoom: effectiveZoom,
            pan: pan
        )
    }

}
