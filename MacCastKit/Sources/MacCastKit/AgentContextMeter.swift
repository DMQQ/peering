import Foundation
import RemoteCore

/// How full a chat's context is, for the small bar in its options row.
public enum AgentContextMeter {
    /// From this fraction the agent is close to compacting or refusing, and the bar says so.
    public static let nearlyFull = 0.8

    /// Nil until both numbers are known: a window guessed wrong would show a confident, false bar.
    public static func fraction(used: Int?, window: Int?) -> Double? {
        guard let used, let window, window > 0, used >= 0 else { return nil }
        return min(Double(used) / Double(window), 1)
    }

    public static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    /// "70k", "200k", "1M", "1.2M": what a bar's label has room for.
    public static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        if count >= 1_000 { return "\(Int((Double(count) / 1_000).rounded()))k" }
        return "\(count)"
    }

    public static func label(used: Int, window: Int) -> String {
        "\(tokens(used)) / \(tokens(window))"
    }

    /// The account's five-hour window, when the CLI reported one.
    public static func fiveHour(in limits: [AgentUsageLimit]) -> AgentUsageLimit? {
        limits.first { $0.label == "5 hours" }
    }

    public static func isNearlyFull(_ fraction: Double) -> Bool {
        fraction >= nearlyFull
    }
}
