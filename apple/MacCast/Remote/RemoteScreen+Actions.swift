import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

extension RemoteScreen {
    func sendScroll(dy: Double) {
        model.send(.scroll(dx: 0, dy: dy))
    }

    func wheelNotch(_ notches: Int) {
        switch interactionMode {
        case .control: sendScroll(dy: Double(notches) * ScrollNotch.pixels)
        case .observe: zoomByNotch(notches)
        }
    }

    var wheelLabel: String {
        interactionMode == .control ? String(localized: "Scroll the Mac") : String(localized: "Zoom the picture")
    }

    var zoomPosition: CGFloat {
        CanvasViewport.wheelPosition(zoom: zoom)
    }

    static let zoomPerPixel: CGFloat = 1.0 / 400

    /// Zooming back out past the fit drops the pan, exactly as the pinch does: the pan limits
    /// shrink with the picture, so at 1× every offset is already out of bounds and holding one
    /// would leave the picture pinned off-centre for no reason the user can see.
    func zoomByNotch(_ notches: Int) {
        let step = Double(notches) * ScrollNotch.pixels * Double(Self.zoomPerPixel)
        zoom = CanvasViewport.wheeled(zoom: zoom, step: step)
        // Re-clamped, not reset — see `onZoom`. The wheel is a finer control than a pinch and
        // makes the snap at the end of a zoom-out easier to produce, not harder.
        pan = clampedPan(pan)
    }

    func sendJoystick(_ travel: CGSize) {
        lastJoystickInput = MonotonicStamp()
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
        // It is an estimate, and it drifts in exactly one case: the Mac's pointer stopping at a
        // screen edge while the thumb keeps pushing. The next touch corrects it, because a touch
        // is absolute.
        advanceClientCursor(by: scaled)
    }

    /// The Mac's watcher reports any pointer move it did not post itself, and while the joystick drives it a few of its own steps look like a hand. Applied, one pulls the drawn cursor to a position from mid-drag. The estimate stays, because only a hand on the Mac can be trusted to move it elsewhere.
    func adoptHostPointer() {
        if let last = lastJoystickInput, last.isWithin(seconds: 1) { return }
        remoteCursor = model.hostPointer.point
    }

    func advanceClientCursor(by travel: CGSize) {
        let points = model.capturePointSize
        guard points.width > 0, points.height > 0 else { return }
        let nx = min(max(Double(CGFloat(remoteCursor.x) + travel.width / points.width), 0), 1)
        let ny = min(max(Double(CGFloat(remoteCursor.y) + travel.height / points.height), 0), 1)
        remoteCursor = NormalizedPoint(x: nx, y: ny)
    }

    func sendJoystickClick() {
        // Joystick input is relative, so they can drift — physical mouse movement,
        // edge-clamping, or a first tap before any movement. Sending the position
        // here makes a joystick tap behave identically to a touch tap.
        model.send(.mouseMove(to: remoteCursor))
        model.send(.mouseDown(button: .left))
        model.send(.mouseUp(button: .left))
    }

    func sendJoystickRightClick() {
        model.send(.mouseMove(to: remoteCursor))
        model.send(.mouseDown(button: .right))
        model.send(.mouseUp(button: .right))
    }

    /// **The latch has to be folded in here rather than left to the Mac.** It is held on the far end
    /// as a real key-down, so an event that did not repeat it in its own flags is a Mac holding ⌃
    /// while the key it is being told about says there is none. Latching two and pressing one key is
    /// the whole of how a combination is sent in one action.
    func sendKey(keyCode: UInt16, modifiers: Modifiers = []) {
        let all = modifiers.union(model.latchedModifiers)
        model.send(.keyDown(keyCode: keyCode, modifiers: all))
        model.send(.keyUp(keyCode: keyCode, modifiers: all))
    }

    func compactKeyButton(
        icon: String,
        keyCode: UInt16,
        large: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        compactCapButton(icon: icon, large: large) { (action ?? { sendKey(keyCode: keyCode) })() }
    }

    @ViewBuilder
    func compactCapButton(icon: String, filled: Bool = false, large: Bool = false, action: @escaping () -> Void) -> some View {
        let size = large ? CGSize(width: 54, height: 42) : CGSize(width: 40, height: 32)
        let glyph: CGFloat = large ? 18 : 14
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            if filled {
                Image(systemName: icon)
                    .font(.system(size: glyph, weight: .bold))
                    .foregroundStyle(ColorPalette.onInk)
                    .frame(width: size.width, height: size.height)
                    .background(ColorPalette.ink, in: shape)
            } else {
                // Yields width on a narrow phone: the keyboard bar's key row adds up to more than a 402pt screen with every key at full size, and a row wider than the screen drags the header pill's buttons off both edges.
                Image(systemName: icon)
                    .font(.system(size: glyph, weight: .semibold))
                    .frame(minWidth: large ? size.width : 28, idealWidth: size.width, maxWidth: size.width, minHeight: size.height, maxHeight: size.height)
                    .glassSurface(in: shape, interactive: true)
            }
        }
        .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
    }

}
