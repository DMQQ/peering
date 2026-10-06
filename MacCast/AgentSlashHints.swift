import RemoteCore
import SwiftUI

struct SlashSuggestion: Identifiable, Equatable {
    enum Kind: Int {
        /// Handled by this app, never sent: it opens one of its own screens.
        case app
        /// Typed to the CLI, which runs it even without a terminal.
        case builtin
        case command
        case skill
    }

    let name: String
    let detail: String
    let kind: Kind

    var id: String { name }

    var symbol: String {
        switch kind {
        case .app: return "iphone"
        case .builtin: return "command"
        case .command: return "slash.circle"
        case .skill: return "wand.and.stars"
        }
    }

    var tag: LocalizedStringKey {
        switch kind {
        case .app: return "In Peering"
        case .builtin: return "Built in"
        case .command: return "Command"
        case .skill: return "Skill"
        }
    }
}

/// What can be typed after a `/` at the start of a message. The CLI runs a command or a skill from its text alone, so the hints are names read off the Mac's own folders, plus the few built-ins that work without a terminal and the ones this app answers itself.
enum AgentSlash {
    /// What follows the slash, while the draft is still one word.
    static func query(_ draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    /// The Mac user's home, read off the project's own path: the phone is not told it.
    static func home(of project: String) -> String? {
        let parts = project.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Users" else { return nil }
        return "/Users/" + parts[1]
    }

    /// The folders a Claude Code command or skill can live in, the project's first because it wins.
    static func folders(project: String, agentID: String) -> [String] {
        guard agentID == "claude" else { return [] }
        let base = project.hasSuffix("/") ? String(project.dropLast()) : project
        var result = [base + "/.claude/commands", base + "/.claude/skills"]
        if let home = home(of: project) {
            result += [home + "/.claude/commands", home + "/.claude/skills"]
        }
        return result
    }

    static func suggestions(
        for typed: String,
        agentID: String,
        project: String,
        offersUsage: Bool,
        offersModel: Bool,
        listing: (String) -> RemoteDirectory?
    ) -> [SlashSuggestion] {
        var found: [SlashSuggestion] = []
        if offersUsage {
            found.append(SlashSuggestion(name: "usage", detail: String(localized: "Open usage and limits"), kind: .app))
        }
        if offersModel {
            found.append(SlashSuggestion(name: "model", detail: String(localized: "Choose the model"), kind: .app))
        }
        found.append(SlashSuggestion(name: "rename", detail: String(localized: "Rename this chat"), kind: .app))
        if agentID == "claude" {
            found.append(SlashSuggestion(name: "compact", detail: String(localized: "Summarise the conversation to free up context"), kind: .builtin))
            found.append(SlashSuggestion(name: "clear", detail: String(localized: "Start over with an empty context"), kind: .builtin))
        }
        for folder in folders(project: project, agentID: agentID) {
            guard let directory = listing(folder) else { continue }
            let isSkill = folder.hasSuffix("/skills")
            let scope = folder.hasPrefix(project) ? String(localized: "This project") : String(localized: "Yours")
            for entry in directory.entries where !entry.name.hasPrefix(".") {
                if isSkill, entry.isDirectory {
                    found.append(SlashSuggestion(name: entry.name, detail: scope, kind: .skill))
                } else if !isSkill, !entry.isDirectory, entry.name.hasSuffix(".md") {
                    found.append(SlashSuggestion(name: String(entry.name.dropLast(3)), detail: scope, kind: .command))
                }
            }
        }
        var seen: Set<String> = []
        let lowered = typed.lowercased()
        return found
            .filter { seen.insert($0.name).inserted }
            .filter { typed.isEmpty || $0.name.localizedStandardContains(typed) }
            .sorted { lhs, rhs in
                let leftStarts = lhs.name.lowercased().hasPrefix(lowered)
                let rightStarts = rhs.name.lowercased().hasPrefix(lowered)
                if leftStarts != rightStarts { return leftStarts }
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

/// The suggestions with what each one does.
struct AgentSlashList: View {
    let items: [SlashSuggestion]
    let pick: (SlashSuggestion) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text("Nothing matches")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(14)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 46) }
                    Button { pick(item) } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: "/" + item.name)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ColorPalette.ink)
                                    .lineLimit(1)
                                Text(verbatim: item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(item.tag)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 264)
        .background(ColorPalette.backdrop, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.14))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}
