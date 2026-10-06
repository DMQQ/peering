import SwiftUI

struct TerminalAgent: Identifiable, Hashable {
    let id: String
    let name: String
    let command: String
    let symbol: String
    /// Whether this agent can also be driven in its structured mode, which is what the native
    /// chat screen needs. Not a plan question: the two agents without it simply have no chat,
    /// on any plan, and their rows draw no chat button at all.
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
