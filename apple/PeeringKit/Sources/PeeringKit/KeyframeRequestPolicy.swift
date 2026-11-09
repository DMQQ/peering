import Foundation

/// When a viewer that dropped frames asks the host for a keyframe. Not on the first dropped frame: a session starts by waiting for the keyframe the host already owes, and a second one would only be a second burst. And not again until the first has had time to arrive.
public struct KeyframeRequestPolicy: Sendable {
    public static let graceSeconds = 0.3
    public static let cooldownSeconds = 1.0

    private var firstDropAt: TimeInterval?
    private var lastAskAt: TimeInterval?

    public init() {}

    /// A frame was dropped for want of a keyframe. True when the host should be asked now.
    public mutating func noteDrop(at now: TimeInterval) -> Bool {
        let started = firstDropAt ?? now
        firstDropAt = started
        guard now - started >= Self.graceSeconds else { return false }
        if let lastAskAt, now - lastAskAt < Self.cooldownSeconds { return false }
        lastAskAt = now
        return true
    }

    /// A picture was shown: the wait is over, and the next one starts its own grace.
    public mutating func noteRecovered() {
        firstDropAt = nil
    }
}
