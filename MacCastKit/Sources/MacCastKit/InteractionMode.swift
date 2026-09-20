import Foundation

/// What the fingers on the picture are for.
///
/// A choice the user makes and can see, not a heuristic. It used to be a hidden flag that
/// pinch-zoom flipped on its own, so the same two-finger drag either scrolled the Mac or moved
/// the view depending on something the user had done earlier in a different gesture — which is
/// impossible to build a habit around.
///
/// Control includes viewing, scrolling, dragging, zooming and panning. Observe is the only
/// separate mode because it makes a materially different promise: no input reaches the Mac.
public enum InteractionMode: CaseIterable, Identifiable, RawRepresentable {
    public typealias RawValue = String

    /// Fingers drive the Mac and the view: one finger controls, pinch zooms, and two fingers
    /// scroll while fitted or pan while zoomed.
    case control
    /// The picture can be inspected, while every input command is blocked.
    case observe

    /// `navigate` was the old Drag & zoom mode. Restoring it as control is the migration that
    /// merges the two modes for existing installs instead of leaving a saved value with no case.
    public init?(rawValue: String) {
        switch rawValue {
        case "control", "navigate": self = .control
        case "observe": self = .observe
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .control: return "control"
        case .observe: return "observe"
        }
    }

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .control: return "Control & zoom"
        case .observe: return "Observe"
        }
    }

    public var symbol: String {
        switch self {
        case .control: return "hand.point.up.left"
        case .observe: return "eye"
        }
    }

    public var toggled: InteractionMode {
        switch self {
        case .control: return .observe
        case .observe: return .control
        }
    }
}

extension InteractionMode {
    /// Pinching always resizes the canvas. The interaction mode only changes what drags do.
    public var pinchZoomsCanvas: Bool { true }

    /// Whether a one-finger drag moves the picture rather than doing something on the Mac.
    public var oneFingerDragPansCanvas: Bool { self == .observe }

    /// Whether a one-finger drag is sent to the Mac at all.
    ///
    /// The pair with ``oneFingerDragPansCanvas`` is the rule this file keeps: a drag moves the
    /// picture or it goes to the Mac, and never both, so no mode can be ambiguous about what a
    /// finger is doing.
    public var oneFingerDragReachesTheMac: Bool { self == .control }

    /// Whether a two-finger drag moves the picture rather than scrolling the Mac.
    ///
    /// Always in observe. In control only while the picture is larger than the view it is drawn
    /// in, which is the one case where there is somewhere to pan *to*. Fitted, with bars down
    /// either side, the gesture scrolls the Mac.
    ///
    /// **The rule is about the picture, not about history.** An earlier version keyed off the
    /// zoom alone, and was argued against on the grounds that the same gesture would do
    /// different things depending on what the user had done minutes earlier. That objection
    /// holds when the cause is invisible; it does not hold here, because a picture that
    /// overflows its view is the thing the user is looking at. The zoom is on screen in the
    /// pill besides — see the percentage readout in ``RemoteScreen``.
    public func twoFingerDragPansCanvas(isZoomed: Bool) -> Bool {
        self != .control || isZoomed
    }

    /// Whether a tap is a click on the Mac. Observe blocks it along with every other input.
    public var tapsReachTheMac: Bool { self == .control }

}
