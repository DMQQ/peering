import Foundation
import RemoteCore

/// Turns measurements the client already has into a stable bitrate choice.
///
/// Falling is intentionally fast: a decoder dropping frames or a round trip climbing past a
/// human-noticeable threshold means the current rate is already hurting the session. Rising is
/// deliberately slow so one good ping cannot make the stream bounce between two bitrates.
struct AutoQualityPolicy: Sendable {
    enum Path: Sendable {
        case lan, relay, direct
    }

    enum Tier: Int, Sendable, Equatable {
        case low, medium, high

        /// The rates themselves come from ``VideoQualityTier``, because the host acts on the
        /// same three numbers: it caps a stream on the control channel at the low one, and has
        /// to put something back when the picture returns to the transport it prefers. A table
        /// written out twice is two ends that can disagree about what a tier means.
        var bitrateKbps: Int {
            switch self {
            case .low: return VideoQualityTier.low.rawValue
            case .medium: return VideoQualityTier.medium.rawValue
            case .high: return VideoQualityTier.high.rawValue
            }
        }

        var lower: Tier {
            switch self {
            case .high: return .medium
            case .medium, .low: return .low
            }
        }

        var higher: Tier {
            switch self {
            case .low: return .medium
            case .medium, .high: return .high
            }
        }
    }

    static let healthySamplesForUpgrade = 12

    private(set) var tier: Tier
    private let path: Path
    private var healthySamples = 0

    init(path: Path) {
        self.path = path
        tier = path == .relay ? .medium : .high
    }

    /// Returns a new tier only when the host should be told to change bitrate.
    mutating func observe(latencyMilliseconds: Double, newDroppedFrames: Int) -> Tier? {
        if latencyMilliseconds >= 350 || newDroppedFrames >= 3 {
            healthySamples = 0
            return change(to: .low)
        }

        if latencyMilliseconds >= 160 || newDroppedFrames > 0 {
            healthySamples = 0
            return change(to: tier.lower)
        }

        let healthyLatency: Double = path == .relay ? 80 : 65
        guard latencyMilliseconds <= healthyLatency else {
            healthySamples = 0
            return nil
        }

        healthySamples += 1
        guard healthySamples >= Self.healthySamplesForUpgrade else { return nil }
        healthySamples = 0
        return change(to: tier.higher)
    }

    private mutating func change(to proposed: Tier) -> Tier? {
        guard proposed != tier else { return nil }
        tier = proposed
        return proposed
    }
}
