import Foundation
import MacCastKit
import RemoteCore

/// Answers ``AgentRequest/commit(sessionID:paths:message:)`` and ``AgentRequest/push(sessionID:)`` in the session's own folder.
///
/// Every decision about what to run is in ``AgentGitCommit`` and ``AgentGitPush``; this runs the lists they return and never builds one itself. Nothing here touches git's configuration, passes `--no-verify`, or names a refspec of its own.
enum AgentGitActions {
    private static let timeout: TimeInterval = 90
    private static let outputLimit = 64 * 1024

    static func commit(
        directory: String, sessionID: UUID, paths: [String], message: String, sink: @escaping AgentSessionManager.Sink
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let folder = URL(fileURLWithPath: directory).standardizedFileURL
            let result = commitResult(in: folder, paths: paths, message: message)
            finish(result, in: folder, sessionID: sessionID, sink: sink)
        }
    }

    static func push(directory: String, sessionID: UUID, sink: @escaping AgentSessionManager.Sink) {
        DispatchQueue.global(qos: .userInitiated).async {
            let folder = URL(fileURLWithPath: directory).standardizedFileURL
            finish(pushResult(in: folder), in: folder, sessionID: sessionID, sink: sink)
        }
    }

    private static func finish(_ result: AgentGitResult, in folder: URL, sessionID: UUID, sink: AgentSessionManager.Sink) {
        sink(.gitResult(sessionID: sessionID, result: result))
        sink(.changes(sessionID: sessionID, report: AgentChangesReader.report(for: folder)))
    }

    private static func commitResult(in folder: URL, paths: [String], message: String) -> AgentGitResult {
        let plan: AgentGitCommitPlan
        switch AgentGitCommit.plan(paths: paths, message: message) {
        case .failure(let reason): return AgentGitOutcome.refused(.commit, reason)
        case .success(let built): plan = built
        }
        if let escaping = paths.first(where: { !staysInside(folder, path: $0) }) {
            return AgentGitOutcome.refused(.commit, .unsafePath(escaping))
        }
        guard let staged = AgentGitRunner.run(plan.stage, in: folder, limit: outputLimit, timeout: timeout, writes: true) else {
            return AgentGitResult(operation: .commit, succeeded: false, message: AgentGitLocator.missingMessage)
        }
        guard staged.succeeded else {
            return AgentGitOutcome.result(operation: .commit, succeeded: false, output: staged.text)
        }
        guard let committed = AgentGitRunner.run(plan.commit, in: folder, limit: outputLimit, timeout: timeout, writes: true) else {
            return AgentGitResult(operation: .commit, succeeded: false, message: AgentGitLocator.missingMessage)
        }
        return AgentGitOutcome.result(operation: .commit, succeeded: committed.succeeded, output: committed.text)
    }

    private static func pushResult(in folder: URL) -> AgentGitResult {
        guard let branch = AgentChangesReader.branch(in: folder) else {
            return AgentGitResult(operation: .push, succeeded: false, message: "This folder is not in a git repository.")
        }
        let arguments: [String]
        switch AgentGitPush.arguments(for: branch) {
        case .failure(let reason): return AgentGitOutcome.refused(.push, reason)
        case .success(let built): arguments = built
        }
        guard let output = AgentGitRunner.run(arguments, in: folder, limit: outputLimit, timeout: timeout, writes: true) else {
            return AgentGitResult(operation: .push, succeeded: false, message: AgentGitLocator.missingMessage)
        }
        return AgentGitOutcome.result(operation: .push, succeeded: output.succeeded, output: output.text)
    }

    /// The path's folder, with links followed, is still under the session's folder. The file itself may be gone (a deletion) or be a link, which git stores as a link.
    private static func staysInside(_ folder: URL, path: String) -> Bool {
        let root = folder.resolvingSymlinksInPath().path + "/"
        let parent = folder.appendingPathComponent(path).deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        return parent.hasPrefix(root)
    }
}
