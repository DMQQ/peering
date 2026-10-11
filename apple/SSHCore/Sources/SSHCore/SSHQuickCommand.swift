import Foundation
import os

private let quickCommandLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// Deliberately not `Macro`, which is a macOS virtual keycode plus modifiers replayed into a Mac (`keyCode 37` means nothing to a Linux box); one type for both would leak an SSH concept into the Mac input path in `RemoteCore`.
public struct SSHQuickCommand: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var command: String

    public init(id: UUID = UUID(), title: String, command: String) {
        self.id = id
        self.title = title
        self.command = command
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        let firstWord = command.split(separator: " ").first.map(String.init) ?? command
        return firstWord.isEmpty ? "Command" : firstWord
    }
}

/// The quick commands, saved whole as a JSON blob in `UserDefaults`.
public struct SSHQuickCommandStore: Sendable {
    public static let key = "Peering.sshQuickCommands"

    // `UserDefaults` is not `Sendable` but is documented thread-safe.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [SSHQuickCommand] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        do {
            return try JSONDecoder().decode([SSHQuickCommand].self, from: data)
        } catch {
            quickCommandLog.error("could not read quick commands: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    public func save(_ commands: [SSHQuickCommand]) {
        do {
            defaults.set(try JSONEncoder().encode(commands), forKey: Self.key)
        } catch {
            quickCommandLog.error("could not save quick commands: \(String(describing: error), privacy: .public)")
        }
    }
}
