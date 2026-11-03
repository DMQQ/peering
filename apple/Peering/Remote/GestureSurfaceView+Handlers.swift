import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension GestureSurfaceView {
    @objc func handleOneFingerPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)

        let isEnding = gesture.state == .ended
            || gesture.state == .cancelled
            || gesture.state == .failed
        if gesture.state == .began {
            ignoresCurrentGesture = CanvasGeometry.isBlocked(point, regions: blockedRegions)
        }
        defer { if isEnding { ignoresCurrentGesture = false } }
        guard !ignoresCurrentGesture else { return }

        // The end of the gesture is not skipped along with its movement. A drag that began
        // before the pinch did has already put the Mac's button down, and a release that never
        // follows is a button held down on someone else's Mac until they notice.
        if isPinching {
            // The movement is dropped rather than saved up. A translation accumulated during the
            // pinch would land in one jump the moment the pinch ended and this drag resumed.
            gesture.setTranslation(.zero, in: self)
            guard isEnding, !interactionMode.oneFingerDragPansCanvas else { return }
            handlers?.onTouchUp(point)
            return
        }

        if interactionMode.oneFingerDragPansCanvas {
            let moved = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            guard moved != .zero else { return }
            handlers?.onPanCanvas(CGSize(width: moved.x, height: moved.y))
            return
        }

        switch gesture.state {
        case .began:
            // The press is posted *after* the move, and the ordering is load-bearing on the
            // host: `mouseDown` is injected at the position of the last move it saw, so a
            // click that overtook its own move would land wherever the cursor happened to be.
            handlers?.onTouchDown(point)
        case .changed:
            handlers?.onTouchMove(point)
        case .ended, .cancelled, .failed:
            handlers?.onTouchUp(point)
        default:
            break
        }
    }

    /// `.failed` is deliberately not a drop. A press that failed is one that never lifted anything
    /// the finger moved, or came up too soon, and telling the screen that a tile was let go when
    /// none was picked up would be a message about a gesture that did not happen.
    @objc func handleMosaicLift(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            handlers?.onMosaicLift(point)
        case .changed:
            handlers?.onMosaicDrag(point)
        case .ended, .cancelled:
            handlers?.onMosaicDrop()
        default:
            break
        }
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        // **A tap on the picture closes an open panel, and goes no further.** The panel covers part
        // of the picture, so a tap beside it is a tap on something only half visible; it is read
        // as "put this away". The keyboard is the exception and stays open: tapping a text field
        // on the Mac is how typing starts, and a first tap that only put the keyboard away was the
        // reason this used to be off for everything. The expanded pill closes too, but that tap
        // still reaches the Mac.
        guard !CanvasGeometry.isBlocked(point, regions: blockedRegions) else { return }

        if handlers?.onPictureTap() == true { return }

        // **A mosaic comes before the mode guard, and that is not an oversight.** Selecting a
        // tile sends no input: it asks the Mac for that one source, which is the same kind of
        // command as opening a panel or choosing from the sources list, and both of those work
        // in observe mode. What observe mode refuses is *touching* the Mac, and this is the app
        // deciding what to show rather than a finger landing on a window.
        if isMosaicShowing {
            handlers?.onMosaicTap(point)
            return
        }

        guard interactionMode.tapsReachTheMac else { return }
        handlers?.onTouchDown(point)
        handlers?.onTouchUp(point)
    }

    @objc func handleSecondaryPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        handlers?.onSecondaryClick(gesture.location(in: self))
    }

    @objc func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            let start = gesture.location(in: self)
            ignoresTwoFingerGesture = CanvasGeometry.isBlocked(start, regions: blockedRegions)
            suppressTwoFingerPanUntilEnd = false
            twoFingerDragPansCanvas = interactionMode.twoFingerDragPansCanvas(isZoomed: isZoomed)
        }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            ignoresTwoFingerGesture = false
        }
        guard !ignoresTwoFingerGesture else { return }

        let isEnding = gesture.state == .ended
            || gesture.state == .cancelled
            || gesture.state == .failed

        // During a pinch the simultaneous pan recognizer is the single owner of shared finger
        // movement. The pinch recognizer below applies scale only; letting both callbacks pan
        // would apply the same centroid delta twice (the visible rightward snap).
        if !suppressTwoFingerPanUntilEnd,
           isPinching || pinch.state == .began || pinch.state == .changed {
            let movement = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            if let movement = CanvasGestureRouting.pinchPanTranslation(
                translation: movement,
                suppressingAfterPinch: false
            ) {
                handlers?.onPanCanvas(CGSize(width: movement.x, height: movement.y))
            }
            return
        }

        if !CanvasGestureRouting.shouldDeliverTwoFingerPan(
            whilePinching: isPinching,
            suppressingAfterPinch: suppressTwoFingerPanUntilEnd
        ) {
            gesture.setTranslation(.zero, in: self)
            if isEnding { suppressTwoFingerPanUntilEnd = false }
            return
        }

        let decision = CanvasGestureRouting.twoFingerPan(
            translation: gesture.translation(in: self),
            whilePinching: isPinching
        )
        if decision.resetsRecognizerTranslation {
            gesture.setTranslation(.zero, in: self)
        }
        guard let point = decision.translation else { return }
        let translation = CGSize(width: point.x, height: point.y)
        if twoFingerDragPansCanvas {
            handlers?.onPanCanvas(translation)
        } else {
            handlers?.onScroll(translation)
        }
    }

    @objc func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard interactionMode.tapsReachTheMac else { return }
        let point = gesture.location(in: self)
        guard !CanvasGeometry.isBlocked(point, regions: blockedRegions) else { return }
        handlers?.onSecondaryClick(point)
    }

    @objc func handleMultiFingerSwipe(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // Toggling `isEnabled` cancels a recogniser, which ends the Mac's held button or the
            // scroll the first fingers started; touches already down are not handed back to it.
            for recognizer in [oneFingerPan, twoFingerPan, pinch, secondaryPress] {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        case .ended:
            let travel = gesture.translation(in: self)
            guard let swipe = TrackpadSwipe(dx: travel.x, dy: travel.y) else { return }
            handlers?.onMultiFingerSwipe(swipe)
        default:
            break
        }
    }

    @objc func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        guard interactionMode.tapsReachTheMac, !isMosaicShowing else { return }
        let point = gesture.location(in: self)
        guard !CanvasGeometry.isBlocked(point, regions: blockedRegions) else { return }
        handlers?.onHover(point)
    }

    @objc func handlePointerScroll(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            pointerScrollPansCanvas = interactionMode.twoFingerDragPansCanvas(isZoomed: isZoomed)
        }
        let moved = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard moved != .zero else { return }
        let translation = CGSize(width: moved.x, height: moved.y)
        if pointerScrollPansCanvas {
            handlers?.onPanCanvas(translation)
        } else if interactionMode.tapsReachTheMac, !isMosaicShowing {
            handlers?.onScroll(translation)
        }
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard interactionMode.tapsReachTheMac, !isMosaicShowing,
              !CanvasGeometry.isBlocked(request.location, regions: blockedRegions)
        else { return nil }
        return defaultRegion
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        .hidden()
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        // **A pinch resizes the picture, in every mode.**

        // Set before the chrome check below, so a pinch that begins over a panel still owns its
        // two fingers and does not scroll the Mac behind the panel.
        switch gesture.state {
        case .began:
            pinchIgnoresChrome = CanvasGeometry.isBlocked(
                gesture.location(in: self),
                regions: blockedRegions
            )
            isPinching = true
        case .changed:
            isPinching = true
        case .ended, .cancelled, .failed:
            isPinching = false
            suppressTwoFingerPanUntilEnd = true
        default:
            break
        }
        guard !pinchIgnoresChrome else { return }

        let point = gesture.location(in: self)

        let phase: CanvasGestureRouting.PinchPhase = switch gesture.state {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        case .failed: .failed
        default: .changed
        }
        let scale = gesture.scale
        gesture.scale = 1
        guard let appliedScale = CanvasGestureRouting.pinchScale(for: phase, scale: scale) else { return }
        handlers?.onZoom(appliedScale, point)
    }
}
