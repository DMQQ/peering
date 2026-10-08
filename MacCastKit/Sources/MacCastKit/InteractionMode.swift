import Foundation

/// What the fingers on the picture are for.
public enum InteractionMode: CaseIterable, Identifiable, RawRepresentable {
    public typealias RawValue = String

    case control
    case observe

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

    public var oneFingerDragPansCanvas: Bool { self == .observe }

    /// Whether a one-finger drag is sent to the Mac at all.
    public var oneFingerDragReachesTheMac: Bool { self == .control }

    /// Whether a two-finger drag moves the picture rather than scrolling the Mac.
    public func twoFingerDragPansCanvas(isZoomed: Bool) -> Bool {
        self != .control || isZoomed
    }

    public var tapsReachTheMac: Bool { self == .control }

}
