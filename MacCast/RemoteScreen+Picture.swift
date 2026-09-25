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
            // Only for the trace: the layer sizes itself to the screen and knows nothing about the
            // picture's own dimensions. See ``VideoLayerView/pictureSize``.
            pictureSize: model.capturePixelSize ?? .zero,
            zoom: effectiveZoom,
            pan: pan,
            // While a transition is in flight, the frozen layer carries its own, independently
            // animated placement; at rest the two are the same number, which is what lets the
            // cross-fade land without a jump either way it is asked for. See ``PictureTransition``.
            stillZoom: transition?.zoom ?? effectiveZoom,
            stillPan: transition?.pan ?? pan,
            showsStill: transition != nil,
            // Frozen by ``RemoteScreen/beginHeroTransition(to:target:carry:)`` at the tap, and one
            // frame old at worst beyond that: see ``VideoRenderer/snapshot()``.
            stillPicture: model.renderer.stillPicture
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
    /// Drawn only while the mosaic is the picture, at rest, with no transition in flight: a border
    /// around a single window would describe a grid that is no longer on screen, and one drawn over
    /// a hero transition's frozen snapshot would be describing a picture that is mid-journey to
    /// somewhere else.
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
    /// somewhere it is never going to be. Both rectangles mapped between are the window's and have
    /// the same shape, so the movement is a straight scale about a point. See
    /// ``CanvasGeometry/videoRect(bounds:pixelSize:)`` and ``mosaicTileRect(_:in:)``.
    ///
    /// With no size in the catalogue for that source there is no window to aim at, and the caller
    /// falls back to switching without a transition.
    ///
    /// The result is a *stored* zoom — a multiple of the current picture's own base — because
    /// ``beginHeroTransition(to:target:carry:)`` converts it to a drawn scale itself, against the
    /// base the picture is drawn at right now. See ``effectiveZoom``.
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

    /// The zoom and the pan that put the picture back where the arrangement will be.
    ///
    /// The transition a tile is opened with, run the other way, and the two have to agree or the way
    /// into an arrangement and the way out look like different features. It aims at the arrangement
    /// being *asked for* (see ``MacSession/mosaicLayout``, not ``MacSession/pictureMosaicLayout``).
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
    /// Nil while any transition is in flight — the live layer is not what is on screen, so there is
    /// nothing here to draw a border on top of yet — and nil when no arrangement is being shown at
    /// all, which is what keeps the borders off a picture the user has chosen since leaving the
    /// mosaic.
    var shownMosaicLayout: MosaicLayout? {
        guard transition == nil else { return nil }
        guard let arrived = model.pictureMosaicLayout else { return nil }
        guard model.isAskingForMosaic, let asked = model.askedMosaicLayout else { return arrived }
        return sameArrangement(asked, arrived) ? asked : arrived
    }

    /// Whether the way back into an arrangement should be offered right now.
    ///
    /// ``MacSession/canReturnToMosaic`` alone is not enough: it flips true the moment the Mac's
    /// config for the opened window arrives, which is well before that window's first frame does,
    /// let alone before a hero transition has revealed it — the control would otherwise be pressable
    /// while the screen is still a frozen, magnified crop of the *mosaic*. Tapped there,
    /// ``animateBackToMosaic()`` would freeze that crop, not the window, and animate the whole
    /// arrangement shrinking into one tile instead of a window shrinking into it. Gating on
    /// ``transition`` being `nil` is what keeps the two questions — "is an arrangement there to go
    /// back to" and "has this screen actually finished arriving anywhere" — from being answered
    /// separately.
    var canReturnToMosaic: Bool {
        model.canReturnToMosaic && transition == nil
    }

    /// Whether two arrangements are the same canvas holding the same windows.
    ///
    /// Deliberately not `==`: a reorder is a *different* layout and still the same picture. What
    /// makes the picture new is a canvas of another shape, or a window that has arrived or gone,
    /// because those are what the Mac has to build a stream again for.
    func sameArrangement(_ one: MosaicLayout, _ other: MosaicLayout) -> Bool {
        one.canvas == other.canvas
            && Set(one.tiles.map(\.source)) == Set(other.tiles.map(\.source))
    }

    /// The window a hero transition is carrying out of an arrangement, on screen, or `nil`.
    ///
    /// The only part of the frozen snapshot to show while one window grows out of it: a tile is a
    /// fraction of a single canvas, so scaling the snapshot scales and moves every other window with
    /// it. This is the rectangle the transition is carrying, which is why it grows with it.
    ///
    /// Nil for anything but the outward direction of a directional transition. Going back the frozen
    /// snapshot is the window alone, and clipping it to itself would be clipping the picture to the
    /// whole picture; a plain cross-fade has no window to carry at all.
    var carriedWindow: CGRect? {
        guard let transition, let carry = transition.carry, carry.carriesOutOfArrangement else {
            return nil
        }
        return CanvasGeometry.rect(
            normalized: carry.frozenAnchor,
            bounds: canvasSize,
            pixelSize: carry.frozenSize,
            zoom: transition.zoom,
            pan: transition.pan
        )
    }

    /// Everything of an arrangement except the window being lifted out of it, hidden.
    ///
    /// Drawn rather than masked: masking a video layer makes the compositor render the whole picture
    /// through an alpha channel on every frame, in the middle of the one animation that has to be
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
    /// The piece of an arrangement a hero transition carries, and both directions need it answered:
    /// once for the arrangement being left, where the window is what the transition is carrying out,
    /// and once for the one arriving, where it is the piece that has to stay still. See
    /// ``HeroCarry``.
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
                // can take ``Motion/settle``. Leaving, a tap has already started a hero transition
                // out, so lines still drawn over the picture are lines on a picture that is no
                // longer there.
                .transition(.asymmetric(
                    insertion: .opacity.animation(Motion.settle),
                    removal: .opacity.animation(Motion.tap)
                ))
            }
        }
        // Keyed on whether the borders are drawn at all, which follows ``shownMosaicLayout`` and
        // therefore ``transition`` directly: the picture is never mid-write when this changes, so
        // there is nothing left to hold the borders back from.
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
    /// about: in Fill a canvas and one of its windows are scaled by different amounts, and a hero
    /// transition is measured against that difference. See ``PictureScale`` and
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
    /// Always read from the picture the model describes right now. There is no locked or borrowed
    /// size to fall back on any more: ``zoom`` is reset to 1 the instant a picture changes (see
    /// ``reactToPictureChange(from:to:)``), in the same update that starts hiding the live layer
    /// behind its frozen snapshot, so by the time anyone can see this number again it is already
    /// being asked about the picture it belongs to.
    var pictureBaseScale: CGFloat {
        pictureScale.base(pixelSize: model.capturePixelSize ?? .zero, in: canvasSize)
    }

    /// Puts the picture back at the default zoom, centred.
    ///
    /// One is the app's default, and not the same thing as "not scaled": `effectiveZoom` is the
    /// picture's own base scale times this number (see ``pictureScale``), so at 1 the picture is
    /// exactly as the fit draws it.
    ///
    /// The percentage chip in the status pill resets through here, and the two have to be the same
    /// number: a reset that landed elsewhere would leave the chip reading 100% over a scaled
    /// picture.
    func resetPicture() {
        zoom = 1
        pan = .zero
    }

}
