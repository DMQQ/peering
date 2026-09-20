import Foundation
import RemoteCore

/// Turns measurements the client already has into a stable bitrate choice.
///
/// Falling is intentionally fast: a decoder dropping frames or a round trip climbing past a
/// human-noticeable threshold means the current rate is already hurting the session. Rising is
/// deliberately slow so one good ping cannot make the stream bounce between two bitrates.
public struct AutoQualityPolicy: Sendable {
    public enum Path: Sendable {
        case lan, relay, direct
    }

    public enum Tier: Int, Sendable, Equatable {
        case low, medium, high

        /// The rates themselves come from ``VideoQualityTier``, because the host acts on the
        /// same three numbers: it caps a stream on the control channel at the low one, and has
        /// to put something back when the picture returns to the transport it prefers. A table
        /// written out twice is two ends that can disagree about what a tier means.
        public var bitrateKbps: Int {
            switch self {
            case .low: return VideoQualityTier.low.rawValue
            case .medium: return VideoQualityTier.medium.rawValue
            case .high: return VideoQualityTier.high.rawValue
            }
        }

        /// Where this rung sits in the ladder, for the one comparison a ceiling needs. A number
        /// rather than a `Comparable` conformance: the only question ever asked of two of these is
        /// "is one above the other", and a type that can be sorted invites sorting it.
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

    /// - Parameter ceiling: how far the picture may climb on *this* session. The direct path is
    ///   never capped by a caller that passes `.high`, which is what every plan gets when the two
    ///   devices are on one network: nobody's bandwidth is being spent there, so there is nothing
    ///   to sell. A relayed session is capped by the plan, because those bytes are the operator's.
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
        // **Clamped on the way up and never on the way down.** A plan's ceiling is about how sharp
        // the picture may get; it is not a floor under how bad the connection is allowed to become,
        // and a session that has gone bad has to be free to fall below it. Clamped rather than
        // refused so that a plan which cannot reach the top still climbs as far as it can.
        let capped = proposed.rank > ceiling.rank ? ceiling : proposed
        guard capped != tier else { return nil }
        tier = capped
        return capped
    }
}
