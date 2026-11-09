import Foundation

/// What a change of mode asks of the picture.
public enum SessionModePicture {
    public enum Action: Equatable, Sendable {
        case none
        case pause
        case resume
    }

    /// `pausedByMode` is whether this mode logic paused the picture earlier, so a pause the person asked for is never undone.
    public static func action(entering mode: SessionMode, pausedByMode: Bool) -> Action {
        if mode.showsPicture { return pausedByMode ? .resume : .none }
        return pausedByMode ? .none : .pause
    }
}
