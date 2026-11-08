import Foundation

/// What the display does with a compressed frame, given whether it is waiting for a keyframe and whether it can take one.
public enum VideoFrameAdmission: Sendable, Equatable {
    case enqueue
    /// A keyframe arriving at a backed-up renderer: worth emptying the queue for, since dropping it extends the wait for a recovery point.
    case flushThenEnqueue
    /// An inter frame that cannot be decoded against what the display holds.
    case drop
    /// An inter frame the renderer had no room for. Every later one references it, so the picture is frozen on the last good frame until a keyframe, instead of smearing.
    case dropAndAwaitKeyframe
}

public enum VideoFrameGate {
    public static func admit(isKeyframe: Bool, awaitingKeyframe: Bool, rendererReady: Bool) -> VideoFrameAdmission {
        if awaitingKeyframe && !isKeyframe { return .drop }
        if !rendererReady { return isKeyframe ? .flushThenEnqueue : .dropAndAwaitKeyframe }
        return .enqueue
    }
}
