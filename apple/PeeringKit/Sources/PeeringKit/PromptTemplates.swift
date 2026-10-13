import Foundation

/// Prompts the person saved to start a chat with, kept on this phone beside the built-in suggestions.
public struct PromptTemplates: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let text: String
    }

    public static let maximumCount = 12
    public static let maximumLength = 500

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Newest first. Blank text and a prompt already saved are ignored; the oldest gives way at the limit.
    @discardableResult
    public mutating func add(_ text: String, id: UUID = UUID()) -> Bool {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumLength))
        guard !trimmed.isEmpty, !entries.contains(where: { $0.text == trimmed }) else { return false }
        entries.insert(Entry(id: id, text: trimmed), at: 0)
        if entries.count > Self.maximumCount { entries.removeLast(entries.count - Self.maximumCount) }
        return true
    }

    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    private static let key = "Peering.promptTemplates"

    public static func load(from defaults: UserDefaults = .standard) -> PromptTemplates {
        guard let data = defaults.data(forKey: key),
              let loaded = try? JSONDecoder().decode(PromptTemplates.self, from: data)
        else { return PromptTemplates() }
        return loaded
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
