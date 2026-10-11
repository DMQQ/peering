import Foundation

/// The chat or shell the person had open last, so the home screen can offer it again in one tap.
public struct LastActivity: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case chat
        case terminal
    }

    public let kind: Kind
    public let id: UUID
    public let hostID: String
    public let title: String
    public let openedAt: Date

    public init(kind: Kind, id: UUID, hostID: String, title: String, openedAt: Date) {
        self.kind = kind
        self.id = id
        self.hostID = hostID
        self.title = title
        self.openedAt = openedAt
    }

    /// Three days: past that it is a different piece of work, and the Mac has likely closed it.
    public static let freshness: TimeInterval = 3 * 24 * 3600

    public func isFresh(at now: Date) -> Bool {
        now.timeIntervalSince(openedAt) < Self.freshness
    }

    private static let key = "Peering.lastActivity"

    public static func load(from defaults: UserDefaults = .standard) -> LastActivity? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LastActivity.self, from: data)
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// A chat or shell that was closed is not worth offering: only its own record is cleared.
    public static func clear(_ id: UUID, from defaults: UserDefaults = .standard) {
        guard load(from: defaults)?.id == id else { return }
        defaults.removeObject(forKey: key)
    }
}
