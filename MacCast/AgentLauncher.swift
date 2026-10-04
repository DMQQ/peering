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

struct AgentGrid: View {
    var launch: (TerminalAgent) -> Void

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(TerminalAgent.all) { agent in
                Button { launch(agent) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: agent.symbol)
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 24)
                        Text(verbatim: agent.name)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.18))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: agent.name))
            }
        }
    }
}

struct AgentStrip: View {
    var launch: (TerminalAgent) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TerminalAgent.all) { agent in
                    Button { launch(agent) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: agent.symbol)
                                .font(.system(size: 12, weight: .medium))
                            Text(verbatim: agent.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: agent.name))
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 44)
    }
}
