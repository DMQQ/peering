import Foundation

/// What a change of mode asks of the picture. A Mac that cannot be asked to pause keeps streaming, and nothing is sent to it.
public enum SessionModePicture {
    public enum Action: Equatable, Sendable {
        case none
        case pause
        case resume
    }

    /// `pausedByMode` is whether this mode logic paused the picture earlier, so a pause the person asked for is never undone.
    public static func action(entering mode: SessionMode, hostMayPause: Bool, pausedByMode: Bool) -> Action {
        guard hostMayPause else { return .none }
        if mode.showsPicture { return pausedByMode ? .resume : .none }
        return pausedByMode ? .none : .pause
    }
}
