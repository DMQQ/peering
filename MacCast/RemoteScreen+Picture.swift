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
    func mosaicTileRect(_ index: Int) -> CGRect? {
        guard let layout = model.mosaicLayout, layout.tiles.indices.contains(index) else {
            return nil
        }
        return CanvasGeometry.rect(
            normalized: layout.tiles[index].rect,
            bounds: canvasSize,
            pixelSize: model.capturePixelSize,
            zoom: effectiveZoom,
            pan: pan
        )
    }

    /// A tile being opened: everything that is not it fades out as it grows to fill the screen.
    ///
    /// **A hole opening, not a border travelling.** What the tap means is "this one, not the
    /// others", so what moves is the *rest of the picture* going away — the border that was drawn
    /// around the tile was the tile's own edge moving, which says where the tile was rather than
    /// what it is becoming.
    ///
    /// Drawn as one even-odd path — the whole screen with the tile knocked out of it — filled with
    /// black, so the hole can grow by animating a single rectangle. At the end the hole is the
    /// screen and the black is nothing, which is the window that has just arrived.
    ///
    /// **Outside the `isShowingMosaic` branch on purpose**, because by the time this is drawn the
    /// arrangement has already been left — that is what choosing a tile means — so a drawing
    /// inside that branch would be removed in the same update that started it.
    @ViewBuilder
    var openingTileScrim: some View {
        if let opening = openingTile, opening.width > 0, opening.height > 0 {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: canvasSize))
                path.addRoundedRect(in: opening, cornerSize: CGSize(width: 6, height: 6))
            }
            .fill(Color.black, style: FillStyle(eoFill: true))
            .opacity(openingTileVeil)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    var mosaicOverlay: some View {
        // **A `ZStack` and not a `Group`**, which is the difference between this animating and
        // this appearing. A `Group` has no layout of its own — every modifier on one lands on
        // each branch separately — so there is nothing for a transition to be attached to and
        // the two states just swap. The `ZStack` is the container the fade belongs to.
        ZStack {
            if let layout = model.mosaicLayout, model.isShowingMosaic {
                MosaicOverlay(placed: layout.tiles.enumerated().compactMap { index, tile in
                    guard let rect = CanvasGeometry.rect(
                        normalized: tile.rect,
                        bounds: canvasSize,
                        pixelSize: model.capturePixelSize,
                        zoom: effectiveZoom,
                        pan: pan
                    ) else { return nil }
                    return MosaicOverlay.Placed(
                        id: index,
                        rect: rect,
                        title: model.catalog?.descriptor(for: tile.source)?.title
                    )
                })
                // **Opacity, and nothing that moves.** Every other entrance in this app slides or
                // scales, and none of them can here: these borders are drawn on the tiles they
                // outline, and a line travelling into place would spend the whole animation
                // somewhere the tile is not. What fades is the app's account of where the windows
                // are; the picture underneath never moved.
                .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: model.isShowingMosaic)
        .ignoresSafeArea()
    }

    /// How much the picture has to grow to reach the screen's edges.
    ///
    /// A captured window is usually a different shape from a phone held sideways, so the fitted
    /// picture is a band with bars either side of it. This is the scale at which the *shorter*
    /// axis of the picture matches the screen — which fills it, and crops the other axis, which
    /// is what the user then pans around while zoomed.
    var fillZoom: CGFloat {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        let rect = CanvasGeometry.videoRect(bounds: canvasSize, pixelSize: model.capturePixelSize)
        guard rect.width > 0, rect.height > 0 else { return 1 }
        return max(canvasSize.width / rect.width, canvasSize.height / rect.height)
    }

    /// What the picture is drawn at, and — because every touch is mapped back through it — what
    /// a touch means. One property rather than two, so a click can never be resolved against a
    /// scale the picture is not actually drawn at.
    ///
    /// In Fill the user's zoom rides *on top of* the fill scale rather than competing with it,
    /// and that is the whole difference between a pinch that works and one that looks broken.
    ///
    /// It was `max(zoom, fillZoom)`, which discarded the user's zoom for as long as it was the
    /// smaller of the two — and `fillZoom` is 1.4× in landscape and over 3× in portrait for a
    /// full-size desktop, so a pinch had *no effect whatsoever* until the picture had already
    /// been magnified past the fill by some other means. There is no other means: the pinch was
    /// the door, and this was the lock on it.
    ///
    /// Multiplying leaves the resting state exactly as it was — at `zoom == 1` this is `fillZoom`
    /// — and gives every step of the pinch somewhere to go from there.
    var effectiveZoom: CGFloat {
        scalesToFill ? fillZoom * zoom : zoom
    }

    /// Puts the picture back where a phone that has just opened a source expects it: at the
    /// default zoom, and centred.
    ///
    /// **One is the app's default, and it is not the same thing as "not scaled".** `effectiveZoom`
    /// is `scalesToFill ? fillZoom * zoom : zoom`, so at 1 the picture is exactly as the fit draws
    /// it: the whole screen in Fit, the screen's edges in Fill. The zoom is a multiple *of* the
    /// fit, which is why the reset is this number and not a smaller one.
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
