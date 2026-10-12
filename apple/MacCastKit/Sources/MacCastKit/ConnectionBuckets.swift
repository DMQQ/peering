import Foundation

/// Coarse buckets for figures that would otherwise identify a session: a closed set per value, so analytics can group by it.
public enum ConnectionBuckets {
    /// `remaining` is `nil` for a plan the relay does not meter.
    public static func quotaRemaining(_ remaining: TimeInterval?) -> String {
        guard let remaining else { return "unlimited" }
        switch remaining {
        case ..<1: return "0"
        case ..<300: return "<5m"
        case ..<900: return "<15m"
        default: return ">=15m"
        }
    }

    public static func bytes(_ count: Int64) -> String {
        switch count {
        case ..<1: return "0"
        case ..<1_000_000: return "<1MB"
        case ..<10_000_000: return "<10MB"
        case ..<100_000_000: return "<100MB"
        case ..<1_000_000_000: return "<1GB"
        default: return ">=1GB"
        }
    }

    public static func droppedFrames(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case ..<10: return "<10"
        case ..<100: return "<100"
        case ..<1000: return "<1000"
        default: return ">=1000"
        }
    }
}
