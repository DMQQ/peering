import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// The picture, and the cursor drawn over it.
///
/// Members are `internal` here because Swift's `private` is file-scoped: state and its gestures have
/// to agree about what the picture is, and they live in both files.
extension RemoteScreen {
    // MARK: - Picture

    var video: some View {
        // No `scaleEffect` or `offset` here: the picture's placement is applied inside the view, as
        // a layer transform, so a pan cannot trail the finger. See `VideoLayerView.updateUIView`.
        VideoLayerView(
            renderer: model.renderer,
            zoom: effectiveZoom,
            pan: pan,
            pictureIsPlaced: pictureIsPlaced,
            stillZoom: stillZoom,
            stillPan: stillPan,
            showsStill: swapping
        )
            .ignoresSafeArea()
            .overlay {
                // The last decoded frame stays on screen when the capture stream has stopped (source
                // closed, app quit), and a touch then lands on whatever the Mac shows at that
                // position rather than on what the phone is displaying.
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

                // The Mac's own caption for a picture that is technically fine. The panel above
                // never fires for this: a sleeping screen *is* streaming, on time and entirely
                // black, so "stream paused" would be the wrong explanation.
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
                    // Hits pass through to the Mac deliberately: an injected event is the activity a
                    // sleeping display is waiting for, and the way out of this screen is a tap on it.
                    .allowsHitTesting(false)
                }
            }
    }

    /// The Mac's pointer, drawn where this phone last put it.
    ///
    /// Only in control: in observe a tap reaches nothing, so a pointer would invite the exact
    /// interaction that mode promises to block.
    var clientCursor: some View {
        Group {
            if interactionMode.tapsReachTheMac,
               model.phase == .ready,
               // Not over an arrangement: a mosaic takes no input at all, so a pointer drawn where
               // the last tap landed is a promise this screen does not keep. The Mac draws the real
               // pointer into each tile.
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
    /// Drawn only while the mosaic is the picture: a border around a single window would describe a
    /// grid that is no longer on screen.
    ///
    /// Where one tile of the arrangement is on screen, or `nil` when there is no arrangement.
    ///
    /// The same ``CanvasGeometry`` call the borders are drawn with and the cursor is mapped through,
    /// so a tile's outline and the tap that opened it cannot disagree about where the tile is.
    func mosaicTileRect(_ index: Int, in layout: MosaicLayout) -> CGRect? {
        guard layout.tiles.indices.contains(index) else { return nil }
        guard let tile = CanvasGeometry.rect(
            normalized: layout.tiles[index].rect,
            bounds: canvasSize,
            // The arrangement's own canvas, not the picture on screen: the two are the same
            // rectangle whenever a mosaic is showing, and not while one is on its way. See
            // ``shownMosaicLayout``.
            pixelSize: layout.canvas,
            zoom: effectiveZoom,
            pan: pan
        ) else { return nil }

        // The slot, not the window inside it: a frame takes the shape of what it is drawn around, so
        // window-shaped frames make the grid read as a pile of rectangles. The grid's own rectangles
        // are all the same size.
        return tile
    }

    /// The zoom and the pan that turn one tile of the arrangement into that window on its own.
    ///
    /// Anchored on the window, not on the tile: a tile is mostly black, the source inside it
    /// letterboxed into whatever rectangle the grid gave it, so moving the tile moves the window
    /// somewhere it is never going to be and the picture jumps when the real stream arrives. Both
    /// rectangles mapped between are the window's and have the same shape, so the movement is a
    /// straight scale about a point and the geometry does not change when the stream arrives. See
    /// ``CanvasGeometry/videoRect(bounds:pixelSize:)`` and ``mosaicTileRect(_:)``.
    ///
    /// With no size in the catalogue for that source there is no window to aim at, and the tile's
    /// own rectangle is the stand-in.
    ///
    /// The division at the end turns a drawn scale back into a stored one: the picture is drawn at
    /// ``pictureBaseScale`` times `zoom`. See ``effectiveZoom``.
    func tileOpeningTransform(_ index: Int, in layout: MosaicLayout) -> (zoom: CGFloat, pan: CGSize)? {
        guard layout.tiles.indices.contains(index) else { return nil }
        return MosaicZoom.opening(
            layout: layout,
            index: index,
            // The size the catalogue has for the window, the only thing either end knows about its
            // shape before its stream arrives, and the size the Mac builds that stream at. Nothing is
            // aimed at when it is missing: see ``MosaicZoom``.
            sourceSize: model.catalog?.descriptor(for: layout.tiles[index].source)?.pixelSize,
            bounds: canvasSize,
            effectiveZoom: effectiveZoom,
            pan: pan,
            scale: pictureScale
        )
    }

    /// The zoom and the pan that draw an arrangement that has arrived where the one before it was.
    ///
    /// A turn of the phone is a different canvas with nothing on the Mac in between, so the only
    /// thing to interpolate through is a place on the screen: the last frame of the old canvas is at
    /// rest in the middle of a screen that has already turned, and the new canvas is drawn there and
    /// moves to where it belongs. The tile borders go through the same zoom and pan, so they stay on
    /// the windows they describe.
    ///
    /// `nil` when there is nothing to interpolate: **both** pictures have to have been arrangements,
    /// and there has to be a shape on screen to have come from. A tile being opened is a window
    /// arriving, which is ``tileOpeningTransform(_:)``; this is for arrangements replacing each
    /// other.
    func arrangementMorph(
        from previous: PictureIdentity,
        to current: PictureIdentity
    ) -> (zoom: CGFloat, pan: CGSize)? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              // The picture that has arrived is an arrangement, and so is the one it replaced.
              model.isShowingMosaic,
              // A mosaic's name is the only one in the app that starts with this, and it is the same
              // name `PictureIdentity` is built from. The value itself is the client's.
              previous.sourceID?.hasPrefix("mosaic:") == true,
              previous.pixelSize != current.pixelSize
        else { return nil }

        // Both rectangles through the one mapping, at the transform on the picture *now*, so where
        // the old one is means where it actually is, which is where the user had pushed it if they
        // had zoomed the arrangement before turning the phone.
        let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        guard let from = CanvasGeometry.rect(
            normalized: full, bounds: canvasSize, pixelSize: current.pixelSize,
            zoom: effectiveZoom, pan: pan
        ), let to = CanvasGeometry.rect(
            normalized: full, bounds: canvasSize, pixelSize: previous.pixelSize,
            zoom: effectiveZoom, pan: pan
        ) else { return nil }

        guard let target = CanvasGeometry.transform(
            of: from, mappingTo: to, bounds: canvasSize, zoom: effectiveZoom, pan: pan
        ) else { return nil }

        // A drawn scale, turned back into a stored one: ``zoom`` is a multiple of the fit times the
        // base, so stored undivided the base is applied twice and the canvas lands short of the
        // rectangle and grows back. The same division, against the base on screen now, as
        // ``MosaicZoom/opening``.
        let base = pictureBaseScale
        guard base > 0 else { return target }
        return (target.zoom / base, target.pan)
    }

    /// The veil that covers the one frame of a turned arrangement that cannot be continuous.
    ///
    /// Dim rather than opaque: the picture travelling from one shape to the other is the whole of
    /// what a turn looks like, and the dim is only for the instant the windows rearrange themselves
    /// inside that travelling frame, which is a change of content and not of place. The same veil
    /// serves the reorder at a lighter weight. See ``heldTile``.
    var arrangementVeilView: some View {
        Color.black
            .opacity(max(arrangementVeil * 0.55, heldTile == nil ? 0 : 0.4))
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// The zoom and the pan that put the picture back where the arrangement will be.
    ///
    /// The movement a tile is opened with, run the other way, and the two have to agree or the way
    /// into an arrangement and the way out look like different features. It aims at the arrangement
    /// being *asked for* (see ``MacSession/mosaicLayout``, not ``MacSession/pictureMosaicLayout``),
    /// and at rest with the arrangement's fit on screen, which is where ``resetPicture()`` lands the
    /// moment the new picture arrives: the movement ends exactly where the reset lands.
    ///
    /// Nothing to move when the window on screen is not one of the arrangement's tiles. See
    /// ``MacSession/canReturnToMosaic``.
    ///
    /// The window is passed in rather than read from the model, because the ask writes the
    /// arrangement's own id to ``SessionModel/activeSourceID`` and the id would then match no tile.
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
    /// The *ask* rather than the answer wherever the two are the same arrangement, which is what
    /// makes a reorder land under the finger: a reorder produces the same canvas, so the Mac never
    /// sends a new config, and an overlay drawn from the answer would go on naming the windows in
    /// the arrangement the user has just left.
    ///
    /// And the answer wherever they are not, because there the picture really is a different one: a
    /// turn, or a window added, makes a canvas of another shape which the Mac takes a moment to
    /// build. See ``MacSession/pictureMosaicLayout``.
    ///
    /// Nil when no arrangement is being shown *and* none is on its way, which is what keeps the
    /// borders off a picture the user has chosen since leaving the mosaic.
    var shownMosaicLayout: MosaicLayout? {
        // Nothing to draw while a window is being lifted out of an arrangement: these lines are
        // drawn around windows, and the rest of the picture is clipped away, so they would be
        // outlines around nothing.
        guard !isCarryingWindowOut else { return nil }

        if let arrived = model.pictureMosaicLayout {
            // And not before the picture they describe is on screen: a config reaches the model a
            // frame or two before its picture reaches the layer, and borders raised in that gap
            // stand over the window they have just replaced.
            //
            // Asked of the layer rather than of ``pendingArrival``, which the arrival handler sets
            // and is therefore a beat behind.
            guard model.hasPictureOnScreen(of: model.capturePixelSize ?? .zero) else { return nil }
            guard model.isAskingForMosaic, let asked = model.mosaicLayout else { return arrived }
            // **And nothing for a picture the arrangement has moved on from.** From the moment a
            // window is added or taken away until the canvas showing the new arrangement arrives,
            // the Mac is tearing the old one down and building the new one, and the layout it last
            // sent describes a grid that is on its way out: the borders were drawn over the black
            // of the rebuild and then jumped to the grid that replaced it. They arrive with the
            // picture now, which is what the appearance and disappearance of this whole layer is
            // for. A reorder is not this case and is deliberately not hidden: the canvas is the
            // same one, so the Mac sends no config and there would be nothing to wait for.
            //
            // The × controls go with them, which is a second reason to hide: they carry the index
            // of the tile they sit on, and an index from a grid that is leaving names the wrong
            // window in the grid that is arriving. See ``removeMosaicTile(at:)``.
            return sameArrangement(asked, arrived) ? asked : nil
        }

        // Nothing on the way back: borders drawn for an arrangement not yet built sit over a picture
        // that is still one window shrinking into one of them, and shift as the movement carries
        // that window. See ``mosaicReturnTransform()``.
        return nil
    }

    /// Whether two arrangements are the same canvas holding the same windows.
    ///
    /// Deliberately not `==`: a reorder is a *different* layout and still the same picture. What
    /// makes the picture new is a canvas of another shape, or a window that has arrived or gone,
    /// because those are what the Mac has to build a stream again for.
    private func sameArrangement(_ one: MosaicLayout, _ other: MosaicLayout) -> Bool {
        one.canvas == other.canvas
            && Set(one.tiles.map(\.source)) == Set(other.tiles.map(\.source))
    }

    /// The window a movement is carrying out of an arrangement, on screen, or `nil`.
    ///
    /// The only part of the picture to show while one window grows out of it: a tile is a fraction
    /// of a single canvas, so scaling it scales and moves every other window with it. This is the
    /// rectangle the movement is carrying, which is why it grows with it, and the same one the
    /// arriving stream is put on.
    ///
    /// Nil when nothing is being carried out. Going back the window is alone on screen, and clipping
    /// it to itself would be clipping the picture to the whole picture.
    var carriedWindow: CGRect? {
        guard isCarryingWindowOut, let aim = pictureAim else { return nil }

        // Before the switch the window is a piece of the arrangement; after it, it is the picture.
        // The two are the same rectangle at the instant the stream arrives, which is what
        // ``MosaicZoom/placing(pixelSize:anchor:at:bounds:scale:)`` guarantees, but they are measured
        // through different pictures, and reading the arrangement's geometry against the window's
        // stream is a hole of the wrong size while the movement has left to run. Which to read is
        // decided by what the movement has been solved for, not by what the Mac has just configured.
        guard placedPictureID != nil, placedPictureID == model.picture?.sourceID else {
            // The departing picture's own base, not `effectiveZoom`: a movement that finished before
            // the stream arrived leaves `pictureGlide` nil, and `pictureBaseScale` would then read
            // the arriving stream's size for a rectangle measured through the arrangement.
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

    /// Whether the transform on the layer is the one the arriving picture needs.
    ///
    /// Three things have to line up, and each of them can be the late one: the renderer has to have
    /// the frame (``SessionModel/isReadyToPlace(of:)``), the model has to have caught up with the
    /// renderer, and the arrival has to have been applied. The frame lands a few milliseconds before
    /// the config reaches the main actor, and a frame let go in that window is drawn at the picture
    /// it replaced. See ``VideoLayerView/pictureIsPlaced``.
    var pictureIsPlaced: Bool {
        guard model.isReadyToPlace(of: model.capturePixelSize ?? .zero) else { return false }

        // A pending arrival has to have been applied, which is the ordered pair of writes this
        // mechanism exists for: the transform is written for the picture whose frame is about to be
        // handed over, and not for the one it replaces.
        //
        // Guarding on ``pendingArrival`` alone is not enough, because it can settle milliseconds
        // after the tap and long before the movement ends. The release is normally driven by
        // ``VideoLayerView``'s update pass, and ``VideoRenderer`` holds every frame of a config
        // rather than only its first, so the wait is a wait rather than a delay of one frame.
        if let pending = pendingArrival, placedPictureID != pending.current.sourceID {
            return false
        }

        // And not until the movement has finished: the swap is a change of sharpness as well as of
        // geometry, since a tile of the canvas is the Mac's own composite of that window at the size
        // of the tile while the stream being replaced is that window alone at the size of the screen.
        // Mid-movement that reads as a flicker; at rest it reads as the picture settling. A frame
        // held past its budget is dropped by ``VideoRenderer/heldFrameBudget``.
        //
        // A movement that is cancelled rather than landed releases the frame too. See
        // ``cancelPictureGlide()``.
        return pictureGlide == nil
    }

    /// Whether a window is being lifted out of an arrangement, and the rest of it has to be hidden.
    ///
    /// Decided by the promise alone, and it stays decided: every finer condition tried here was a
    /// moment at which the hole closed, and closing it reveals whatever is behind it, which is a
    /// flicker whether that thing belongs there or not. So the hole opens when a movement starts
    /// carrying a window and stays open, over black, until the picture changes to one this movement
    /// was not about. See the arrival in `RemoteScreen`, and ``PictureAim``.
    ///
    /// The direction is the other half: going *back* the window is the whole picture, so a hole
    /// measured around it would black out the arrangement on its way in.
    private var isCarryingWindowOut: Bool {
        pictureAim?.carriesOutOfArrangement == true
    }

    /// Everything of an arrangement except the window being lifted out of it, hidden.
    ///
    /// Drawn rather than masked: masking a video layer makes the compositor render the whole picture
    /// through an alpha channel on every frame, in the middle of the one movement that has to be
    /// smooth. A black shape with the window cut out of it is the same thing seen from the front.
    /// See ``carriedWindow``.
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
    /// The piece of an arrangement that a movement carries, and both directions need it answered:
    /// once for the arrangement being left, where the window is what the movement is carrying out,
    /// and once for the one arriving, where it is the piece that has to stay still. See ``PictureAim``.
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
    /// Checked rather than indexed: the arrangement is the one being *asked for*, and it can be
    /// replaced between a finger picking a tile up and putting one down.
    private func window(at slot: Int?, in layout: MosaicLayout) -> String? {
        guard let slot, layout.tiles.indices.contains(slot) else { return nil }
        return layout.tiles[slot].source.stableID
    }

    var mosaicOverlay: some View {
        // A `ZStack` and not a `Group`, which is the difference between this animating and this
        // appearing: a `Group` has no layout of its own, so a modifier lands on each branch
        // separately and there is nothing for a transition to attach to. The `ZStack` is the
        // container the fade belongs to.
        ZStack {
            if let layout = shownMosaicLayout {
                MosaicOverlay(placed: layout.tiles.enumerated().compactMap { index, tile -> MosaicOverlay.Placed? in
                    guard let rect = mosaicTileRect(index, in: layout) else { return nil }
                    return MosaicOverlay.Placed(
                        // The window, not the slot: a reorder moves windows between places without
                        // moving any place, so keyed by index nothing about the views changes and
                        // there is nothing for the drop to animate. Keyed by the window, the outline
                        // held under the finger travels into the slot it was dropped in.
                        id: tile.source.stableID,
                        rect: rect,
                        title: model.catalog?.descriptor(for: tile.source)?.title
                    )
                }, held: window(at: heldTile, in: layout),
                   heldPoint: heldPoint,
                   target: window(at: targetTile, in: layout))
                // Opacity, and nothing that moves: these borders are drawn on the tiles they
                // outline, and a line travelling into place would spend the whole animation
                // somewhere the tile is not.
                //
                // The way out is quicker than the way in, and the two are different events rather
                // than one reversed. Arriving, the borders are the arrangement being explained and
                // can take ``Motion/settle``. Leaving, a tap has already started carrying one window
                // out, so lines still drawn over the picture are lines on a picture that is no
                // longer there.
                .transition(.asymmetric(
                    insertion: .opacity.animation(Motion.settle),
                    removal: .opacity.animation(Motion.tap)
                ))
            }
        }
        // Keyed on whether the borders are drawn at all rather than on whether the Mac has answered:
        // on the way back from a tile they appear the moment the user asks. See ``shownMosaicLayout``.
        .animation(Motion.settle, value: shownMosaicLayout != nil)
        .ignoresSafeArea()
    }

    /// A small control on each tile that takes that window out of the arrangement.
    ///
    /// Its own layer, above the gesture surface, and it has to be: the borders take no touches, so a
    /// control drawn with them would be swallowed before anything reached it. See ``MosaicOverlay``.
    ///
    /// Hidden while a tile is in the hand, so a row of buttons is not a row of ways out of something
    /// the user is in the middle of doing.
    ///
    /// Drawn only where the tile is big enough to hold one, by the same measure the name is drawn
    /// at: on a small tile the control is most of the corner it sits in, and the tap meant for the
    /// window would find the button instead.
    var mosaicDismissButtons: some View {
        ZStack {
            if let layout = shownMosaicLayout, heldTile == nil {
                ForEach(layout.tiles.indices, id: \.self) { index in
                    if let rect = mosaicTileRect(index, in: layout),
                       rect.width > Self.dismissalMinimumTileWidth {
                        Button {
                            model.removeMosaicTile(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ColorPalette.ink)
                                .frame(
                                    width: Self.dismissalDiameter,
                                    height: Self.dismissalDiameter
                                )
                                .glassSurface(in: Circle())
                        }
                        .contentShape(Circle())
                        .buttonStyle(RailButtonStyle(scale: 0.92))
                        .position(
                            x: rect.maxX - Self.dismissalInset - Self.dismissalDiameter / 2,
                            y: rect.minY + Self.dismissalInset + Self.dismissalDiameter / 2
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    /// How big the control that takes a window out of an arrangement is, and where it sits.
    ///
    /// Smaller than the chrome's own dots, which are 48: a control that size over a tile of a
    /// five-tile arrangement is a quarter of it.
    private static let dismissalDiameter: CGFloat = 28
    private static let dismissalInset: CGFloat = 8
    /// Below this a tile is a label with a window behind it, and a button in its corner is the
    /// corner.
    private static let dismissalMinimumTileWidth: CGFloat = 140

    /// How the picture is scaled on its way to the screen, over and above the user's zoom.
    ///
    /// A value rather than a number, because the answer depends on which picture is being asked
    /// about: in Fill a canvas and one of its windows are scaled by different amounts, and the
    /// movement between them is measured against that difference. See ``PictureScale`` and
    /// ``MacCastKit/MosaicZoom``.
    var pictureScale: PictureScale {
        PictureScale(
            scalesToFill: scalesToFill,
            // Portrait has no margin, and the asymmetry is the chrome's: the pill and the dock sit
            // above and below the middle of the screen, and the canvas of an arrangement is a band
            // across that middle. See ``ChromeMetrics/pictureInset``.
            inset: deviceIsLandscape ? ChromeMetrics.pictureInset : 0
        )
    }

    /// What the picture is drawn at, and, because every touch is mapped back through it, what a
    /// touch means. One property rather than two, so a click can never be resolved against a scale
    /// the picture is not actually drawn at.
    ///
    /// In Fill the user's zoom rides *on top of* the fill scale rather than competing with it:
    /// multiplying leaves the resting state exactly as it was, at `zoom == 1` the base scale, and
    /// gives every step of the pinch somewhere to go. With `max(zoom, fill)` a pinch had no effect
    /// at all until the picture had been magnified past the fill by some other means.
    var effectiveZoom: CGFloat {
        pictureBaseScale * zoom
    }

    /// What the picture **on screen** is multiplied by, over and above the user's zoom.
    ///
    /// The margin is not a box the drawing is moved into, it is the same rectangle drawn 85% as
    /// large about the same centre. See ``pictureScale`` for the picture-dependent half.
    var pictureBaseScale: CGFloat {
        // Use the locked size while animating: the pixel size ``zoom`` was calibrated against is
        // ``lockedPixelSize``, not whatever the model currently reports. See ``lockedPixelSize``.
        //
        // And keep using it until the arrival has been solved for, which is not the same moment.
        // `capturePixelSize` moves the instant a config arrives and `lockedPixelSize` is written when
        // the arrival is solved, so between those two the stream has changed and the picture on
        // screen has not. A glide is nil across that whole gap, so gating on the glide alone hands
        // the transform the *arriving* picture's base while the zoom is still the departing one's,
        // which draws the picture at twice the size it belongs at for a frame.
        let unsolved = placedPictureID != model.picture?.sourceID
        let size = (pictureGlide != nil || unsolved)
            ? lockedPixelSize
            : (model.capturePixelSize ?? .zero)
        return pictureScale.base(pixelSize: size, in: canvasSize)
    }

    /// Whether the new picture is already drawn where a reset would draw it.
    ///
    /// Asked of the rectangle rather than of the zoom: a zoom is a multiple of the picture's own fit
    /// and a reset is the number 1, so "the zoom is not 1" and "the picture is not where it belongs"
    /// are different questions, and only the second is about anything the user can see. A reorder, a
    /// source picked out of a panel, a return to an arrangement: all arrive already at rest, and the
    /// reset is then a re-expression of the same rectangle rather than a movement.
    ///
    /// Asked the moment a new picture arrives, so everything it reads is the new picture's. It is
    /// deliberately *not* the test for a window a movement was aimed at, because the number cannot
    /// answer that one. See ``RemoteScreen/openingTarget``.
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
        // even-rounding of a tile's surface, and a correction for that would be a movement the user
        // watches for half a second to travel nowhere.
        return abs(now.midX - rest.midX) < 1
            && abs(now.midY - rest.midY) < 1
            && abs(now.width - rest.width) < 1
            && abs(now.height - rest.height) < 1
    }

    /// Puts the picture back where a phone that has just opened a source expects it: at the
    /// default zoom, and centred.
    ///
    /// One is the app's default, and not the same thing as "not scaled": `effectiveZoom` is the
    /// picture's own base scale times this number (see ``pictureScale``), so at 1 the picture is
    /// exactly as the fit draws it. The zoom is a multiple *of* the fit, which is why the reset is
    /// this number and not a smaller one.
    ///
    /// The percentage chip in the status pill resets through here as well, and the two have to be
    /// the same number: a reset that landed elsewhere would leave the chip reading 100% over a
    /// scaled picture.
    ///
    /// Not animated, and it cannot be: the zoom reaches the picture as a layer transform with Core
    /// Animation's implicit animations switched off (see ``VideoLayerView/updateUIView(_:context:)``),
    /// and the frames behind it are being replaced at the same moment.
    func resetPicture() {
        zoom = 1
        pan = .zero
        // This is where an arriving picture becomes the picture: everything measured against the
        // picture's own size moves with it, and both of the ways a picture arrives at rest come
        // through here. See ``pictureBaseScale``.
        lockedPixelSize = model.capturePixelSize ?? .zero
        placedPictureID = model.picture?.sourceID
    }

}
