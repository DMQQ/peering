import Foundation

/// How one file differs from the last commit.
public enum AgentChangeKind: String, Codable, Equatable, Sendable {
    case modified, added, deleted
    /// Not tracked by git yet: the whole file is new.
    case untracked
}

/// One file `git` reports as changed under a session's folder.
public struct AgentChangedFile: Codable, Equatable, Sendable {
    /// Relative to the session's folder, with `/` separators.
    public let path: String
    public let kind: AgentChangeKind
    public let added: Int
    public let removed: Int
    /// A unified diff of this file alone, cut short when it is large. Nil for a file with no text to show (binary).
    public let diff: String?

    public init(path: String, kind: AgentChangeKind, added: Int, removed: Int, diff: String?) {
        self.path = path
        self.kind = kind
        self.added = added
        self.removed = removed
        self.diff = diff
    }
}

/// What the Mac found under a session's folder: the project's files and which of them differ from git's last commit.
public struct AgentChangesReport: Codable, Equatable, Sendable {
    /// False when the folder is not inside a git work tree, or git could not run; ``message`` says which.
    public let isRepository: Bool
    public let files: [AgentChangedFile]
    /// Every file git knows or would add (tracked and untracked, ignored ones left out), relative to the folder, capped.
    public let paths: [String]
    /// Set when ``files`` or ``paths`` was cut at its limit.
    public let truncated: Bool
    public let message: String?
    /// The branch the folder is on, for the commit and push actions; nil when it could not be read.
    public let branch: AgentGitBranch?

    public init(
        isRepository: Bool, files: [AgentChangedFile], paths: [String], truncated: Bool,
        message: String? = nil, branch: AgentGitBranch? = nil
    ) {
        self.isRepository = isRepository
        self.files = files
        self.paths = paths
        self.truncated = truncated
        self.message = message
        self.branch = branch
    }

    public static func failure(_ message: String) -> AgentChangesReport {
        AgentChangesReport(isRepository: false, files: [], paths: [], truncated: false, message: message)
    }
}

public enum AgentChangePath {
    /// Whether a path git reported stays inside the folder it was asked about: relative, with no `..` and no empty or NUL-bearing component.
    public static func isInsideFolder(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }
}
