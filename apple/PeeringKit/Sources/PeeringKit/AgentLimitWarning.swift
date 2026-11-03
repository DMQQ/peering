import Foundation
import RemoteCore

/// The warnings before the account's five-hour window runs out: one at each threshold, once per window.
public struct AgentLimitWarning: Equatable, Sendable {
    public static let thresholds = [80, 95]

    public let percent: Int
    public let resetsAt: Date?
    /// Names the window and the threshold, so the same warning is never given twice and a new window starts clean.
    public let key: String

    /// The highest threshold the window has reached, or nil below the first.
    public static func current(in limits: [AgentUsageLimit]) -> AgentLimitWarning? {
        guard let window = AgentContextMeter.fiveHour(in: limits) else { return nil }
        let used = AgentContextMeter.percent(window.usedFraction)
        guard let threshold = thresholds.last(where: { used >= $0 }) else { return nil }
        let windowID = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return AgentLimitWarning(percent: threshold, resetsAt: window.resetsAt, key: "\(windowID)-\(threshold)")
    }

    /// The warning to give now, if it has not been given; records it in `given`.
    public static func due(in limits: [AgentUsageLimit], given: inout Set<String>) -> AgentLimitWarning? {
        guard let warning = current(in: limits), !given.contains(warning.key) else { return nil }
        given.insert(warning.key)
        return warning
    }
}
