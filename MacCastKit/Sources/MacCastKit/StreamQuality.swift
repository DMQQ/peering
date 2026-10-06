import Foundation
import RemoteCore

/// A preset for the picture's bitrate, or the app's own choice of one.
///
/// The raw value is a storage token and not the word on screen, because `@AppStorage` persists it:
/// keying a saved preference on UI copy means the day the chip's label is reconsidered, every
/// stored preference resets to automatic. The token is decoded through `init?(rawValue:)` rather
/// than force-read, so an unknown one is distinguishable from a real answer, the same shape as
/// ``InteractionMode``. The old spelling, the words on screen, decodes to nothing and starts over.
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

    /// The three rates that can be picked by hand, in order.
    ///
    /// `auto` is not a fourth rung of this ladder, it is the other answer to the same question, and
    /// ``SettingsPanel`` shows it that way as one mode and then three levels. The picker asks for
    /// this list rather than spelling the three out, so a case added here cannot leave it behind.
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

    /// What the status chip prints, abbreviated for the row it sits in. ``title`` and ``menuTitle``
    /// carry the roomier spellings.
    public var chipTitle: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Med")
        case .high: return String(localized: "High")
        }
    }

    /// The name spelled out, for somewhere with more room than the status chip.
    public var title: String {
        switch self {
        case .auto: return String(localized: "Automatic")
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        }
    }

    /// The name and what it costs, for a menu that has to say what is being given up.
    ///
    /// Shared by the status chip's menu (``RemoteScreen``) and the Settings tab, so the two cannot
    /// describe the same four presets differently.
    public var menuTitle: String {
        switch self {
        case .auto: return String(localized: "Auto, follows the network")
        case .low: return String(localized: "Low, 2 Mbps")
        case .medium: return String(localized: "Medium, 8 Mbps")
        case .high: return String(localized: "High, 20 Mbps")
        }
    }

    /// The preset that names a given automatic tier, so a manual choice starts where the policy
    /// settled. The two enums share their numbers through ``bitrateKbps`` but not their cases.
    public init(_ tier: AutoQualityPolicy.Tier) {
        switch tier {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }
}

extension StreamQuality {
    /// The preset the app is set to, read straight from the defaults.
    ///
    /// Failable decoding on purpose: an absent or unrecognised token means nothing has been stored
    /// yet and reads as ``StreamQuality/auto``. A force-read would make a token from a future
    /// version read as a choice somebody made, and a token written under the old spelling decodes
    /// to nothing rather than silently becoming a different preset.
    ///
    /// The defaults are a parameter so the rule can be exercised without writing to the real store.
    public static func stored(in defaults: UserDefaults = .standard) -> StreamQuality {
        defaults.string(forKey: PreferenceKeys.streamQuality)
            .flatMap(StreamQuality.init(rawValue:)) ?? .auto
    }

    /// The level to come back to when the rate is taken over by hand again, or `nil` for automatic.
    ///
    /// `nil` for a stored ``StreamQuality/auto``: there is no manual level to come back to, and the
    /// policy's current tier stands in. See `setAutomaticQuality(_:)`.
    public static func storedManualLevel(in defaults: UserDefaults = .standard) -> StreamQuality? {
        let stored = stored(in: defaults)
        return stored.isManual ? stored : nil
    }

    /// Whether this preset names a rate, which is the same question as whether it is ``auto``.
    public var isManual: Bool { bitrateKbps != nil }
}
