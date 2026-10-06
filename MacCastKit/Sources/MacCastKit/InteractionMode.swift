import Foundation

/// What the fingers on the picture are for.
///
/// A choice the user makes and can see, not a heuristic: the same two-finger drag cannot scroll the
/// Mac in one state and move the view in another depending on what came before.
///
/// Control includes viewing, scrolling, dragging, zooming and panning. Observe is the only separate
/// mode because it makes a materially different promise: no input reaches the Mac.
public enum InteractionMode: CaseIterable, Identifiable, RawRepresentable {
    public typealias RawValue = String

    /// Fingers drive the Mac and the view: one finger controls, pinch zooms, and two fingers
    /// scroll while fitted or pan while zoomed.
    case control
    /// The picture can be inspected, while every input command is blocked.
    case observe

    /// `navigate` was the old Drag & zoom mode, restored as control so a saved value from an
    /// earlier install still resolves instead of having no case.
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
        case .control: return String(localized: "Control & zoom")
        case .observe: return String(localized: "Observe")
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
    /// picture or it goes to the Mac, never both.
    public var oneFingerDragReachesTheMac: Bool { self == .control }

    /// Whether a two-finger drag moves the picture rather than scrolling the Mac.
    ///
    /// Always in observe. In control only while the picture is larger than the view it is drawn in,
    /// which is the one case where there is somewhere to pan to: fitted, with bars down either side,
    /// the gesture scrolls the Mac. The overflow is on screen and so is the zoom, in the pill's
    /// percentage readout in ``RemoteScreen``, so the gesture stays predictable.
    public func twoFingerDragPansCanvas(isZoomed: Bool) -> Bool {
        self != .control || isZoomed
    }

    /// Whether a tap is a click on the Mac. Observe blocks it along with every other input.
    public var tapsReachTheMac: Bool { self == .control }

}
