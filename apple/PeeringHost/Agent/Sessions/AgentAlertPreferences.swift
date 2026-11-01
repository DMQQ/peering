import Foundation

/// Which phones asked to be alerted only for decisions, kept on disk so a push decided while the phone is away still follows it.
final class AgentAlertPreferences: @unchecked Sendable {
    static let shared = AgentAlertPreferences()

    private static let key = "Peering.agentDecisionsOnlyClients"

    /// Guards `clients` and its write to the defaults, so an older snapshot cannot land after a newer one. UserDefaults takes no lock of ours.
    private let lock = NSLock()
    private var clients: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clients = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func decisionsOnly(for clientID: String) -> Bool {
        lock.withLock { clients.contains(clientID) }
    }

    func set(decisionsOnly: Bool, for clientID: String) {
        update { clients in
            if decisionsOnly { clients.insert(clientID) } else { clients.remove(clientID) }
        }
    }

    func forget(clientID: String) {
        update { $0.remove(clientID) }
    }

    func forgetAll() {
        update { $0.removeAll() }
    }

    private func update(_ change: (inout Set<String>) -> Void) {
        lock.withLock {
            var updated = clients
            change(&updated)
            guard updated != clients else { return }
            clients = updated
            defaults.set(updated.sorted(), forKey: Self.key)
        }
    }
}
