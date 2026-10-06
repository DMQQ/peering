import SwiftUI

struct TerminalAgent: Identifiable, Hashable {
    let id: String
    let name: String
    let command: String
    let symbol: String
    let supportsChat: Bool

    static let all: [TerminalAgent] = [
        TerminalAgent(id: "claude", name: "Claude Code", command: "claude", symbol: "sparkles", supportsChat: true),
        TerminalAgent(id: "codex", name: "Codex", command: "codex", symbol: "chevron.left.forwardslash.chevron.right", supportsChat: true),
        TerminalAgent(id: "opencode", name: "OpenCode", command: "opencode", symbol: "curlybraces", supportsChat: true),
        TerminalAgent(id: "hermes", name: "Hermes", command: "hermes", symbol: "paperplane", supportsChat: false),
        TerminalAgent(id: "gemini", name: "Gemini CLI", command: "gemini", symbol: "diamond", supportsChat: false),
        TerminalAgent(id: "aider", name: "Aider", command: "aider", symbol: "wand.and.stars", supportsChat: false),
    ]
}
