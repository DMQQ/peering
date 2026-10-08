import Foundation
import RemoteCore

public struct SlashSuggestion: Identifiable, Equatable {
    public enum Kind: Int, Sendable {
        /// Handled by this app, never sent: it opens one of its own screens.
        case app
        /// Typed to the CLI, which runs it even without a terminal.
        case builtin
        case command
        case skill
    }

    /// What the hint says under the name. Wording belongs to the app, which owns the translations.
    public enum Detail: Equatable, Sendable {
        case usage, model, rename, compact, clear
        case thisProject, yours
    }

    public let name: String
    public let detail: Detail
    public let kind: Kind

    public var id: String { name }

    public init(name: String, detail: Detail, kind: Kind) {
        self.name = name
        self.detail = detail
        self.kind = kind
    }
}

/// What can be typed after a `/` at the start of a message. The CLI runs a command or a skill from its text alone, so the hints are names read off the Mac's own folders, plus the few built-ins that work without a terminal and the ones this app answers itself.
public enum AgentSlash {
    /// What follows the slash, while the draft is still one word.
    public static func query(_ draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    /// The Mac user's home, read off the project's own path: the phone is not told it.
    public static func home(of project: String) -> String? {
        let parts = project.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Users" else { return nil }
        return "/Users/" + parts[1]
    }

    /// The folders a Claude Code command or skill can live in, the project's first because it wins.
    public static func folders(project: String, agentID: String) -> [String] {
        guard agentID == "claude" else { return [] }
        let base = project.hasSuffix("/") ? String(project.dropLast()) : project
        var result = [base + "/.claude/commands", base + "/.claude/skills"]
        if let home = home(of: project) {
            result += [home + "/.claude/commands", home + "/.claude/skills"]
        }
        return result
    }

    public static func suggestions(
        for typed: String,
        agentID: String,
        project: String,
        offersUsage: Bool,
        offersModel: Bool,
        listing: (String) -> [RemoteDirectoryEntry]?
    ) -> [SlashSuggestion] {
        var found: [SlashSuggestion] = []
        if offersUsage {
            found.append(SlashSuggestion(name: "usage", detail: .usage, kind: .app))
        }
        if offersModel {
            found.append(SlashSuggestion(name: "model", detail: .model, kind: .app))
        }
        found.append(SlashSuggestion(name: "rename", detail: .rename, kind: .app))
        if agentID == "claude" {
            found.append(SlashSuggestion(name: "compact", detail: .compact, kind: .builtin))
            found.append(SlashSuggestion(name: "clear", detail: .clear, kind: .builtin))
        }
        for folder in folders(project: project, agentID: agentID) {
            guard let entries = listing(folder) else { continue }
            let isSkill = folder.hasSuffix("/skills")
            let scope: SlashSuggestion.Detail = folder.hasPrefix(project) ? .thisProject : .yours
            for entry in entries where !entry.name.hasPrefix(".") {
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
