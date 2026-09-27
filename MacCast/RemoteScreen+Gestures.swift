import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// A window's place in an arrangement, for the scrim a hero transition cuts a hole in while a tile
/// grows out of, or shrinks back into, its canvas.
///
/// Kept as fractions of each picture rather than as rectangles on screen because the frozen layer's
/// rectangle moves for the whole of the transition: where the window is *now* is a question that can
/// only be answered at the instant it is asked, against whichever picture is animating.
struct HeroCarry: Equatable {
    /// Whether the transition is lifting a window *out of* an arrangement, as opposed to carrying an
    /// arrangement back around one.
    ///
    /// **The direction decides whether anything is hidden.** Going out, the frozen snapshot is the
    /// arrangement and the window is a piece of it: the rest of it has to be hidden while that piece
    /// grows, or every other window grows across the screen with it. Coming back, the frozen snapshot
    /// is the window alone — a scrim there would black out the arrangement fading in behind it.
    let carriesOutOfArrangement: Bool
    /// Where the window sits inside the frozen snapshot, as a fraction of it, and that snapshot's own
    /// pixel size.
    let frozenAnchor: NormalizedRect
    let frozenSize: CGSize
}

/// One picture replacing another: the frozen layer's journey from where the outgoing picture was to
/// where the arriving one belongs, and the wait for the arriving picture to actually be ready.
///
/// **Everything here belongs to the frozen layer alone.** The live layer never moves during a
/// transition — it sits hidden at whatever the arriving picture's own resting transform is, written
/// once and left alone — which is the whole difference from the mosaic's first design. Nothing here
/// can flicker, because the one thing that used to flicker (a live video layer scaled while its
/// content swaps under it, on two different clocks) never happens: the layer doing the animating
/// never receives a new frame, and the layer receiving frames is never on screen until it is done
/// receiving them. See ``VideoHostView/stillView``.
struct PictureTransition {
    /// Identifies this transition uniquely, so a superseding one can tell an old animation's ticks
    /// and deadline apart from its own rather than by comparing the values they carry.
    let token: UUID
    /// The picture this transition is delivering. It ends only once the live layer is showing this
    /// exact source, not merely a picture of the same size, which a resize could produce by chance.
    let targetSourceID: String?

    /// The frozen layer's own zoom and pan, in the same drawn units ``RemoteScreen/effectiveZoom``
    /// uses, walked from `startZoom/startPan` to `endZoom/endPan`.
    ///
    /// Drawn rather than stored: the frozen layer's own picture never changes for the life of one
    /// transition, so unlike the live layer there is no shifting base to divide back out, and no
    /// reason to keep the two representations apart.
    var zoom: CGFloat
    var pan: CGSize
    let startZoom: CGFloat
    let startPan: CGSize
    let endZoom: CGFloat
    let endPan: CGSize
    let startedAt: ContinuousClock.Instant
    var task: Task<Void, Never>?

    /// Whether the journey above has reached `endZoom/endPan`. The transition ends only once this is
    /// true *and* the arriving picture is ready, whichever comes second — see
    /// ``RemoteScreen/endTransitionIfReady()``.
    var settled: Bool

    /// The window this transition is carrying, if it is directional. `nil` for a plain cut: a source
    /// picked from a panel, a lane switch, a rotation's rebuilt canvas, or a picture this screen did
    /// not see coming and is merely not flickering over.
    var carry: HeroCarry?

}

/// Touches, mapped through the picture.
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
            onHover: { point in
                guard let normalized = normalized(point) else { return }
                remoteCursor = normalized
                model.send(.mouseMove(to: normalized))
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
                // **A hand on the picture takes it from any transition in flight.** A hero
                // transition is the app moving the picture on its own account; a pinch is the user
                // saying where it belongs, and two writers with different answers is a picture that
                // fights the fingers. See ``cancelTransition()``.
                cancelTransition()
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
                cancelTransition()
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
            onPictureTap: {
                if statusBarExpanded { collapseStatusBar() }
                guard openPanel != nil else { return false }
                withAnimation(Motion.settle) { openPanel = nil }
                return true
            },
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

    /// Opens one tile of the arrangement: a frozen snapshot of the arrangement grows to fill the
    /// screen where that window sits, and the Mac is asked for the window at the tap.
    ///
    /// **The ask goes out at the tap, and the hero transition is only ever how it is shown.**
    /// What is being shown and how it is shown are two decisions: the ask is not deferred to the
    /// end of a movement, so an interrupted transition is never a tap that did nothing. It also
    /// costs the Mac the length of the animation before it starts building the stream, which is
    /// time the two can spend at once.
    func openMosaicTile(_ index: Int, in layout: MosaicLayout) {
        guard layout.tiles.indices.contains(index) else { return }

        // **A tile whose window is not in the catalogue is a card, and a card is not a window.**
        // The Mac draws one for every source it can no longer capture — a window closed while the
        // arrangement was up is the ordinary way that happens — and there is nothing behind it to
        // open. Tapping it used to send the ask anyway, and the Mac, whose catalogue is the
        // authority on this, refuses to capture a window that is not there: no picture ever
        // arrives, so the transition that had already run left the arrangement magnified with
        // nothing selected and no answer coming to put it back. Saying nothing is the whole of
        // what this can do about it, and it is the honest answer for a tile that is a card.
        guard model.catalog?.descriptor(for: layout.tiles[index].source) != nil else { return }

        // **And a tile that has already been asked for and answered with nothing is a card too**,
        // whatever the catalogue says about its window. That is the case the test above cannot
        // reach: a window ScreenCaptureKit lists and will not render. See
        // ``MacSession/sourcesThatOpenedNothing``.
        let sourceID = layout.tiles[index].source.stableID
        guard !model.sourcesThatOpenedNothing.contains(sourceID) else { return }

        guard let anchor = windowAnchor(in: layout, sourceID: sourceID),
              let target = tileOpeningTransform(index, in: layout)
        else {
            // No rectangle to travel with — a tile the arrangement cannot place, which is a window
            // the catalogue has no size for. The switch still happens; only the animation is
            // skipped, and with it any promise about where the picture would land.
            model.focusMosaicTile(layout.tiles[index].source)
            return
        }

        beginHeroTransition(
            to: sourceID,
            target: target,
            carry: HeroCarry(
                carriesOutOfArrangement: true,
                frozenAnchor: anchor,
                frozenSize: layout.canvas
            )
        )
        // **The arrangement as it looks this instant, kept for the way back.** The Mac tears the
        // canvas down to build this window's stream and builds it again when the user returns,
        // measured at about a second and a quarter, and the picture frozen a moment ago is the
        // only thing that can stand in for it. See ``VideoRenderer/mosaicSnapshot``.
        model.renderer.rememberMosaicSnapshot()

        model.focusMosaicTile(layout.tiles[index].source)
        watchTileOpening(sourceID)
    }

    /// Puts the arrangement back when a tile that was tapped never opens.
    ///
    /// **The one failure this screen cannot see coming.** Everything else about a tile is known
    /// before the tap: whether its window is still in the catalogue, whether the arrangement can
    /// place it, whether it has already opened nothing once. A window the Mac cannot capture is
    /// not knowable, so the only way to find out is to ask and wait.
    ///
    /// Three seconds. A second and a fifth covered the Mac building a stream, but a window on
    /// another desktop waits for the Mac to switch there first, and a tile that misses this is
    /// dead until the arrangement is rebuilt.
    private func watchTileOpening(_ sourceID: String) {
        model.tileOpeningWatch?.cancel()
        model.tileOpeningWatch = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            // **A picture with this source's name on it is the Mac answering.** Anything else is
            // no answer: the identity is still the arrangement's, so nothing was opened.
            guard model.picture?.sourceID == sourceID else {
                model.sourcesThatOpenedNothing.insert(sourceID)
                animateBackToMosaic()
                return
            }
        }
    }

    /// Goes back to the whole arrangement: a frozen snapshot of the window shrinks into the tile
    /// it will occupy, while the Mac tears the window's stream down and builds the canvas again.
    ///
    /// **The way out of an arrangement is the way in, backwards**, and it is not a nicety: a
    /// transition that describes what a tap did and then nothing on the way back says the app has
    /// two different ideas of what the two states are. The window shrinks to exactly the place it
    /// held in the canvas, which is also the place it is about to hold again, so the arrangement
    /// arrives around it rather than replacing it.
    ///
    /// **The ask goes out at the tap**, like a tile opening, and for the same reason.
    func animateBackToMosaic() {
        // **Whatever was waiting for a tile to open is over**, whoever decided that: the user has
        // asked for the arrangement, so a wait that outlived the ask would be this screen arguing
        // with them. See ``watchTileOpening(_:)``.
        model.tileOpeningWatch?.cancel()

        let sourceID = model.activeSourceID
        guard let sourceID, let layout = model.mosaicLayout,
              let anchor = windowAnchor(in: layout, sourceID: sourceID),
              let target = mosaicReturnTransform(sourceID: sourceID)
        else {
            // Nothing to travel to — the picture is not one of an arrangement's tiles. The switch
            // still happens; only the animation is skipped.
            model.returnToMosaic()
            return
        }

        beginHeroTransition(
            to: CaptureSource.mosaic(layout).stableID,
            target: target,
            carry: HeroCarry(
                carriesOutOfArrangement: false,
                frozenAnchor: anchor,
                frozenSize: model.capturePixelSize ?? .zero
            )
        )

        model.returnToMosaic()
    }

    /// Starts a hero transition: freezes the picture on screen, and walks that frozen snapshot from
    /// where it is to `target` while the live layer, hidden, waits for the picture it describes.
    ///
    /// **The one animation in this app that moves a picture rather than the whole live layer.** The
    /// frozen layer's own content never changes for the life of this transition, so unlike the
    /// mosaic's first design there is nothing here for a decoder to race: the zoom and the pan are
    /// walked on a plain per-frame timer, same as any other view state, because nothing downstream
    /// of them is fighting a second writer on a different clock.
    ///
    /// `target` is a *stored* zoom — a multiple of the current picture's own base, in the terms
    /// ``MosaicZoom/opening(layout:index:sourceSize:bounds:effectiveZoom:pan:scale:)`` and
    /// ``MosaicZoom/returning(layout:sourceID:sourceSize:bounds:effectiveZoom:pan:scale:)`` return it
    /// — because both are normalized against the picture on screen *now*, which is exactly the
    /// picture the frozen layer is a snapshot of and whose base does not change for the whole of the
    /// transition. Converted to a drawn scale once, here, rather than carried as a stored value the
    /// way the live layer's ``zoom`` is: the frozen layer has no shifting base to divide back out.
    @discardableResult
    func beginHeroTransition(
        to sourceID: String?,
        target: (zoom: CGFloat, pan: CGSize),
        carry: HeroCarry
    ) -> Task<Void, Never> {
        // **Nothing to animate over means no animation.** A freeze is the frame the live layer is
        // showing at this instant, so it cannot be the wrong tile or the wrong shape — but a layer
        // that has displayed nothing yet has nothing to give, and switching plainly is the honest
        // answer for a picture no one has seen.
        guard model.renderer.freezeCurrentFrame() else {
            return Task {}
        }

        let base = pictureBaseScale
        let start = (zoom: effectiveZoom, pan: pan)
        let end = (zoom: base * target.zoom, pan: target.pan)

        // The live layer's own resting state for whatever arrives. Safe to write immediately: it
        // is hidden behind the frozen layer for the whole of the transition, so nothing sees it
        // change.
        zoom = 1
        pan = .zero

        return startTransition(to: sourceID, from: start, to: end, carry: carry)
    }

    /// Freezes the picture in place with nothing to animate: a source picked from a panel, a lane
    /// switch, a rotation's rebuilt canvas, or a picture that arrived without this screen having
    /// asked for anything in particular. The frozen snapshot does not move; only the cross-fade to
    /// the arriving picture, once it is ready, is seen.
    private func beginPlainTransition(to sourceID: String?, resetZoom: Bool) {
        // The same rule as a hero: no frozen picture, no transition. A cross-fade from an image
        // nobody froze would put an older picture on screen for the whole of it.
        guard model.renderer.freezeCurrentFrame() else { return }
        let current = (zoom: effectiveZoom, pan: pan)
        if resetZoom {
            zoom = 1
            pan = .zero
        }
        startTransition(to: sourceID, from: current, to: current, carry: nil)
    }

    @discardableResult
    private func startTransition(
        to sourceID: String?,
        from start: (zoom: CGFloat, pan: CGSize),
        to end: (zoom: CGFloat, pan: CGSize),
        carry: HeroCarry?
    ) -> Task<Void, Never> {
        transition?.task?.cancel()

        let startedAt = ContinuousClock().now
        let alreadySettled = start.zoom == end.zoom && start.pan == end.pan
        let token = UUID()
        // Fixed rather than the default: the `PictureTransition` below and every reader of
        // `transition?.token` after it have to agree on the same value, and generating a second
        // one there would make ``endTransitionIfReady()``'s comparisons meaningless.

        let task = Task { @MainActor in
            guard !alreadySettled else { return }
            let clock = ContinuousClock()
            while true {
                guard var current = transition, current.token == token else { return }
                let seconds = (clock.now - startedAt) / .seconds(1)
                let progress = Motion.settleProgress(at: seconds, response: Motion.pictureResponse)
                if seconds >= Motion.pictureResponse * 1.6 {
                    current.zoom = end.zoom
                    current.pan = end.pan
                    current.settled = true
                    // **The arrangement as it looked when the user left it, put up the moment
                    // there is a place for it to sit still in.** Only for a return, and the picture
                    // and the transform go together: the transform the movement has just finished
                    // on belongs to the window, and the arrangement drawn at it lands as a canvas
                    // shrunk into one tile. The window's own tile is where the window has just been
                    // put either way, so nothing moves but the tiles that appear around it. See
                    // ``VideoRenderer/mosaicSnapshot``.
                    if current.carry?.carriesOutOfArrangement == false,
                       let arrangement = model.renderer.mosaicSnapshot {
                        model.renderer.hold(arrangement)
                        let canvas = CGSize(
                            width: CGFloat(arrangement.width),
                            height: CGFloat(arrangement.height)
                        )
                        current.zoom = pictureScale.base(pixelSize: canvas, in: canvasSize)
                        current.pan = .zero
                    }
                    transition = current
                    endTransitionIfReady()
                    return
                }
                current.zoom = start.zoom + (end.zoom - start.zoom) * progress
                current.pan = CGSize(
                    width: start.pan.width + (end.pan.width - start.pan.width) * progress,
                    height: start.pan.height + (end.pan.height - start.pan.height) * progress
                )
                transition = current
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
            }
        }

        transition = PictureTransition(
            token: token,
            targetSourceID: sourceID,
            zoom: start.zoom, pan: start.pan,
            startZoom: start.zoom, startPan: start.pan,
            endZoom: end.zoom, endPan: end.pan,
            startedAt: startedAt, task: task,
            settled: alreadySettled,
            carry: carry
        )

        armTransitionDeadline(token: token)
        if alreadySettled { endTransitionIfReady() }
        return task
    }

    /// Bounds the wait for a picture this end has already started showing a transition for.
    ///
    /// A transition that never ends leaves the picture frozen for good: the config it is waiting
    /// for can be lost to a network hiccup, or belong to a tile that never opens (though
    /// ``watchTileOpening(_:)`` already answers that one specifically, faster, by putting the
    /// arrangement back). This is the backstop for everything else — past the deadline, the live
    /// layer is shown wherever it currently is rather than left hidden behind a stale snapshot.
    private func armTransitionDeadline(token: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard transition?.token == token else { return }
            transition = nil
        }
    }

    /// Ends the current transition once its animation has settled *and* the picture it is for has
    /// actually reached the live layer — whichever of the two becomes true second. Called from every
    /// place either half of that can change: the animation's own completion, a frame reaching the
    /// live layer, and the picture identity changing.
    func endTransitionIfReady() {
        guard let transition, transition.settled,
              model.picture?.sourceID == transition.targetSourceID,
              model.isReadyToPlace(of: model.capturePixelSize ?? .zero)
        else { return }
        self.transition = nil
    }

    /// Called when a picture arrives that this screen did not already arrange a transition for: a
    /// panel pick, a lane switch, a rotation's rebuilt canvas, or the Mac answering with something
    /// this end never asked for.
    ///
    /// Nothing for a picture a hero transition already targets — ``openMosaicTile(_:in:)`` and
    /// ``animateBackToMosaic()`` have already frozen the right snapshot and are animating it; this
    /// would only interrupt that with a second, motionless freeze of whatever is on screen at the
    /// moment the config happens to land.
    func reactToPictureChange(from previous: PictureIdentity, to current: PictureIdentity) {
        switch previous.change(to: current) {
        case .unchanged:
            return
        case .resized:
            // The magnification is kept, because it is a multiple of the fit, and a lane switch
            // has nothing to do with what the user was looking at. The offset is measured in
            // points of a canvas whose picture has just changed shape, so left alone it can sit
            // outside the range the new picture allows.
            pan = clampedPan(pan)
            guard transition?.targetSourceID != current.sourceID else {
                endTransitionIfReady()
                return
            }
            beginPlainTransition(to: current.sourceID, resetZoom: false)
        case .replaced:
            guard transition?.targetSourceID != current.sourceID else {
                endTransitionIfReady()
                return
            }
            beginPlainTransition(to: current.sourceID, resetZoom: true)
        }
    }

    /// Gives up the transition in flight, if there is one. The live layer is left wherever its
    /// resting transform currently is, and is revealed at once.
    ///
    /// Called when the user's own gesture takes the picture over — see ``gestures`` — and when the
    /// session leaves `.ready`. A transition mid-flight has no promise worth keeping past either:
    /// the frozen snapshot it was animating belongs to a moment that has already passed.
    func cancelTransition() {
        guard let transition else { return }
        transition.task?.cancel()
        self.transition = nil
    }

    /// Gives up whatever transition or rearrangement was in flight.
    ///
    /// **Called when the connection leaves `.ready`, because none of it survives the connection it
    /// was measuring.** This view is kept across a drop on purpose — the picture stays up, and the
    /// zoom and the open panel with it — but the transit state does not belong to the picture that
    /// comes back.
    func abandonPictureTransit() {
        cancelTransition()
        heldTile = nil
        targetTile = nil
        heldPoint = nil
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
