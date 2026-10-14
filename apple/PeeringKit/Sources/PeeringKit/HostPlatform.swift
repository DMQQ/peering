import Foundation

/// What the computer on the other end runs. The sentences for a connected host are written for a Mac;
/// ``adapt(_:)`` swaps the one noun, which is safe in every language the app ships because Mac and PC
/// share a gender and an article wherever the language has them.
public enum HostPlatform: String, Sendable, Equatable {
    case mac = "macos"
    case windows

    /// `nil` is a Mac from before the hello named its platform. An unknown name is also taken for a Mac, the wording the app always had.
    public init(wireName: String?) {
        self = wireName.flatMap(Self.init(rawValue:)) ?? .mac
    }

    public func adapt(_ text: String) -> String {
        switch self {
        case .mac: text
        case .windows: text.replacing(/\bMac(s?)\b/) { "PC\($0.output.1)" }
        }
    }
}

/// The platform each paired host last announced. A connection that fails before the hello still has to say PC or Mac.
public struct HostPlatformMemory {
    private let defaults: UserDefaults
    private let key = "hostPlatforms"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func platform(forHostID hostID: String?) -> HostPlatform {
        guard let hostID else { return .mac }
        return HostPlatform(wireName: (defaults.dictionary(forKey: key) as? [String: String])?[hostID])
    }

    public func remember(_ platform: HostPlatform, forHostID hostID: String) {
        var known = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        guard known[hostID] != platform.rawValue else { return }
        known[hostID] = platform.rawValue
        defaults.set(known, forKey: key)
    }
}
