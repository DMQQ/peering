import RemoteCore
import SwiftUI
import UIKit

/// What a gesture turns into on the wire.
///
/// An extension rather than a file of its own type: state and its gestures have to
/// agree about what the picture is, and the view is easier to read in pieces than as
/// one file of two thousand lines. Members are `internal` here because Swift's
/// `private` is file-scoped — see the note in `RemoteScreen`.
extension RemoteScreen {
    func sendScroll(dy: CGFloat) {
        model.send(.scroll(dx: 0, dy: Double(dy)))
    }

    /// What the wheel does, which is the mode's business rather than the wheel's.
    ///
    /// In control it scrolls the Mac. In observe it zooms the picture, because input is blocked.
    func wheelScroll(dy: CGFloat) {
        switch interactionMode {
        case .control: sendScroll(dy: dy)
        case .observe: zoomByWheel(dy)
        }
    }

    /// What the wheel is for at the moment, for anyone listening rather than looking.
    var wheelLabel: String {
        interactionMode == .control ? "Scroll the Mac" : "Zoom the picture"
    }

    /// How far up its track the wheel's gauge should be filled, 0 to 1.
    ///
    /// Logarithmic, because zoom is: the difference between 1× and 2× is the same *step* as
    /// between 4× and 8×, and a linear gauge would spend the whole top half of its length on the
    /// last few factors while the bottom half covered everything below 2×. Measured, it makes each
    /// equal length of track an equal doubling.
    var zoomPosition: CGFloat {
        let low = log(minimumZoom)
        let high = log(maximumZoom)
        guard high > low, zoom > 0 else { return 0 }
        return min(max((log(zoom) - low) / (high - low), 0), 1)
    }

    /// How far one pixel of wheel travel moves the zoom.
    ///
    /// Multiplicative, because zoom is: a fixed step is an enormous change at 1× and invisible at
    /// 6×, and a finger on the wheel has no idea which end of the range it is at. A full drag of
    /// the track works out at roughly six times either way — enough to be worth the space, not so
    /// much that it overshoots what the user aimed at.
    static let zoomPerPixel: CGFloat = 1.0 / 400

    /// Resizes the picture by a wheel drag. Up is closer, which is the way the two-finger pinch
    /// already goes.
    ///
    /// Zooming back out past the fit drops the pan, exactly as the pinch does: the pan limits
    /// shrink with the picture, so at 1× every offset is already out of bounds and holding one
    /// would leave the picture pinned off-centre for no reason the user can see.
    func zoomByWheel(_ pixels: CGFloat) {
        let before = zoom
        zoom = min(max(zoom * exp(-pixels * Self.zoomPerPixel), minimumZoom), maximumZoom)
        // Re-clamped, not reset — see `onZoom`. The wheel is a finer control than a pinch and
        // makes the snap at the end of a zoom-out easier to produce, not harder.
        pan = clampedPan(pan)
    }

    func sendJoystick(_ travel: CGSize) {
        // The speed multiplies the travel here rather than at the joystick, so the drawn cursor
        // and the Mac's pointer are advanced by the same amount. Scaling one and not the other
        // is exactly the drift where the arrow on screen stops agreeing with the thing clicking.
        let speed = CGFloat(model.pointerSpeed)
        let scaled = CGSize(width: travel.width * speed, height: travel.height * speed)
        model.send(.joystickMove(dx: Double(scaled.width), dy: Double(scaled.height)))
        // The joystick is the one control that moves the Mac's pointer without the client
        // knowing where it went. Touch sends an absolute position, so the drawn cursor and the
        // real one are the same fact; a joystick sends a delta and nothing comes back, because
        // the protocol does not carry the pointer's position — `InputTransform` has the inverse
        // for a host that reports it, and no host does. So the client advances its own copy by
        // the same delta, in the same units.
        //
        // The units are the captured content's points, which is the space `joystickMove` is in —
        // see `capturePointSize`. That is why this divides by it rather than by anything the
        // canvas knows about: the pointer travels in the Mac's points whatever the phone draws.
        //
        // It is an estimate, and it drifts in exactly one case: the Mac's pointer stopping at a
        // screen edge while the thumb keeps pushing. The next touch corrects it, because a touch
        // is absolute.
        advanceClientCursor(by: scaled)
    }

    func advanceClientCursor(by travel: CGSize) {
        let points = model.capturePointSize
        guard points.width > 0, points.height > 0 else { return }
        let nx = min(max(Double(CGFloat(remoteCursor.x) + travel.width / points.width), 0), 1)
        let ny = min(max(Double(CGFloat(remoteCursor.y) + travel.height / points.height), 0), 1)
        remoteCursor = NormalizedPoint(x: nx, y: ny)
    }

    func sendJoystickClick() {
        model.send(.mouseDown(button: .left))
        model.send(.mouseUp(button: .left))
    }

    func sendJoystickRightClick() {
        model.send(.mouseDown(button: .right))
        model.send(.mouseUp(button: .right))
    }

    func sendKey(keyCode: UInt16, modifiers: Modifiers = []) {
        model.send(.keyDown(keyCode: keyCode, modifiers: modifiers))
        model.send(.keyUp(keyCode: keyCode, modifiers: modifiers))
    }

    /// - Parameter action: what the key does, when sending it is not the whole of it — Return also
    ///   clears the typed preview. Defaults to the plain press this strip uses for everything else.
    func compactKeyButton(
        icon: String,
        keyCode: UInt16,
        action: (() -> Void)? = nil
    ) -> some View {
        Button { (action ?? { sendKey(keyCode: keyCode) })() } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 32)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(RailButtonStyle(scale: 0.86))
    }

}
