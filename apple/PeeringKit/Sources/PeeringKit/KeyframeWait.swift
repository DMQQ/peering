import Foundation

/// How long a client has waited for the keyframe it asked for, and when a still screen needs a push.
///
/// A requested keyframe is only ever carried by the next frame the capture produces, and a still screen produces none. Pure: it takes the instant as an argument, so tests need no sleeping.
public struct KeyframeWait: Sendable {
    /// Long enough that a screen which is changing delivers its own frame first, so the push is only spent on a still one.
    public static let nudgeAfter: Duration = .milliseconds(150)

    public struct Delivered: Sendable, Equatable {
        public let waitedMilliseconds: Int
        public let nudged: Bool
    }

    private var askedAt: ContinuousClock.Instant?
    private var nudged = false

    public init() {}

    /// The earliest unanswered request is the one that counts: a second ask does not restart the wait.
    public mutating func asked(at now: ContinuousClock.Instant) {
        if askedAt == nil { askedAt = now }
    }

    /// True once per wait, when it has gone on past ``nudgeAfter``.
    public mutating func shouldNudge(at now: ContinuousClock.Instant) -> Bool {
        guard let askedAt, !nudged, now - askedAt >= Self.nudgeAfter else { return false }
        nudged = true
        return true
    }

    /// Ends the wait; nil when no keyframe had been asked for, as for the encoder's own periodic one.
    public mutating func delivered(at now: ContinuousClock.Instant) -> Delivered? {
        defer {
            askedAt = nil
            nudged = false
        }
        guard let askedAt else { return nil }
        let waited = now - askedAt
        let milliseconds = Int(waited / .milliseconds(1))
        return Delivered(waitedMilliseconds: milliseconds, nudged: nudged)
    }
}
