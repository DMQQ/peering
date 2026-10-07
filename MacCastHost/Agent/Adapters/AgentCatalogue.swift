import Foundation

/// The agents a phone can chat with: one entry per CLI, so adding one is adding a line here.
enum AgentCatalogue {
    struct Entry: Sendable {
        let id: String
        let name: String
        let make: @Sendable (URL, AgentResume?) -> any AgentAdapter
    }

    static let entries: [Entry] = [
        Entry(id: ClaudeCodeAdapter.command, name: "Claude Code") { ClaudeCodeAdapter(directory: $0, resume: $1) },
        Entry(id: CodexAdapter.command, name: "Codex") { CodexAdapter(directory: $0, resume: $1) },
        Entry(id: OpenCodeAdapter.command, name: "OpenCode") { OpenCodeAdapter(directory: $0, resume: $1) },
    ]

    static func entry(for id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    static var names: [String: String] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.name) })
    }
}
