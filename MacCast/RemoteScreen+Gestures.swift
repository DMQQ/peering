import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

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
                guard let layout = model.mosaicLayout,
                      let normalized = normalized(point),
                      let index = MosaicGrid.tileIndex(at: normalized, in: layout)
                else { return }
                openMosaicTile(index)
            },
            isPanelOpen: openPanel != nil,
            onDismissPanel: { withAnimation(Motion.settle) { openPanel = nil } },
            isStatusBarExpanded: statusBarExpanded,
            onCollapseStatusBar: { collapseStatusBar() },
            isKeyboardOpen: model.showKeyboard,
            onDismissKeyboard: { model.showKeyboard = false }
        )
        .ignoresSafeArea()
    }

    /// Opens one tile of the arrangement: the picture becomes that window, and the outline the
    /// tile was drawn with grows to the edges of the screen on its way out.
    ///
    /// Two beats rather than one, and the second is what makes it read as an opening rather than
    /// as a flourish. The outline starts at the tile's own rect — so what moves is the tile's own
    /// edge, travelling — and only then travels outward; set to the full size in the same update
    /// that created it, there is no starting value for SwiftUI to interpolate from and the shape
    /// simply appears at full size. It fades once it has arrived, by which time the Mac has
    /// switched capture and the window it outlines is the one on screen.
    func openMosaicTile(_ index: Int) {
        openingTileTask?.cancel()

        guard let start = mosaicTileRect(index) else {
            // No rectangle to travel from — a tap that resolved to a tile the screen cannot
            // place. The switch still happens; only the drawing is skipped.
            model.focusMosaicTile(index)
            return
        }

        openingTile = start
        model.focusMosaicTile(index)

        openingTileTask = Task { @MainActor in
            // One frame at the tile's own size before anything moves. A shorter sleep than this
            // is the same frame, and a longer one is a pause the eye reads as a delay.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.settle) {
                openingTile = CGRect(origin: .zero, size: canvasSize)
            }

            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.tap) { openingTile = nil }
        }
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
