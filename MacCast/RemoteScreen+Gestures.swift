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
                if interactionMode.isTrackpad {
                    model.send(.mouseDown(button: .left))
                    return
                }
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
                if interactionMode.isTrackpad {
                    model.send(.mouseUp(button: .left))
                    releaseMoveIfArmed()
                    return
                }
                guard let normalized = normalized(point) else { return }
                remoteCursor = normalized
                model.send(.mouseMove(to: normalized))
                model.send(.mouseUp(button: .left))
                releaseMoveIfArmed()
            },
            onSecondaryClick: { point in
                if interactionMode.isTrackpad {
                    model.send(.mouseDown(button: .right))
                    model.send(.mouseUp(button: .right))
                    return
                }
                guard let normalized = normalized(point) else { return }
                remoteCursor = normalized
                model.send(.mouseMove(to: normalized))
                model.send(.mouseDown(button: .right))
                model.send(.mouseUp(button: .right))
            },
            onScroll: { translation in
                // Doubled into pixels, which is the unit the host's wheel event is built in
                // (`units: .pixel`). A point of finger travel moving one pixel would make
                // scrolling a page take several swipes.
                model.send(.scroll(dx: Double(translation.width) * 2, dy: Double(translation.height) * 2))
            },
            onZoom: { factor, _ in
                zoom = min(max(zoom * factor, minimumZoom), maximumZoom)
                // Zooming no longer decides what the fingers mean. It used to flip two-finger
                // drags between scrolling the Mac and moving the picture, so the same gesture
                // did different things depending on what the user had done minutes earlier.
                // Only the mode switch moves that, and only the user moves the mode switch.
                //
                // The pan is re-clamped rather than dropped past some threshold. Zooming out
                // shrinks what there is to pan over, and letting the offset stand until the
                // picture no longer overflows and then zeroing it snapped the view sideways in
                // one frame. Clamped every step, the picture slides back as the room for it goes.
                pan = clampedPan(pan)
            },
            onPanCanvas: { translation in
                if interactionMode.isTrackpad {
                    // Relative movement: delta normalised by canvas size, scaled 2× to feel like
                    // a physical trackpad (finger travel ≈ pointer travel at arm's length).
                    guard canvasSize.width > 0, canvasSize.height > 0 else { return }
                    let sensitivity: CGFloat = 2.0
                    let dx = (translation.width / canvasSize.width) * sensitivity
                    let dy = (translation.height / canvasSize.height) * sensitivity
                    let nx = min(max(Double(CGFloat(remoteCursor.x) + dx), 0), 1)
                    let ny = min(max(Double(CGFloat(remoteCursor.y) + dy), 0), 1)
                    remoteCursor = NormalizedPoint(x: nx, y: ny)
                    model.send(.mouseMove(to: remoteCursor))
                } else {
                    pan = clampedPan(
                        CGSize(width: pan.width + translation.width,
                               height: pan.height + translation.height)
                    )
                }
            },
            onSizeChange: { canvasSize = $0 },
            interactionMode: interactionMode,
            // The drawn scale, not the user's zoom alone: `scalesToFill` enlarges the picture
            // without `zoom` moving, and a cropped picture is exactly the one with somewhere to
            // pan to. A hundredth of slack, so a floating-point return to 1.0 still counts as
            // fitted and gives the two-finger drag back to the Mac.
            isZoomed: effectiveZoom > 1.01,
            blockedRegions: blockedRegions,
            isPanelOpen: openPanel != nil,
            onDismissPanel: { withAnimation(Motion.settle) { openPanel = nil } },
            isStatusBarExpanded: statusBarExpanded,
            onCollapseStatusBar: { collapseStatusBar() },
            isKeyboardOpen: model.showKeyboard,
            onDismissKeyboard: { model.showKeyboard = false }
        )
        .ignoresSafeArea()
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
    /// Drag & zoom makes this reachable: without a limit the picture can be flung off the screen
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
            leading = max(leading, rect.minX)
            trailing = max(trailing, canvasSize.width - rect.maxX)
            top = max(top, rect.minY)
            bottom = max(bottom, canvasSize.height - rect.maxY)
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
            return slack > 0 ? slack + margin : 0
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
