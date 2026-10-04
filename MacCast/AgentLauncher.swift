import SwiftUI

struct TerminalAgent: Identifiable {
    let id: String
    let name: String
    let command: String
    let symbol: String

    static let all: [TerminalAgent] = [
        TerminalAgent(id: "claude", name: "Claude Code", command: "claude", symbol: "sparkles"),
        TerminalAgent(id: "codex", name: "Codex", command: "codex", symbol: "chevron.left.forwardslash.chevron.right"),
        TerminalAgent(id: "opencode", name: "OpenCode", command: "opencode", symbol: "curlybraces"),
        TerminalAgent(id: "hermes", name: "Hermes", command: "hermes", symbol: "paperplane"),
        TerminalAgent(id: "gemini", name: "Gemini CLI", command: "gemini", symbol: "diamond"),
        TerminalAgent(id: "aider", name: "Aider", command: "aider", symbol: "wand.and.stars"),
    ]
}
