import Foundation
import os

private let quickCommandLog = Logger(subsystem: "pl.dmq.peering", category: "ssh")

/// A command the user runs often enough to want one tap away.
///
/// Deliberately *not* the app's existing `Macro`, which looks like the same idea and is not: a
/// `Macro` is a macOS virtual keycode plus modifiers, because it is replayed into a Mac through the
/// session's input channel. `keyCode 37` means "the L key" on a Mac and nothing at all to a Linux
/// box. One type covering both would have every call site handling a case that can never arrive
/// there, and would put an SSH concept into the Mac input path in `RemoteCore`, where the host also
/// has to read it.
public struct SSHQuickCommand: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var command: String

    public init(id: UUID = UUID(), title: String, command: String) {
        self.id = id
        self.title = title
        self.command = command
    }

    /// What a chip shows when the user did not give it a name. The first word of the command is
    /// what they think of it as, and a chip reading `docker` is more use than one reading "Command".
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        let firstWord = command.split(separator: " ").first.map(String.init) ?? command
        return firstWord.isEmpty ? "Command" : firstWord
    }
}

/// The quick commands, saved whole — the same JSON-blob-in-`UserDefaults` shape as the host list.
public struct SSHQuickCommandStore: Sendable {
    public static let key = "Peering.sshQuickCommands"

    // `UserDefaults` is not `Sendable` — it is a mutable reference type — but it is
    // documented as thread-safe, and the alternative is dropping `Sendable` from a store whose
    // only job is to hand a value to a main-actor model and take one back.
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
