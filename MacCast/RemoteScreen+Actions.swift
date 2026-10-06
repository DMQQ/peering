import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// What a gesture turns into on the wire.
extension RemoteScreen {
    /// Sends a wheel delta, in the unit the host builds its event in: pixels of scroll, signed the
    /// way a wheel rolled towards the user reads, so positive scrolls down.
    ///
    /// The only figure in the app that produces one is ``ScrollNotch/pixels``, which is why the
    /// wheel hands over notches and this multiplies: the control counts detents and knows nothing
    /// about pixels, and the one place that knows how big a detent is is the one place that
    /// crosses to the wire.
    func sendScroll(dy: Double) {
        model.send(.scroll(dx: 0, dy: dy))
    }

    /// What the wheel does, which is the mode's business rather than the wheel's.
    ///
    /// In control it scrolls the Mac. In observe it zooms the picture, because input is blocked.
    /// Either way it is handed whole notches and converts them here, so that the two meanings of
    /// the same control cannot disagree about how much a notch is.
    func wheelNotch(_ notches: Int) {
        switch interactionMode {
        case .control: sendScroll(dy: Double(notches) * ScrollNotch.pixels)
        case .observe: zoomByNotch(notches)
        }
    }

    /// What the wheel is for at the moment, for anyone listening rather than looking.
    var wheelLabel: String {
        interactionMode == .control ? String(localized: "Scroll the Mac") : String(localized: "Zoom the picture")
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
    /// 6×, and a finger on the wheel has no idea which end of the range it is at.
    ///
    /// The wheel arrives here as notches, which are turned into their pixel value on the way in, so
    /// one notch is a step of about six per cent — and the arrows above and below the wheel are
    /// exactly one of them. That is the same bargain the scrolling side strikes: a step the user
    /// can ask for by name rather than however far a drag happened to travel.
    static let zoomPerPixel: CGFloat = 1.0 / 400

    /// Resizes the picture by whole wheel notches. Up is closer, which is the way the two-finger
    /// pinch already goes.
    ///
    /// Zooming back out past the fit drops the pan, exactly as the pinch does: the pan limits
    /// shrink with the picture, so at 1× every offset is already out of bounds and holding one
    /// would leave the picture pinned off-centre for no reason the user can see.
    func zoomByNotch(_ notches: Int) {
        let step = Double(notches) * ScrollNotch.pixels * Double(Self.zoomPerPixel)
        zoom = min(max(zoom * exp(-step), minimumZoom), maximumZoom)
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
        // Anchor the cursor before clicking. Touch input always sends mouseMove(to:)
        // immediately before a press, so the host cursor and the drawn arrow agree.
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

    /// A key press, carrying both the modifiers the caller asked for and whatever is latched on the
    /// session's own ⇧⌃⌥⌘ row.
    ///
    /// **The latch has to be folded in here rather than left to the Mac.** It is held on the far end
    /// as a real key-down, so an event that did not repeat it in its own flags is a Mac holding ⌃
    /// while the key it is being told about says there is none. Latching two and pressing one key is
    /// the whole of how a combination is sent in one action.
    func sendKey(keyCode: UInt16, modifiers: Modifiers = []) {
        let all = modifiers.union(model.latchedModifiers)
        model.send(.keyDown(keyCode: keyCode, modifiers: all))
        model.send(.keyUp(keyCode: keyCode, modifiers: all))
    }

    /// - Parameter action: what the key does, when sending it is not the whole of it — Return also
    ///   clears the typed preview. Defaults to the plain press this strip uses for everything else.
    func compactKeyButton(
        icon: String,
        keyCode: UInt16,
        large: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        compactCapButton(icon: icon, large: large) { (action ?? { sendKey(keyCode: keyCode) })() }
    }

    /// The same cap, for a control that is not a key press.
    ///
    /// **One cap, because the cap is what says "press me".** The hide-keyboard control is pressed
    /// with the same thumb as the Return beside it and belongs to the same row, and while it was
    /// drawn as a bare glyph it read as a caption for the field rather than as the way out of the
    /// mode. The shape is here rather than at each control so the two cannot drift apart.
    /// `filled` draws the cap in ink, for the one key in a row that has to be found at a glance.
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
                Image(systemName: icon)
                    .font(.system(size: glyph, weight: .semibold))
                    .frame(width: size.width, height: size.height)
                    .glassSurface(in: shape, interactive: true)
            }
        }
        .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
    }

}
