import Foundation

/// The mode last chosen for each Mac, and whether to ask again on every connect.
public struct SessionModeMemory {
    public enum Decision: Equatable, Sendable {
        case open(SessionMode)
        case ask
    }

    private static let askEveryTimeKey = PreferenceKeys.asksSessionModeOnConnect
    private static let keyPrefix = "Peering.sessionMode."

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var asksEveryTime: Bool {
        get { defaults.bool(forKey: Self.askEveryTimeKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.askEveryTimeKey) }
    }

    public func remembered(for hostID: String) -> SessionMode? {
        defaults.string(forKey: Self.keyPrefix + hostID).flatMap(SessionMode.init(rawValue:))
    }

    public func remember(_ mode: SessionMode, for hostID: String) {
        defaults.set(mode.rawValue, forKey: Self.keyPrefix + hostID)
    }

    /// For a Mac this device forgets: its remembered mode and its pinned apps.
    public func forget(_ hostID: String) {
        defaults.removeObject(forKey: Self.keyPrefix + hostID)
        ApplicationFavourites(hostID: hostID, defaults: defaults).clear()
    }

    /// Asks the first time for a Mac, and whenever the person asked to be asked; a remembered mode the Mac cannot offer any more asks again.
    public func decision(for hostID: String?, available: [SessionMode]) -> Decision {
        guard let hostID, !asksEveryTime, let mode = remembered(for: hostID), available.contains(mode) else { return .ask }
        return .open(mode)
    }
}
