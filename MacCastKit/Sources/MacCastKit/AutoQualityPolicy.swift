import Foundation
import RemoteCore

/// Turns measurements the client already has into a stable bitrate choice: it falls on the first
/// bad sample and rises only after ``healthySamplesForUpgrade`` good ones, so one good ping cannot
/// make the stream bounce between two bitrates.
public struct AutoQualityPolicy: Sendable {
    public enum Path: Sendable {
        case lan, relay, direct
    }

    public enum Tier: Int, Sendable, Equatable {
        case low, medium, high

        /// Read from ``VideoQualityTier``, because the host caps a stream at the same three
        /// numbers: a table written out twice is two ends that can disagree about a tier.
        public var bitrateKbps: Int {
            switch self {
            case .low: return VideoQualityTier.low.rawValue
            case .medium: return VideoQualityTier.medium.rawValue
            case .high: return VideoQualityTier.high.rawValue
            }
        }

        /// Where this rung sits in the ladder, for the one comparison a ceiling needs.
        var rank: Int {
            switch self {
            case .low: return 0
            case .medium: return 1
            case .high: return 2
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

    public static let healthySamplesForUpgrade = 12

    public private(set) var tier: Tier
    private let path: Path
    /// The fastest this session may go, which is the plan's answer rather than the network's.
    private let ceiling: Tier
    private var healthySamples = 0

    /// - Parameter ceiling: how far the picture may climb on this session. Relayed bytes are the
    ///   operator's, so a relayed session is capped by the plan; a direct one has nothing to sell.
    public init(path: Path, ceiling: Tier = .high) {
        self.path = path
        self.ceiling = ceiling
        tier = path == .relay ? .medium : .high
    }

    /// Returns a new tier only when the host should be told to change bitrate.
    public mutating func observe(latencyMilliseconds: Double, newDroppedFrames: Int) -> Tier? {
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
        // Clamped on the way up, never on the way down: a ceiling is not a floor under how bad the
        // connection may become. Clamped rather than refused, so a capped plan still climbs.
        let capped = proposed.rank > ceiling.rank ? ceiling : proposed
        guard capped != tier else { return nil }
        tier = capped
        return capped
    }
}
