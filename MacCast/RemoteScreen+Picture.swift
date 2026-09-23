import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// The picture, and the cursor drawn over it.
///
/// An extension rather than a file of its own type: state and its gestures have to
/// agree about what the picture is, and the view is easier to read in pieces than as
/// one file of two thousand lines. Members are `internal` here because Swift's
/// `private` is file-scoped — see the note in `RemoteScreen`.
extension RemoteScreen {
    // MARK: - Picture

    var video: some View {
        // No `scaleEffect` or `offset` here: the picture's placement is applied inside the view,
        // as a layer transform — see `VideoLayerView.updateUIView`, which is where a pan that
        // trailed the finger was coming from.
        VideoLayerView(renderer: model.renderer, zoom: effectiveZoom, pan: pan)
            .ignoresSafeArea()
            .overlay {
                // When the capture stream has stopped (source closed, app quit) the last
                // decoded frame stays visible on screen. Without a visual warning the user
                // touches what looks live but is actually stale — clicks land on whatever the
                // Mac currently shows at that position, not what the iPhone is displaying.
                if !model.isVideoStreaming && model.phase == .ready {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        VStack(spacing: 8) {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.85))
                            Text("Stream paused")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text(model.videoStatus)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    }
                    .allowsHitTesting(false)
                }

                // The Mac's own caption for a picture that is technically fine. Preferred to
                // the panel above, which never fires for this: a sleeping screen *is*
                // streaming — on time, at full rate, and entirely black — so "stream paused"
                // would be the wrong explanation and there would be no explanation at all.
                if let notice = model.remoteNotice, let message = notice.message, model.phase == .ready {
                    ZStack {
                        Color.black.opacity(0.72).ignoresSafeArea()
                        VStack(spacing: 12) {
                            Image(systemName: notice.symbol ?? "display.slash")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.9))
                            Text(message)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                        }
                        .padding(32)
                    }
                    // Hits pass through to the Mac, deliberately: an injected event is real
                    // user activity, and real user activity is what a sleeping display is
                    // waiting for. The way out of this screen is a tap on it.
                    .allowsHitTesting(false)
                }
            }
    }

    /// The Mac's pointer, drawn where this phone last put it.
    ///
    /// Only in control. In observe a tap reaches nothing, so showing a pointer would invite the
    /// exact interaction that mode promises to block.
    var clientCursor: some View {
        Group {
            if interactionMode.tapsReachTheMac,
               model.phase == .ready,
               // **Not over an arrangement.** A mosaic takes no input at all — a tap selects the
               // tile it landed in, and the Mac refuses everything else — so a pointer drawn where
               // the last tap landed is a promise this screen does not keep. Nothing is lost by
               // leaving it out: the Mac draws the real pointer into each tile, where it is
               // actually a pointer in a window. The Mac draws that one, into each tile.
               !model.isShowingMosaic,
               let point = CanvasGeometry.point(
                   normalized: remoteCursor,
                   bounds: canvasSize,
                   pixelSize: model.capturePixelSize,
                   zoom: effectiveZoom,
                   pan: pan
               ) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 0, x: 1.5, y: 1.5)
                    .frame(width: 32, height: 32, alignment: .topLeading)
                    .position(x: point.x + 16, y: point.y + 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .ignoresSafeArea()
    }

    /// The tiles' edges and names, when what is on screen is an arrangement.
    ///
    /// **Mapped through the same call the cursor goes through**, with the same zoom and pan, so
    /// the borders cannot drift from the picture they are drawn around: both are the letterboxed
    /// rect moved by the canvas's transform, and there is one expression of that in the app.
    ///
    /// Drawn only while the mosaic is the picture. Selecting a tile leaves the arrangement behind
    /// in every way that matters, and a border drawn around a single window would be the app
    /// describing a grid that is no longer on screen.
    /// Where one tile of the arrangement is on screen, or `nil` when there is no arrangement.
    ///
    /// The same ``CanvasGeometry`` call the borders are drawn with and the cursor is mapped
    /// through, so a tile's outline and the tap that opened it cannot disagree about where the
    /// tile is.
    func mosaicTileRect(_ index: Int, in layout: MosaicLayout) -> CGRect? {
        guard layout.tiles.indices.contains(index) else { return nil }
        return CanvasGeometry.rect(
            normalized: layout.tiles[index].rect,
            bounds: canvasSize,
            // **The arrangement's own canvas, not the picture on screen.** The two are the same
            // rectangle whenever a mosaic is what is showing, and they are not while one is on its
            // way — which is exactly when the borders have to be drawn for where the tiles are
            // going to be. See ``shownMosaicLayout``.
            pixelSize: layout.canvas,
            zoom: effectiveZoom,
            pan: pan
        )
    }

    /// The zoom and the pan that turn one tile of the arrangement into that window on its own.
    ///
    /// **Anchored on the window, not on the tile.** A tile is mostly black: the source inside it
    /// keeps its own shape and is letterboxed into whatever rectangle the grid gave it, so a
    /// window is a band across the middle of its tile with the canvas showing above and below.
    /// Moving *the tile* to the screen therefore moves the window somewhere it is never going to
    /// be — the framing a filtered window itself has is a different shape from the tile's — and
    /// the picture then jumps a second later when the real stream arrives at the fit. That jump
    /// is what the first version of this animation did, and it read as the whole movement being
    /// aimed at the wrong thing.
    ///
    /// So the two rectangles this maps between are both the *window's*: where it sits inside its
    /// tile now, and where it will sit when it is the whole picture, which is what
    /// ``CanvasGeometry/videoRect(bounds:pixelSize:)`` gives for the source's own size. The two
    /// have the same shape, so the movement between them is a straight scale about a point, and
    /// when the Mac's stream arrives the geometry does not change at all — the picture sharpens
    /// where it already is. See ``mosaicTileRect(_:)`` for the left-hand rectangle.
    ///
    /// Nothing to move between when the Mac's catalogue has no size for that source — a tile whose
    /// source has gone — and then the tile's own rectangle is the honest stand-in: it is on screen,
    /// it is what was tapped, and there is no window in it to aim at.
    ///
    /// **The division at the end is this view's and nobody else's.** The picture is drawn at
    /// ``pictureBaseScale`` times the number stored in `zoom` — the chrome's margin, or the user's
    /// Fill, whichever applies — so a target expressed as a drawn scale has to be turned back into
    /// a stored one before it can be written to the state. See ``effectiveZoom``, which is the
    /// other half of the same sentence.
    func tileOpeningTransform(_ index: Int, in layout: MosaicLayout) -> (zoom: CGFloat, pan: CGSize)? {
        guard layout.tiles.indices.contains(index) else { return nil }
        return MosaicZoom.opening(
            layout: layout,
            index: index,
            // The size the catalogue has for the window, which is the only thing either end knows
            // about how it is shaped before its stream arrives — and the same size the Mac builds
            // that stream at. Nothing is aimed at when it is missing: see ``MosaicZoom``.
            sourceSize: model.catalog?.descriptor(for: layout.tiles[index].source)?.pixelSize,
            bounds: canvasSize,
            effectiveZoom: effectiveZoom,
            pan: pan,
            scale: pictureScale
        )
    }

    /// The zoom and the pan that draw an arrangement that has arrived where the one before it was.
    ///
    /// **A turn of the phone is a different canvas, and this is the only way it can be one
    /// movement.** The Mac composites whatever rectangle it is asked for, so a phone held up shows
    /// a canvas of one shape and the same phone held sideways shows another; there is nothing in
    /// between, because there is nothing on the Mac in between. What there *is* is a place on the
    /// screen: the last frame of the old canvas is at rest in the middle of a screen that has
    /// already turned, and the new canvas can be drawn exactly there and then move to where it
    /// belongs. That is this transform — and because the tile borders are the new arrangement put
    /// through the same zoom and pan, they travel with it and stay on the windows they describe for
    /// the whole of the movement, which is the thing that was wrong with every earlier attempt at
    /// animating a rotation.
    ///
    /// `nil` when there is nothing to interpolate: **both** pictures have to have been arrangements
    /// — a rotation, or the arrangement re-asked with a window added — and there has to be a shape
    /// on screen to have come from.
    ///
    /// Only checking the one being left behind was a bug with a very visible signature: opening a
    /// tile leaves *from* an arrangement, so the morph ran when the window's stream arrived a second
    /// or two later and dragged the picture out to where the canvas had been and back. Two zooms,
    /// the second one late and unmotivated, on the one gesture in the app that already has a
    /// movement of its own. A tile being opened is a window arriving, and a window has
    /// ``tileOpeningTransform(_:)``; this is for arrangements replacing each other.
    func arrangementMorph(
        from previous: PictureIdentity,
        to current: PictureIdentity
    ) -> (zoom: CGFloat, pan: CGSize)? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              // The picture that has arrived is an arrangement, and so is the one it replaced.
              // The first is the screen's own answer and is already up to date by the time this is
              // asked — see the note on the call site.
              model.isShowingMosaic,
              // A mosaic's name is the only one in the app that starts with this, and it is the same
              // name `PictureIdentity` is built from. The value itself is the client's.
              previous.sourceID?.hasPrefix("mosaic:") == true,
              previous.pixelSize != current.pixelSize
        else { return nil }

        // Both rectangles through the one mapping, at the transform that is on the picture *now* —
        // so where the old one is means where it actually is, which is where the user had pushed it
        // if they had zoomed the arrangement before turning the phone, and not a rest position they
        // are not looking at.
        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        guard let from = CanvasGeometry.rect(
            normalized: full, bounds: canvasSize, pixelSize: current.pixelSize,
            zoom: effectiveZoom, pan: pan
        ), let to = CanvasGeometry.rect(
            normalized: full, bounds: canvasSize, pixelSize: previous.pixelSize,
            zoom: effectiveZoom, pan: pan
        ) else { return nil }

        return CanvasGeometry.transform(
            of: from, mappingTo: to, bounds: canvasSize, zoom: effectiveZoom, pan: pan
        )
    }

    /// The veil that covers the one frame of a turned arrangement that cannot be continuous.
    ///
    /// Dim rather than opaque, because the point of the movement is that it is *seen*: the picture
    /// travelling from one shape to the other is the whole of what a turn looks like now, and
    /// covering it would be a fade between two stills. What the dim is for is the instant the
    /// windows rearrange themselves inside that travelling frame — six rectangles becoming six
    /// different ones — which is a change of content and not of place.
    /// The same veil serves the reorder, at a lighter weight: a tile that has been picked up is a
    /// thing being looked at rather than a picture being replaced, and the arrangement under it
    /// should recede rather than disappear. See ``heldTile``.
    var arrangementVeilView: some View {
        Color.black
            .opacity(max(arrangementVeil * 0.55, heldTile == nil ? 0 : 0.4))
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// The zoom and the pan that put the picture back where the arrangement will be.
    ///
    /// **The movement a tile is opened with, run the other way.** A tile opening maps where the
    /// window sits inside its tile onto the framing it has as the whole picture; going back is the
    /// same journey in reverse, and the two have to agree or the way out of an arrangement and the
    /// way into it look like different features.
    ///
    /// The arrangement it aims at is the one being *asked for* — see ``MacSession/mosaicLayout``
    /// rather than ``MacSession/pictureMosaicLayout`` — because the ask is what the movement is
    /// for: the picture is a single window, and what is coming is the canvas built around it. And
    /// the state it aims at is the one the Mac's answer will put the view in: at rest, with the
    /// arrangement's fit on screen — which is what ``resetPicture()`` does the moment the new
    /// picture arrives. That is the trick of the whole thing: the movement ends exactly where the
    /// reset lands, so the canvas appears around the window with nothing moving at all.
    ///
    /// Nothing to move when the window on screen is not one of the arrangement's tiles — a source
    /// chosen after the mosaic was left, which is a session with no arrangement to go back to and
    /// no back control drawn on it. See ``MacSession/canReturnToMosaic``.
    ///
    /// The window is passed in rather than read from the model, because the ask is a source switch
    /// and it writes the arrangement's own id to ``SessionModel/activeSourceID``. Read after that
    /// the id matches no tile, and the movement is skipped.
    func mosaicReturnTransform(sourceID: String) -> (zoom: CGFloat, pan: CGSize)? {
        guard let layout = model.mosaicLayout else { return nil }
        return MosaicZoom.returning(
            layout: layout,
            sourceID: sourceID,
            sourceSize: model.capturePixelSize,
            bounds: canvasSize,
            effectiveZoom: effectiveZoom,
            pan: pan,
            scale: pictureScale
        )
    }

    /// The arrangement everything drawn over the picture is drawn for.
    ///
    /// **The ask rather than the answer, wherever the two are the same arrangement** — which is
    /// the whole of what makes a reorder land under the finger. A reorder, a change of a tile's
    /// size, and a return from one of the tiles all produce the *same canvas*: same size, same
    /// windows, same parameter sets. So the Mac never sends a new video config, the answer never
    /// arrives to say what changed, and an overlay drawn from it goes on naming the windows in the
    /// arrangement the user has just left. The client is the side that built these rectangles —
    /// the arrangement is its own — so it draws them, and the Mac's composite catches up under it.
    ///
    /// **And the answer wherever they are not**, because there the picture really is a different
    /// one: a turn of the phone, or a window added to the arrangement, makes a canvas of another
    /// shape which the Mac takes a moment to build, and borders drawn for it over the old canvas
    /// are borders on windows that are not there. That is what ``MacSession/pictureMosaicLayout``
    /// exists for, and this defers to it.
    ///
    /// Nil when no arrangement is being shown *and* none is on its way — which is what keeps the
    /// borders off a picture the user has chosen since leaving the mosaic.
    var shownMosaicLayout: MosaicLayout? {
        // **Nothing to draw while a window is being lifted out of an arrangement.** Every one of
        // these lines is drawn around a window, and while the movement is carrying one the rest of
        // the picture is clipped away: the lines would be outlines around nothing, and there is no
        // reading of that other than the arrangement having broken. Fading them with the pictures
        // they describe is what makes a tap read as one window leaving.
        guard !isCarryingWindowOut else { return nil }

        if let arrived = model.pictureMosaicLayout {
            // **And not before the picture they describe is on screen.** A config reaches the model
            // a frame or two before its picture reaches the layer, and borders raised in that gap
            // are six rectangles standing over the window they have just replaced.
            //
            // Asked of the layer rather than of ``pendingArrival``, which is a state the arrival
            // handler sets and is therefore a beat behind: gated on that, the borders went up with
            // the config, came down when the handler ran, and went up again with the frame.
            guard model.hasPictureOnScreen(of: model.capturePixelSize ?? .zero) else { return nil }
            guard model.isAskingForMosaic, let asked = model.mosaicLayout else { return arrived }
            return sameArrangement(asked, arrived) ? asked : arrived
        }

        // **Nothing on the way back, and drawing it there was a mistake worth naming.** The picture
        // is one window and what is coming is the arrangement built around it, so the borders of
        // that arrangement can be drawn the moment the ask goes out — and drawn there they say the
        // arrangement has already arrived: six rectangles standing over a single window that is
        // still shrinking into one of them. The movement is the whole of what a return has to say,
        // and it says it better with nothing drawn over it. See ``mosaicReturnTransform()``.
        return nil
    }

    /// Whether two arrangements are the same canvas holding the same windows.
    ///
    /// The question ``shownMosaicLayout`` turns on, and it is deliberately not `==`: a reorder is
    /// a *different* layout — that is the entire point of it — and it is still the same picture.
    /// What makes the picture new is a canvas of another shape, or a window that has arrived or
    /// gone, because those are what the Mac has to build a stream again for.
    private func sameArrangement(_ one: MosaicLayout, _ other: MosaicLayout) -> Bool {
        one.canvas == other.canvas
            && Set(one.tiles.map(\.source)) == Set(other.tiles.map(\.source))
    }

    /// The window a movement is carrying out of an arrangement, on screen, or `nil`.
    ///
    /// **The only part of the picture the user should see while one window is growing out of it.**
    /// A tile is a fraction of a single canvas, so growing one window means scaling that canvas —
    /// and every other window in it is scaled and moved with it, which is what a tap on a window
    /// looked like it was doing: rectangles flying about at two or three times their size while the
    /// one that was tapped grew. The tap means one window, so this is the rectangle that says which
    /// one: the same rectangle the movement is carrying, which is why it grows with it, and the
    /// same one the arriving stream is put on when it turns up.
    ///
    /// Nil when nothing is being carried out of an arrangement. The way back is the case that
    /// matters: the window is alone on the screen, there is nothing to hide it among, and clipping
    /// it to itself would be clipping the picture to the whole picture.
    var carriedWindow: CGRect? {
        guard isCarryingWindowOut, let aim = pictureAim else { return nil }

        // **Before the switch the window is a piece of the arrangement; after it, it is the
        // picture.** The two are the same rectangle at the instant the stream arrives — that is
        // what ``MosaicZoom/placing(pixelSize:anchor:at:bounds:scale:)`` guarantees — but they are
        // measured through different pictures, and reading the arrangement's geometry against the
        // window's stream is a hole of the wrong size for as long as the movement has left to run.
        //
        // Which one to read is decided by what the movement has been solved for, not by what the
        // Mac has just configured: switched on the model, the hole is measured through the window
        // at the arrangement's zoom and the whole mosaic shows through where it used to be.
        guard placedPictureID != nil, placedPictureID == model.picture?.sourceID else {
            // The departing picture's own base, not `effectiveZoom`: a movement that finished
            // before the stream arrived leaves `pictureGlide` nil, and `pictureBaseScale` then
            // reads the arriving stream's size for a rectangle measured through the arrangement.
            let departed = pictureScale.base(pixelSize: aim.departedSize, in: canvasSize) * zoom
            return CanvasGeometry.rect(
                normalized: aim.departedAnchor,
                bounds: canvasSize,
                pixelSize: aim.departedSize,
                zoom: departed,
                pan: pan
            )
        }
        return CanvasGeometry.rect(
            normalized: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            bounds: canvasSize,
            pixelSize: model.capturePixelSize,
            zoom: effectiveZoom,
            pan: pan
        )
    }

    /// The cover over the one frame in which the layer and the transform disagree.
    ///
    /// **The two cannot be committed together from here.** The video layer swaps its own contents
    /// on the renderer's queue; the transform that scales them is written by the main thread in
    /// `updateUIView`. So around every source switch there is a frame in which the arriving
    /// picture is drawn at the departing picture's scale: the window at twice its size in the
    /// middle of a zoom in, the canvas at half size in the middle of a zoom out.
    ///
    /// **Covering it is cheaper than it sounds.** The content changes at that instant whatever
    /// happens, so what the cover hides is a change that is going on regardless; what it removes
    /// is the size being briefly wrong, which is the part that reads as a blink. One frame, and
    /// only while the arrival is unsettled: the render that follows clears it and carries the
    /// transform the picture was waiting for. See ``RemoteScreen/settleArrival(force:)``.
    var swapVeil: some View {
        ZStack {
            if let pending = pendingArrival, model.hasPictureOnScreen(of: pending.current.pixelSize) {
                Color.black.ignoresSafeArea().allowsHitTesting(false)
            }
        }
    }

    /// Whether a window is being lifted out of an arrangement, and the rest of it has to be hidden.
    ///
    /// **Decided by the promise alone, and it stays decided.** Every finer condition tried here was
    /// a moment at which the hole *closed*, and closing it is the one thing this must not do: the
    /// instant it goes, whatever is behind it is revealed, and a reveal is a flicker whether the
    /// thing revealed was meant to be there or not. So the hole opens when a movement starts
    /// carrying a window, and it stays open — over black, which is what is behind a window once its
    /// stream is up, so leaving it open costs nothing to look at — until the picture changes to one
    /// this movement was not about. See the arrival in `RemoteScreen`, and ``PictureAim``.
    ///
    /// The direction is the other half. Going *back* to an arrangement the window is the whole
    /// picture, there is nothing to hide it among, and a hole measured around it would black out
    /// the arrangement on its way in.
    private var isCarryingWindowOut: Bool {
        pictureAim?.carriesOutOfArrangement == true
    }

    /// Everything of an arrangement except the window being lifted out of it, hidden.
    ///
    /// **Drawn rather than masked.** The rest of the picture has to go while one window grows into
    /// the screen — the canvas is a single picture and scaling it moves every window in it, so the
    /// others are not something the user should be watching — and a layer mask is the obvious way
    /// to do it and the expensive one: masking a video layer makes the compositor render the whole
    /// picture through an alpha channel on every frame, in the middle of the one movement that has
    /// to be smooth. A black shape with the window cut out of it is the same thing seen from the
    /// front — what is behind it is black either way, and the picture leaves no gap anywhere else
    /// — for the price of filling a path. See ``carriedWindow``.
    var carryingScrim: some View {
        ZStack {
            if let window = carriedWindow {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: canvasSize))
                    path.addRect(window)
                }
                .fill(Color.black, style: FillStyle(eoFill: true))
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
    }

    /// Where a window's picture sits inside one tile of an arrangement, as a fraction of the canvas.
    ///
    /// **The piece of an arrangement that a movement carries.** A tile holds a window the way a page
    /// holds a picture, and where that window is *inside the canvas* is the question both directions
    /// of the movement need answered: once for the arrangement being left behind, where the window
    /// is what the movement is carrying out of it, and once for the arrangement arriving, where the
    /// window is the piece of the incoming canvas that has to stay still. See ``PictureAim``.
    func windowAnchor(in layout: MosaicLayout, sourceID: String) -> NormalizedRect? {
        guard layout.canvas.width > 0, layout.canvas.height > 0,
              let index = layout.tiles.firstIndex(where: { $0.source.stableID == sourceID }),
              let size = model.catalog?.descriptor(for: layout.tiles[index].source)?.pixelSize,
              let window = MosaicTileFit.windowRect(
                  sourceSize: size,
                  in: layout.tiles[index].rect.pixels(in: layout.canvas)
              )
        else { return nil }

        return NormalizedRect(
            x: Double(window.minX / layout.canvas.width),
            y: Double(window.minY / layout.canvas.height),
            width: Double(window.width / layout.canvas.width),
            height: Double(window.height / layout.canvas.height)
        )
    }

    /// Which window sits in one slot of a drawn arrangement, or `nil` when there is no such slot.
    ///
    /// Checked rather than indexed, because the arrangement is the one being *asked for*: it can be
    /// replaced between the moment a finger picks a tile up and the moment it puts one down, and an
    /// index that was in range when the press began need not still be.
    private func window(at slot: Int?, in layout: MosaicLayout) -> String? {
        guard let slot, layout.tiles.indices.contains(slot) else { return nil }
        return layout.tiles[slot].source.stableID
    }

    var mosaicOverlay: some View {
        // **A `ZStack` and not a `Group`**, which is the difference between this animating and
        // this appearing. A `Group` has no layout of its own — every modifier on one lands on
        // each branch separately — so there is nothing for a transition to be attached to and
        // the two states just swap. The `ZStack` is the container the fade belongs to.
        ZStack {
            if let layout = shownMosaicLayout {
                MosaicOverlay(placed: layout.tiles.enumerated().compactMap { index, tile -> MosaicOverlay.Placed? in
                    guard let rect = mosaicTileRect(index, in: layout) else { return nil }
                    return MosaicOverlay.Placed(
                        // **The window, not the slot.** A slot's identity is its place in the
                        // arrangement, and a reorder moves windows between places without moving
                        // any place: keyed by index, nothing about the views changes and there is
                        // nothing for the drop to animate. Keyed by the window, the outline held
                        // under the finger travels into the slot it was dropped in and every
                        // window it displaced travels into its own.
                        id: tile.source.stableID,
                        rect: rect,
                        title: model.catalog?.descriptor(for: tile.source)?.title
                    )
                }, held: window(at: heldTile, in: layout),
                   heldPoint: heldPoint,
                   target: window(at: targetTile, in: layout))
                // **Opacity, and nothing that moves.** Every other entrance in this app slides or
                // scales, and none of them can here: these borders are drawn on the tiles they
                // outline, and a line travelling into place would spend the whole animation
                // somewhere the tile is not. What fades is the app's account of where the windows
                // are; the picture underneath never moved.
                .transition(.opacity)
            }
        }
        // Keyed on whether the borders are drawn at all rather than on whether the Mac has
        // answered: the entrance is the arrangement appearing, and on the way back from a tile it
        // appears the moment the user asks. See ``shownMosaicLayout``.
        .animation(Motion.settle, value: shownMosaicLayout != nil)
        .ignoresSafeArea()
    }

    /// How the picture is scaled on its way to the screen, over and above the user's zoom.
    ///
    /// A value rather than a number, because the answer depends on which picture is being asked
    /// about: in Fill a canvas and one of its windows are scaled by different amounts, and that
    /// difference is what the movement between them is measured against. See ``PictureScale``,
    /// which is where the arithmetic lives, and ``MacCastKit/MosaicZoom``, which is what uses it.
    var pictureScale: PictureScale {
        PictureScale(
            scalesToFill: scalesToFill,
            // Portrait has no margin, and the asymmetry is the chrome's rather than a preference:
            // the pill and the dock sit above and below the middle of the screen, and the canvas
            // of an arrangement is a band across that middle. See ``ChromeMetrics/pictureInset``.
            inset: deviceIsLandscape ? ChromeMetrics.pictureInset : 0
        )
    }

    /// What the picture is drawn at, and — because every touch is mapped back through it — what
    /// a touch means. One property rather than two, so a click can never be resolved against a
    /// scale the picture is not actually drawn at.
    ///
    /// In Fill the user's zoom rides *on top of* the fill scale rather than competing with it,
    /// and that is the whole difference between a pinch that works and one that looks broken.
    ///
    /// It was `max(zoom, fill)`, which discarded the user's zoom for as long as it was the
    /// smaller of the two — and the fill is 1.4× in landscape and over 3× in portrait for a
    /// full-size desktop, so a pinch had *no effect whatsoever* until the picture had already
    /// been magnified past the fill by some other means. There is no other means: the pinch was
    /// the door, and this was the lock on it.
    ///
    /// Multiplying leaves the resting state exactly as it was — at `zoom == 1` this is the base
    /// scale — and gives every step of the pinch somewhere to go from there.
    var effectiveZoom: CGFloat {
        pictureBaseScale * zoom
    }

    /// What the picture **on screen** is multiplied by, over and above the user's zoom.
    ///
    /// The margin costs nothing anywhere: it is not a box the drawing has to be moved into, it is
    /// the same rectangle drawn 85% as large about the same centre. See ``pictureScale`` for the
    /// picture-dependent half, which is the one a movement between two pictures has to be careful
    /// about.
    var pictureBaseScale: CGFloat {
        // **Use the locked size while animating.** When a glide is running the pixel size the
        // ``zoom`` factor was calibrated against is ``lockedPixelSize``, not whatever the model
        // currently reports — see the note on ``lockedPixelSize`` for why this matters.
        let size = pictureGlide != nil ? lockedPixelSize : (model.capturePixelSize ?? .zero)
        return pictureScale.base(pixelSize: size, in: canvasSize)
    }

    /// Whether the new picture is already drawn where a reset would draw it.
    ///
    /// **Asked of the rectangle rather than of the zoom.** A zoom is a multiple of whatever the
    /// picture's own fit is, and a reset is the number 1 — so "the zoom is not 1" and "the picture
    /// is not where it belongs" are not the same question, and only the second one is about
    /// anything the user can see. A reorder, a source picked out of a panel, a return to an
    /// arrangement: all of them are already at rest when they arrive, and the reset is then a
    /// re-expression of the same rectangle rather than a movement.
    ///
    /// Asked the moment a new picture arrives, so everything it reads is the new picture's:
    /// ``capturePixelSize`` is the stream that has just been configured and ``effectiveZoom`` is
    /// that picture's own base scale times the stored zoom. It is deliberately *not* the test for
    /// a window a movement was aimed at — see ``RemoteScreen/openingTarget`` for why the number
    /// cannot answer that one — and the two tests together are the correction in `RemoteScreen`.
    var pictureIsAtRest: Bool {
        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        guard let size = model.capturePixelSize,
              let now = CanvasGeometry.rect(
                  normalized: full, bounds: canvasSize, pixelSize: size,
                  zoom: effectiveZoom, pan: pan
              ),
              let rest = CanvasGeometry.rect(
                  normalized: full, bounds: canvasSize, pixelSize: size,
                  zoom: pictureBaseScale, pan: .zero
              )
        else { return true }

        // A point of slack, which is under the eye's: the aim is right to within a pixel of the
        // even-rounding of a tile's surface, and a correction for that would be a movement the
        // user watches for half a second to travel nowhere.
        return abs(now.midX - rest.midX) < 1
            && abs(now.midY - rest.midY) < 1
            && abs(now.width - rest.width) < 1
            && abs(now.height - rest.height) < 1
    }

    /// Puts the picture back where a phone that has just opened a source expects it: at the
    /// default zoom, and centred.
    ///
    /// **One is the app's default, and it is not the same thing as "not scaled".** `effectiveZoom`
    /// is the picture's own base scale times this number — see ``pictureScale`` — so at 1 the
    /// picture is exactly as the fit draws it: the whole screen in Fit, the screen's edges in Fill.
    /// The zoom is a multiple *of* the fit, which is why the reset is this number and not a
    /// smaller one.
    ///
    /// The percentage chip in the status pill resets through here as well, and the two have to be
    /// the same number: a reset that landed somewhere else would leave the chip reading 100% over
    /// a picture that was scaled.
    ///
    /// Not animated, and it cannot be: the zoom reaches the picture as a layer transform with Core
    /// Animation's implicit animations switched off (see ``VideoLayerView/updateUIView(_:context:)``),
    /// and the frames behind it are being replaced at the same moment, so an animation would spend
    /// its length drawing the new source at the old source's scale.
    func resetPicture() {
        zoom = 1
        pan = .zero
    }

}
