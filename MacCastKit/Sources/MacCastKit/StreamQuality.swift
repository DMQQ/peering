import Foundation
import RemoteCore

/// The raw value is a storage token, not the word on screen: `@AppStorage` persists it, so keying on UI copy would reset every stored preference when a label changes. Decoded with `init?(rawValue:)` so an unknown token is distinguishable from a real answer.
public enum StreamQuality: CaseIterable, Hashable, Sendable, RawRepresentable {
    public typealias RawValue = String

    case auto, low, medium, high

    public init?(rawValue: String) {
        switch rawValue {
        case "auto": self = .auto
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .auto: return "auto"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    /// `auto` is the other answer to the same question, not a fourth rung. The picker uses this list so a new case cannot be left behind.
    public static let manualCases: [StreamQuality] = allCases.filter { $0 != .auto }

    /// The same three numbers as ``AutoQualityPolicy/Tier``, and the same source for them:
    /// `Low` here is what the host caps a stream at when the picture is on the control channel.
    public var bitrateKbps: Int? {
        switch self {
        case .auto: return nil
        case .low: return VideoQualityTier.low.rawValue
        case .medium: return VideoQualityTier.medium.rawValue
        case .high: return VideoQualityTier.high.rawValue
        }
    }

    public var chipTitle: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Med")
        case .high: return String(localized: "High")
        }
    }

    public var title: String {
        switch self {
        case .auto: return String(localized: "Automatic")
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        }
    }

    /// Shared by the status chip's menu and the Settings tab so they cannot describe the presets differently.
    public var menuTitle: String {
        switch self {
        case .auto: return String(localized: "Auto, follows the network")
        case .low: return String(localized: "Low, 2 Mbps")
        case .medium: return String(localized: "Medium, 8 Mbps")
        case .high: return String(localized: "High, 20 Mbps")
        }
    }

    /// The preset naming an automatic tier, so a manual choice starts where the policy settled. The enums share ``bitrateKbps`` but not cases.
    public init(_ tier: AutoQualityPolicy.Tier) {
        switch tier {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }
}

extension StreamQuality {
    /// Failable decoding on purpose: an absent or unrecognised token reads as ``StreamQuality/auto``, and a token from the old spelling or a future version is not mistaken for a choice. Defaults are a parameter for tests.
    public static func stored(in defaults: UserDefaults = .standard) -> StreamQuality {
        defaults.string(forKey: PreferenceKeys.streamQuality)
            .flatMap(StreamQuality.init(rawValue:)) ?? .auto
    }

    /// `nil` for a stored ``StreamQuality/auto``: the policy's current tier stands in. See `setAutomaticQuality(_:)`.
    public static func storedManualLevel(in defaults: UserDefaults = .standard) -> StreamQuality? {
        let stored = stored(in: defaults)
        return stored.isManual ? stored : nil
    }

    public var isManual: Bool { bitrateKbps != nil }
}
