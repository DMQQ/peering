import Foundation

/// The way a several-finger swipe on the trackpad went, read once when the fingers lift.
public enum TrackpadSwipe: Sendable, Equatable {
    case left, right, up, down

    /// Below this distance in points a lift is no swipe at all.
    public static let minimumDistance = 40.0

    /// The longer axis decides, so a swipe drawn at an angle still counts. `dy` grows downwards, as on screen.
    public init?(dx: Double, dy: Double) {
        guard max(abs(dx), abs(dy)) >= Self.minimumDistance else { return nil }
        if abs(dx) >= abs(dy) {
            self = dx < 0 ? .left : .right
        } else {
            self = dy < 0 ? .up : .down
        }
    }
}
