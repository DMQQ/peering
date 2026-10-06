import Foundation

/// The APNs tokens phones have registered with this Mac, kept across a restart of it.
final class PushTokenStore: @unchecked Sendable {
    static let shared = PushTokenStore()

    private static let key = "Peering.pushTokens"

    private let lock = NSLock()
    private var tokens: [String: String]

    init() {
        tokens = Self.load()
    }

    /// One phone's token, or `nil` for a phone that has never registered or has asked to be forgotten.
    func token(for clientID: String) -> String? {
        lock.withLock { tokens[clientID] }
    }

    func tokensByClient() -> [String: String] {
        lock.withLock { tokens }
    }

    func set(_ token: String?, for clientID: String) {
        let updated = lock.withLock { () -> [String: String] in
            tokens[clientID] = token
            return tokens
        }
        Self.save(updated)
    }

    func forget(clientID: String) {
        set(nil, for: clientID)
    }

    func forgetAll() {
        let emptied = lock.withLock { () -> [String: String] in
            tokens = [:]
            return tokens
        }
        Self.save(emptied)
    }

    private static func load() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ tokens: [String: String]) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
