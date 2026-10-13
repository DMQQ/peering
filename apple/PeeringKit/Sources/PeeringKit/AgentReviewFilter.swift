import Foundation
import RemoteCore

/// Which changed files the review list counts and shows. Hidden files are not pending: they never reach the card's totals.
public struct AgentReviewFilter: Codable, Equatable, Sendable {
    /// Any path component starting with a dot (.skills, .claude, .git, .build).
    public var hidesHiddenFolders = true
    public var showsUntracked = true
    public var kinds: Set<AgentChangeKind> = [.modified, .added, .deleted, .untracked]
    /// Only the Changes screen can apply it: it needs the chat's transcript, which To review does not read.
    public var onlyAgentEdited = false
    /// Paths containing any of these (ignoring case) are hidden.
    public private(set) var hiddenPatterns: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case hidesHiddenFolders, showsUntracked, kinds, onlyAgentEdited, hiddenPatterns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hidesHiddenFolders = try container.decodeIfPresent(Bool.self, forKey: .hidesHiddenFolders) ?? true
        showsUntracked = try container.decodeIfPresent(Bool.self, forKey: .showsUntracked) ?? true
        kinds = try container.decodeIfPresent(Set<AgentChangeKind>.self, forKey: .kinds) ?? kinds
        onlyAgentEdited = try container.decodeIfPresent(Bool.self, forKey: .onlyAgentEdited) ?? false
        hiddenPatterns = try container.decodeIfPresent([String].self, forKey: .hiddenPatterns) ?? []
    }

    public var isDefault: Bool { self == AgentReviewFilter() }

    /// Whether the filter is at rest for a screen that cannot apply the agent-edited rule.
    public var isDefaultIgnoringAgentRule: Bool {
        var copy = self
        copy.onlyAgentEdited = false
        return copy.isDefault
    }

    /// To review's rule: the agent-edited setting does not apply there, so it is not consulted.
    public func shows(_ file: AgentChangedFile) -> Bool {
        shows(path: file.path, kind: file.kind)
    }

    public func shows(_ file: AgentChangedFile, editedByAgent: Bool) -> Bool {
        shows(file) && (!onlyAgentEdited || editedByAgent)
    }

    /// A file only the transcript knows of has no kind, so the kind rules leave it alone.
    public func shows(_ entry: AgentChangeEntry) -> Bool {
        shows(path: entry.path, kind: entry.kind) && (!onlyAgentEdited || entry.editedByAgent)
    }

    /// An unchanged file in the project tree: only the path rules (and the agent rule, which no untouched file meets) apply.
    public func showsUnchanged(path: String) -> Bool {
        !onlyAgentEdited && shows(path: path, kind: nil)
    }

    private func shows(path: String, kind: AgentChangeKind?) -> Bool {
        if let kind {
            if !kinds.contains(kind) { return false }
            if kind == .untracked && !showsUntracked { return false }
        }
        if hidesHiddenFolders && Self.hasHiddenComponent(path) { return false }
        return !hiddenPatterns.contains { path.localizedCaseInsensitiveContains($0) }
    }

    /// The screen's search box, separate because it narrows a list without changing what counts as pending.
    public static func matches(_ file: AgentChangedFile, search: String) -> Bool {
        matches(path: file.path, search: search)
    }

    public static func matches(path: String, search: String) -> Bool {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || path.localizedCaseInsensitiveContains(term)
    }

    public mutating func addPattern(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hiddenPatterns.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        hiddenPatterns.append(trimmed)
    }

    public mutating func removePattern(_ pattern: String) {
        hiddenPatterns.removeAll { $0 == pattern }
    }

    public mutating func toggle(_ kind: AgentChangeKind) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
    }

    static func hasHiddenComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }
}
