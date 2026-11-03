import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

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
                // at the one scale this screen moves content by, see `ScrollNotch`. Doubling a
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
                let result = CanvasViewport.pinched(
                    zoom: zoom, pan: pan, factor: factor, centre: centre, canvas: canvasSize
                )
                pan = result.pan
                zoom = result.zoom
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
                // An open panel no longer swallows the tap: the picture stays usable under it, and the panel is closed by its handle.
                return false
            },
            onMultiFingerSwipe: { swipe in
                for command in swipe.commands(spaces: model.catalog?.spaceInfo) { model.send(command) }
            }
        )
        .ignoresSafeArea()
        .transaction { $0.disablesAnimations = true }
    }

    func mosaicSlot(at point: CGPoint) -> Int? {
        guard let layout = shownMosaicLayout, let normalized = normalized(point) else {
            return nil
        }
        return MosaicGrid.tileIndex(at: normalized, in: layout)
    }

    /// **One ask at the end rather than a rearrangement per slot.** Moving the tile under the
    /// finger would re-ask the Mac on every seam it crossed, six windows torn down and rebuilt,
    /// or re-composited, several times in a second of dragging. What the user is arranging is the
    /// order, and the order is only settled when they let go.
    func dropHeldTile() {
        let from = heldTile
        let to = targetTile

        // **The new arrangement in the same breath as letting go, and that is the whole of the
        // feedback.** The outline being carried is drawn where the finger is; the arrangement it
        // is dropped into is the client's own, known the instant the user lets go, and drawing it
        // at once means the outline travels from the thumb into the slot it was put in and every
        // window it displaced travels into its own. Asked of the Mac and *then* drawn, which is
        // what this did, because the borders were drawn from the Mac's answer, the outline simply
        // vanished and the arrangement under it reordered itself a moment later, with the names in
        // the old places the whole time. See ``shownMosaicLayout``.
        withAnimation(Motion.settle) {
            heldTile = nil
            targetTile = nil
            heldPoint = nil
            if let from, let to, from != to {
                model.moveMosaicTile(from: from, to: to)
            }
        }
    }

    /// **The ask goes out at the tap, and the hero transition is only ever how it is shown.**
    /// What is being shown and how it is shown are two decisions: the ask is not deferred to the
    /// end of a movement, so an interrupted transition is never a tap that did nothing. It also
    /// costs the Mac the length of the animation before it starts building the stream, which is
    /// time the two can spend at once.
    func openMosaicTile(_ index: Int, in layout: MosaicLayout) {
        guard layout.tiles.indices.contains(index) else { return }

        // **A tile whose window is not in the catalogue is a card, and a card is not a window.**
        // The Mac draws one for every source it can no longer capture, a window closed while the
        // arrangement was up is the ordinary way that happens, and there is nothing behind it to
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

    /// Three seconds. A second and a fifth covered the Mac building a stream, but a window on
    /// another desktop waits for the Mac to switch there first, and a tile that misses this is
    /// dead until the arrangement is rebuilt.
    func watchTileOpening(_ sourceID: String) {
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

    ///
    /// The clamp used to stop exactly where the picture's edge met the screen's, which sounds
    /// right and is not: at that limit a corner of the desktop sits in the screen's own corner,
    /// underneath the rail, and in landscape underneath the notch as well. The corner the user is
    /// dragging towards to *look at* is the one thing they cannot see.
    /// Measured rather than calculated, and that is the whole point. Both earlier attempts worked
    /// the number out from the rail's nominal width, once as the width itself, once as the width
    /// plus its edge inset, and both were short by the same thing neither knew about: the rails
    /// sit *inside the safe area*, which in landscape is a wide inset on the side the sensor
    /// housing is on. On this phone the rail's inner edge is 121 points from the screen's edge,
    /// not the 62 the metrics describe, so a corner dragged towards it came to rest underneath it
    /// either way. Reading the frames the chrome reports cannot be wrong about this.
    /// Only ever added to an axis that already overflows: with the picture fitted there is nothing
    /// to reveal, and a margin there would let a drag pull the picture away from its own edges and
    /// show the backdrop.
    var panMargin: CGSize {
        CanvasViewport.chromeMargin(
            chromeFrames.filter { $0.key != .panel }.map(\.value),
            canvas: canvasSize,
            gap: ChromeMetrics.edgeInset * 2
        )
    }

    var panLimit: CGSize {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        return CanvasViewport.panLimit(
            canvas: canvasSize,
            picture: CanvasGeometry.videoRect(bounds: canvasSize, pixelSize: model.capturePixelSize).size,
            effectiveZoom: effectiveZoom,
            margin: panMargin
        )
    }

    func clampedPan(_ proposed: CGSize) -> CGSize {
        CanvasViewport.clamped(proposed, to: panLimit)
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
