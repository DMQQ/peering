import PeeringKit
import SwiftUI
import UIKit

/// What the pad reports. Moves are fractions of the pad's own size since the last report; `onTouch` is where the finger is, in points, or nil once it lifts.
struct RemoteDockPadActions {
    var onMove: (CGSize) -> Void
    var onTap: () -> Void
    var onTwoFingerTap: () -> Void
    var onScroll: (CGSize) -> Void
    var onDragBegin: () -> Void
    var onDragEnd: () -> Void
    var onTouch: (CGPoint?) -> Void
    /// A tap, where it landed: the ripple answers taps only, not the start of a drag.
    var onPress: (CGPoint) -> Void
    var onSwipe: (TrackpadSwipe) -> Void
}

/// A trackpad surface: one finger moves, a tap clicks, two fingers scroll or right-click, a hold then a move drags.
struct RemoteDockPad: UIViewRepresentable {
    let actions: RemoteDockPadActions

    func makeUIView(context: Context) -> UIView {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = TrackpadEngine.dragHoldSeconds
        hold.allowableMovement = TrackpadEngine.tapMaxMovement
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        let twoTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.twoTapped))
        twoTap.numberOfTouchesRequired = 2
        let swipe = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.swiped(_:)))
        swipe.minimumNumberOfTouches = 3
        swipe.maximumNumberOfTouches = 4
        pan.require(toFail: hold)
        tap.require(toFail: twoTap)
        for recognizer in [hold, pan, scroll, swipe, tap, twoTap] { view.addGestureRecognizer(recognizer) }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.actions = actions
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    final class Coordinator: NSObject {
        var actions: RemoteDockPadActions
        private var lastHoldPoint = CGPoint.zero
        init(actions: RemoteDockPadActions) {
            self.actions = actions
            super.init()
        }

        /// The finger's movement as the person meant it: the screen stays upright when the phone is turned upside down, so without this every gesture ran backwards.
        private func intended(_ delta: CGPoint, in view: UIView?) -> CGPoint {
            let screen: Int = switch view?.window?.windowScene?.effectiveGeometry.interfaceOrientation {
            case .landscapeRight: 1
            case .portraitUpsideDown: 2
            case .landscapeLeft: 3
            default: 0
            }
            let device: Int = switch UIDevice.current.orientation {
            case .portrait: 0
            case .landscapeLeft: 1
            case .portraitUpsideDown: 2
            case .landscapeRight: 3
            default: screen
            }
            let turned = TrackpadOrientation(device: device, screen: screen).intended(dx: delta.x, dy: delta.y)
            return CGPoint(x: turned.dx, y: turned.dy)
        }

        /// Measured from the view itself: a size handed in from SwiftUI was still zero when the first moves arrived, and the engine drops a move against an empty pad, so only taps reached the Mac.
        private func fraction(_ delta: CGPoint, in view: UIView?) -> CGSize? {
            guard let bounds = view?.bounds, bounds.width > 0, bounds.height > 0 else { return nil }
            let delta = intended(delta, in: view)
            return CGSize(width: delta.x / bounds.width, height: delta.y / bounds.height)
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let delta = recognizer.translation(in: recognizer.view)
                recognizer.setTranslation(.zero, in: recognizer.view)
                actions.onTouch(recognizer.location(in: recognizer.view))
                if let move = fraction(delta, in: recognizer.view) { actions.onMove(move) }
            default:
                actions.onTouch(nil)
            }
        }

        @objc func scrolled(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .changed else { return }
            let delta = intended(recognizer.translation(in: recognizer.view), in: recognizer.view)
            recognizer.setTranslation(.zero, in: recognizer.view)
            actions.onScroll(CGSize(width: delta.x, height: delta.y))
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            actions.onPress(recognizer.location(in: recognizer.view))
            actions.onTap()
        }

        @objc func swiped(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let travel = intended(recognizer.translation(in: recognizer.view), in: recognizer.view)
            guard let swipe = TrackpadSwipe(dx: travel.x, dy: travel.y) else { return }
            actions.onSwipe(swipe)
        }

        @objc func twoTapped() { actions.onTwoFingerTap() }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                lastHoldPoint = point
                actions.onTouch(point)
                actions.onDragBegin()
            case .changed:
                let delta = CGPoint(x: point.x - lastHoldPoint.x, y: point.y - lastHoldPoint.y)
                lastHoldPoint = point
                actions.onTouch(point)
                if let move = fraction(delta, in: recognizer.view) { actions.onMove(move) }
            case .ended, .cancelled, .failed:
                actions.onTouch(nil)
                actions.onDragEnd()
            default:
                break
            }
        }
    }
}
