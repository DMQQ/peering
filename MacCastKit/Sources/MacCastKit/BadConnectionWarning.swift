import Foundation

/// Decides when a round trip is bad enough to tell the person, and no more often than they can use it.
public struct BadConnectionWarning: Sendable {
    public static let thresholdMilliseconds: Double = 1000
    /// Readings in a row above the threshold before it counts, so one stalled round trip is not a verdict.
    public static let sustainedReadings = 3
    public static let cooldown: TimeInterval = 300

    private var slowReadings = 0
    private var lastWarnedAt: Date?

    public init() {}

    /// True when this reading is the one to warn on.
    public mutating func shouldWarn(milliseconds: Double, now: Date = Date()) -> Bool {
        guard milliseconds >= Self.thresholdMilliseconds else {
            slowReadings = 0
            return false
        }
        slowReadings += 1
        guard slowReadings >= Self.sustainedReadings else { return false }
        if let lastWarnedAt, now.timeIntervalSince(lastWarnedAt) < Self.cooldown { return false }
        lastWarnedAt = now
        return true
    }
}
