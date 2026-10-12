import Foundation

/// Lets a failure through at most once a minute per code, counting what it swallowed, so a failure loop sends one event with a number instead of thousands. Not thread safe: the caller holds its own lock.
public struct HostErrorLimiter: Sendable {
    public static let window: TimeInterval = 60

    private var lastSent: [HostEventCodes.ErrorCode: Date] = [:]
    private var suppressed: [HostEventCodes.ErrorCode: Int] = [:]

    public init() {}

    /// The number of occurrences this event stands for (1 or more), or `nil` when it is held back.
    public mutating func admit(_ code: HostEventCodes.ErrorCode, at now: Date) -> Int? {
        if let last = lastSent[code], now.timeIntervalSince(last) < Self.window {
            suppressed[code, default: 0] += 1
            return nil
        }
        lastSent[code] = now
        return 1 + (suppressed.removeValue(forKey: code) ?? 0)
    }
}
