import Foundation
import RemoteCore

/// What the phone remembers for the spending guard: each chat's cap, and which limit warnings it has already given.
public struct AgentGuardStore {
    private static let capsKey = "Peering.agentSpendingCaps"
    private static let warningsKey = "Peering.agentLimitWarningsGiven"
    private static let dismissedKey = "Peering.agentLimitWarningsDismissed"
    /// Two warnings a window and a window every five hours: this covers days.
    private static let keptWarnings = 40

    private let defaults: UserDefaults
    private let hostKey: String?

    /// Caps are kept per Mac, since each prunes against only its own chats; without a host they are the unkeyed caps of older builds.
    public init(defaults: UserDefaults = .standard, hostKey: String? = nil) {
        self.defaults = defaults
        self.hostKey = hostKey
    }

    private var capsKey: String { hostKey.map { "\(Self.capsKey).\($0)" } ?? Self.capsKey }

    public func caps() -> [UUID: AgentSpendingCap] {
        var caps = Self.decodedCaps(defaults.data(forKey: capsKey))
        if hostKey != nil {
            for (id, cap) in Self.decodedCaps(defaults.data(forKey: Self.capsKey)) where caps[id] == nil { caps[id] = cap }
        }
        return caps
    }

    private static func decodedCaps(_ data: Data?) -> [UUID: AgentSpendingCap] {
        guard let data, let stored = try? JSONDecoder().decode([String: AgentSpendingCap].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, cap in UUID(uuidString: key).map { ($0, cap) } })
    }

    private func write(_ caps: [UUID: AgentSpendingCap], forKey key: String) throws {
        let encoded = Dictionary(uniqueKeysWithValues: caps.map { ($0.key.uuidString, $0.value) })
        defaults.set(try JSONEncoder().encode(encoded), forKey: key)
    }

    public func cap(for id: UUID) -> AgentSpendingCap? {
        caps()[id]
    }

    /// An empty cap is the same as none, and is removed.
    public func setCap(_ cap: AgentSpendingCap?, for id: UUID) throws {
        var stored = Self.decodedCaps(defaults.data(forKey: capsKey))
        stored[id] = cap?.isEmpty == false ? cap : nil
        try write(stored, forKey: capsKey)
        if hostKey != nil { try moveOutOfUnkeyed([id]) }
    }

    /// Drops the caps of chats this Mac no longer lists, and takes over the unkeyed caps of chats it does.
    public func keepCaps(only ids: Set<UUID>) throws {
        let kept = caps().filter { ids.contains($0.key) }
        try write(kept, forKey: capsKey)
        if hostKey != nil { try moveOutOfUnkeyed(ids) }
    }

    private func moveOutOfUnkeyed(_ ids: Set<UUID>) throws {
        let unkeyed = Self.decodedCaps(defaults.data(forKey: Self.capsKey))
        guard unkeyed.keys.contains(where: ids.contains) else { return }
        try write(unkeyed.filter { !ids.contains($0.key) }, forKey: Self.capsKey)
    }

    public var givenWarnings: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.warningsKey) ?? []) }
        nonmutating set { defaults.set(Array(newValue.sorted().suffix(Self.keptWarnings)), forKey: Self.warningsKey) }
    }

    /// Warnings the person closed in a chat, so the banner stays down for that threshold and window.
    public var dismissedWarnings: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.dismissedKey) ?? []) }
        nonmutating set { defaults.set(Array(newValue.sorted().suffix(Self.keptWarnings)), forKey: Self.dismissedKey) }
    }
}
