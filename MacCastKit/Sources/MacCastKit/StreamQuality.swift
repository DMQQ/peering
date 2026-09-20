import Foundation
import RemoteCore

/// A preset for the picture's bitrate, or the app's own choice of one.
///
/// **The raw value is a storage token and not the word on screen**, which costs a `RawValue`
/// written out by hand and buys the setting being safe to persist. It used to be
/// `enum StreamQuality: String` with `"Auto"`, `"Low"`, `"Med"`, `"High"`, and the chip
/// printed `rawValue` directly — fine while nothing stored it. `@AppStorage` persists the raw
/// value, so that spelling would have keyed a saved preference on UI copy: "Med" is an
/// abbreviation chosen for a chip that shares a row with four other controls, and the day
/// somebody reconsiders it, every stored preference fails to decode and silently resets to
/// automatic. The token is `init?(rawValue:)`-decoded rather than force-read so that an
/// unknown one is distinguishable from a real answer — the same shape, for the same reason,
/// as ``InteractionMode``.
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
    /// `auto` is not the fourth rung of this ladder, it is the other answer to the same
    /// question — let the app choose the rate, or choose it yourself. ``SettingsPanel``
    /// shows it that way, as one mode and then three levels, and it asks for this list
    /// rather than spelling the three out so that adding a case here cannot leave the
    /// picker behind.
    public static let manualCases: [StreamQuality] = allCases.filter { $0 != .auto }

    /// The same three numbers as ``AutoQualityPolicy/Tier``, and the same source for them:
    /// `Low` here is exactly what the host caps a stream at when the picture is on the
    /// control channel, so a preset that named a different figure would read on screen as
    /// a setting that does not take.
    public var bitrateKbps: Int? {
        switch self {
        case .auto: return nil
        case .low: return VideoQualityTier.low.rawValue
        case .medium: return VideoQualityTier.medium.rawValue
        case .high: return VideoQualityTier.high.rawValue
        }
    }

    /// What the status chip prints, abbreviated for the row it sits in.
    ///
    /// This is what ``rawValue`` used to be, and it is the only reason the two were ever the
    /// same string. The chip shares its row with the path, the fit and the camera, so the
    /// names are clipped to fit it — see ``title`` and ``menuTitle`` for the roomier
    /// spellings.
    public var chipTitle: String {
        switch self {
        case .auto: return "Auto"
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        }
    }

    /// The name spelled out, for somewhere with more room than the status chip.
    ///
    /// ``chipTitle`` is what the chip prints, abbreviated to "Auto" and "Med" because that
    /// chip shares a row with four other controls. A settings row has the width of the
    /// panel and no such excuse.
    public var title: String {
        switch self {
        case .auto: return "Automatic"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// The name and what it costs, for a menu that has to say what is being given up.
    ///
    /// The figure is the whole point of it: "Low" and "Medium" mean nothing to somebody who
    /// has not already learned this app's ladder, and the choice being made is how much of
    /// the connection to spend on the picture. Shared by the status chip's menu
    /// (``RemoteScreen``) and the Settings tab, so the two cannot come to describe the same
    /// four presets differently.
    public var menuTitle: String {
        switch self {
        case .auto: return "Auto, follows the network"
        case .low: return "Low, 2 Mbps"
        case .medium: return "Medium, 8 Mbps"
        case .high: return "High, 20 Mbps"
        }
    }

    /// The preset that names a given automatic tier.
    ///
    /// For handing the rate over: whatever the policy had settled on is where a manual
    /// choice should start, and the two enums share their numbers through
    /// ``bitrateKbps`` but not their cases.
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
    /// **Failable decoding on purpose**: an absent or unrecognised token means "nothing has been
    /// stored yet", which is ``StreamQuality/auto``: the behaviour the app had before the setting
    /// existed. A force-read would make a token from a future version read as a choice somebody
    /// made, and a token the app once wrote but no longer recognises is the case
    /// ``init?(rawValue:)`` exists to catch: the raw values used to be the words on screen, so
    /// anything stored under the old spelling decodes to nothing and starts over at automatic
    /// rather than silently becoming a different preset.
    ///
    /// The defaults are a parameter so that the rule can be exercised without writing to the real
    /// store: a test that has to save and restore `UserDefaults.standard` is a test that fails
    /// when another one runs beside it.
    public static func stored(in defaults: UserDefaults = .standard) -> StreamQuality {
        defaults.string(forKey: PreferenceKeys.streamQuality)
            .flatMap(StreamQuality.init(rawValue:)) ?? .auto
    }

    /// The level to come back to when the rate is taken over by hand again, or `nil` for automatic.
    ///
    /// `nil` is the right answer for a stored ``StreamQuality/auto``: there is no manual level to
    /// come back to, and the policy's current tier stands in. See `setAutomaticQuality(_:)`.
    public static func storedManualLevel(in defaults: UserDefaults = .standard) -> StreamQuality? {
        let stored = stored(in: defaults)
        return stored.isManual ? stored : nil
    }

    /// Whether this preset names a rate, which is the same question as whether it is ``auto``.
    public var isManual: Bool { bitrateKbps != nil }
}
