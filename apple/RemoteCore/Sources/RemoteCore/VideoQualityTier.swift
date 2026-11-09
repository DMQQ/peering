import Foundation

public enum VideoQualityTier: Int, Sendable, CaseIterable {
    case low = 2_000
    case medium = 8_000
    case high = 20_000
    /// Reached only automatically, on a path that spends nobody's bandwidth.
    case ultra = 60_000
}
