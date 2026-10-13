import Foundation
import PeeringKit
import RemoteCore

/// Answers ``AgentRequest/changes(sessionID:)``: the session's folder as git sees it.
///
/// The folder is the session's own, never one the phone names, so there is no path to refuse on the way in. What git prints on the way out is checked instead: a path that is not relative to the folder, or that resolves outside it through a link, is dropped.
enum AgentChangesReader {
    static let maximumPaths = 5_000
    static let maximumChangedFiles = 300
    static let maximumUntrackedFiles = 100
    static let maximumUntrackedBytes = 200 * 1024

    static func read(directory: String, sessionID: UUID, sink: @escaping AgentSessionManager.Sink) {
        DispatchQueue.global(qos: .userInitiated).async {
            sink(.changes(sessionID: sessionID, report: report(for: URL(fileURLWithPath: directory).standardizedFileURL)))
        }
    }

    static func report(for directory: URL) -> AgentChangesReport {
        guard let probe = AgentGitRunner.run(["rev-parse", "--is-inside-work-tree"], in: directory, limit: 64) else {
            return .failure(AgentGitLocator.missingMessage)
        }
        guard probe.succeeded, probe.text.hasPrefix("true") else {
            return .failure("This folder is not in a git repository, so only the agent's own edits are listed.")
        }
        let tracked = names(["ls-files", "-z", "--cached"], in: directory)
        let untracked = names(["ls-files", "-z", "--others", "--exclude-standard"], in: directory)
        let patch = trackedPatch(in: directory)

        var files = AgentGitDiff.files(in: patch.text).filter { AgentChangePath.isInsideFolder($0.path) }
        var truncated = patch.truncated || tracked.truncated || untracked.truncated || files.count > maximumChangedFiles
        files = Array(files.prefix(maximumChangedFiles))
        let newFiles = untracked.names.prefix(maximumUntrackedFiles).map { path in
            AgentGitDiff.untracked(path: path, content: text(ofFileAt: path, in: directory))
        }
        truncated = truncated || untracked.names.count > maximumUntrackedFiles
        files = (files + newFiles).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var paths = Array(NSOrderedSet(array: tracked.names + untracked.names)) as? [String] ?? []
        if paths.count > maximumPaths {
            paths = Array(paths.prefix(maximumPaths))
            truncated = true
        }
        return AgentChangesReport(isRepository: true, files: files, paths: paths, truncated: truncated, branch: branch(in: directory))
    }

    static func branch(in directory: URL) -> AgentGitBranch? {
        guard let status = AgentGitRunner.run(["status", "--porcelain=v2", "--branch", "--untracked-files=no"], in: directory, limit: 64 * 1024),
              status.succeeded,
              let parsed = AgentGitPush.branch(statusHeaders: status.text, remote: nil, mergeRef: nil)
        else { return nil }
        guard let head = parsed.head else { return parsed }
        let remote = configured("branch.\(head).remote", in: directory)
        let mergeRef = configured("branch.\(head).merge", in: directory)
        return AgentGitPush.branch(statusHeaders: status.text, remote: remote, mergeRef: mergeRef)
    }

    private static func configured(_ key: String, in directory: URL) -> String? {
        guard let output = AgentGitRunner.run(["config", "--get", key], in: directory, limit: 1024), output.succeeded else { return nil }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Against the last commit, so staged and unstaged edits both show; a repository with no commit yet has nothing to compare against and shows what is staged.
    private static func trackedPatch(in directory: URL) -> AgentGitOutput {
        let options = ["--relative", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "-U3"]
        let limit = 4 * 1024 * 1024
        if let head = AgentGitRunner.run(["diff", "HEAD"] + options, in: directory, limit: limit), head.succeeded {
            return head
        }
        return AgentGitRunner.run(["diff", "--cached"] + options, in: directory, limit: limit)
            ?? AgentGitOutput(data: Data(), truncated: false, succeeded: false)
    }

    private static func names(_ arguments: [String], in directory: URL) -> (names: [String], truncated: Bool) {
        guard let output = AgentGitRunner.run(arguments, in: directory, limit: 2 * 1024 * 1024), output.succeeded else {
            return ([], false)
        }
        let parts = output.text.split(separator: "\0").map(String.init).filter(AgentChangePath.isInsideFolder)
        // A cut list ends mid-name.
        return (output.truncated ? Array(parts.dropLast()) : parts, output.truncated)
    }

    /// Nil for a file that is binary, too odd to read, or that a link points out of the folder.
    private static func text(ofFileAt path: String, in directory: URL) -> String? {
        let root = directory.resolvingSymlinksInPath().path + "/"
        let file = directory.appendingPathComponent(path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumUntrackedBytes), !data.contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
