import Foundation

/// Turns a finger's movement on the glass into the direction the person meant, when the phone is held at an angle the screen did not rotate to (upside down, most often). Quarter turns count the phone's rotation past the screen's, counterclockwise as the person sees it.
public struct TrackpadOrientation: Sendable, Equatable {
    public let quarterTurns: Int

    /// Orientations as quarter turns counterclockwise from upright portrait: 0 portrait, 1 the top to the left, 2 upside down, 3 the top to the right.
    public init(device: Int, screen: Int) {
        quarterTurns = ((device - screen) % 4 + 4) % 4
    }

    /// `dy` grows downwards on the glass and in the result.
    public func intended(dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        switch quarterTurns {
        case 1: (dy, -dx)
        case 2: (-dx, -dy)
        case 3: (-dy, dx)
        default: (dx, dy)
        }
    }
}
