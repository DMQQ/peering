import Foundation
import RemoteCore

/// Why a commit request was refused before git was asked anything.
public enum AgentGitRefusal: Error, Equatable, Sendable {
    case noFiles, tooManyFiles, emptyMessage, messageTooLong, unsafePath(String)
    case detachedHead, noUpstream, unsafeBranch, unsafeRemote

    public var text: String {
        switch self {
        case .noFiles: "Choose at least one file to commit."
        case .tooManyFiles: "That is too many files for one commit from the phone."
        case .emptyMessage: "A commit needs a message."
        case .messageTooLong: "That commit message is too long."
        case .unsafePath(let path): "\(path) is not a file inside this folder."
        case .detachedHead: "This folder is not on a branch (detached HEAD), so there is nothing to push."
        case .noUpstream: "This branch has no upstream. Set one on the Mac, then push from here."
        case .unsafeBranch: "This branch's name is not one the phone will push."
        case .unsafeRemote: "This branch's remote is not one the phone will push to."
        }
    }
}

/// The two git runs a commit takes, built only from values that passed the checks below.
public struct AgentGitCommitPlan: Equatable, Sendable {
    public let stage: [String]
    public let commit: [String]
}

/// Argument lists for committing chosen files. No flag the user or the phone supplies ever reaches git as an option: paths follow `--`, and the message is the value of `-m`.
public enum AgentGitCommit {
    public static let maximumFiles = 1_000
    public static let maximumMessageLength = 5_000

    public static func plan(paths: [String], message: String) -> Result<AgentGitCommitPlan, AgentGitRefusal> {
        let unique = Array(NSOrderedSet(array: paths)) as? [String] ?? paths
        guard !unique.isEmpty else { return .failure(.noFiles) }
        guard unique.count <= maximumFiles else { return .failure(.tooManyFiles) }
        if let bad = unique.first(where: { !isCommittable($0) }) { return .failure(.unsafePath(bad)) }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyMessage) }
        guard text.count <= maximumMessageLength, !text.contains("\0") else { return .failure(.messageTooLong) }
        // Literal, so a name that looks like a pathspec (`:(glob)*`) is a file name and nothing wider.
        return .success(AgentGitCommitPlan(
            stage: ["--literal-pathspecs", "add", "--"] + unique,
            commit: ["--literal-pathspecs", "commit", "-m", text, "--"] + unique
        ))
    }

    /// Inside the folder, and not git's own directory.
    public static func isCommittable(_ path: String) -> Bool {
        guard AgentChangePath.isInsideFolder(path), !path.contains("\n") else { return false }
        return !path.split(separator: "/").contains { $0.lowercased() == ".git" }
    }
}

/// The options that could rewrite or widen what a push does. Nothing built here may contain one.
public enum AgentGitForbidden {
    static let flags: Set<String> = [
        "--force", "-f", "--force-with-lease", "--force-if-includes", "--delete", "-d", "--mirror",
        "--all", "--tags", "--prune", "--no-verify", "--follow-tags", "--atomic", "--receive-pack", "--exec",
    ]

    /// Whether any option-shaped argument (before a `--`, and not a `-m` value) is on the list or a refspec forces.
    public static func appears(in arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return false }
            if argument == "-m" { index += 2; continue }
            if flags.contains(argument) || argument.hasPrefix("--force") || argument.hasPrefix("+") || argument.contains(":+") {
                return true
            }
            index += 1
        }
        return false
    }
}
