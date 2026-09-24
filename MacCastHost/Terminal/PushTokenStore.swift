import Foundation

/// The APNs tokens phones have registered with this Mac, kept across a restart of it.
///
/// **On disk, because a token only ever arrives while a session is up.** A Mac that has quit and
/// relaunched cannot be given one again until that phone next connects, and until then a shell that
/// stops reaches nobody with nothing logged at either end.
///
/// Shared rather than owned by the terminal manager, because it has two writers: the manager writes a
/// token as a phone registers, and the device list clears one when a phone is forgotten.
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

    /// Every token this Mac holds, whether or not the phone that gave it is connected.
    func tokensByClient() -> [String: String] {
        lock.withLock { tokens }
    }

    /// Stores a token, or forgets the phone when `token` is `nil`.
    ///
    /// `nil` rather than an empty string: the push path tests for existence, and a stored `""` would be
    /// handed to the relay as a device nobody can reach.
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
