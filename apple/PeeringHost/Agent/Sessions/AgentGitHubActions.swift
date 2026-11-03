import Foundation
import PeeringKit
import RemoteCore

/// Answers ``AgentRequest/github(sessionID:)`` and ``AgentRequest/githubAction(sessionID:action:)`` with the Mac's own signed-in `gh`, so the phone never holds a GitHub token.
///
/// Every argument list comes from ``AgentGitHubReading``; this only runs them in the session's folder.
enum AgentGitHubActions {
    private static let readTimeout: TimeInterval = 30
    private static let actionTimeout: TimeInterval = 90
    private static let outputLimit = 256 * 1024

    private static let executable: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func read(directory: String, sessionID: UUID, sink: @escaping AgentSessionManager.Sink) {
        DispatchQueue.global(qos: .userInitiated).async {
            sink(.github(sessionID: sessionID, report: report(in: URL(fileURLWithPath: directory).standardizedFileURL)))
        }
    }

    static func perform(_ action: AgentGitHubAction, directory: String, sessionID: UUID, sink: @escaping AgentSessionManager.Sink) {
        DispatchQueue.global(qos: .userInitiated).async {
            let folder = URL(fileURLWithPath: directory).standardizedFileURL
            sink(.githubResult(sessionID: sessionID, result: result(of: action, in: folder)))
            sink(.github(sessionID: sessionID, report: report(in: folder)))
        }
    }

    private static func report(in folder: URL) -> AgentGitHubReport {
        guard executable != nil else { return .failure(AgentGitHubReading.missingMessage) }
        guard let branch = AgentChangesReader.branch(in: folder)?.head else {
            return .failure("This folder is not on a branch, so there is nothing to look up on GitHub.")
        }
        guard let pullRequestOutput = run(AgentGitHubReading.pullRequestArguments, in: folder, timeout: readTimeout) else {
            return .failure(AgentGitHubReading.missingMessage)
        }
        let pullRequest: AgentGitHubPullRequest?
        switch AgentGitHubReading.pullRequest(succeeded: pullRequestOutput.succeeded, output: pullRequestOutput.text) {
        case .problem(let problem): return .failure(problem)
        case .none: pullRequest = nil
        case .found(let found): pullRequest = found
        }
        var runs: [AgentGitHubRun] = []
        if let arguments = AgentGitHubReading.runArguments(branch: branch),
           let output = run(arguments, in: folder, timeout: readTimeout), output.succeeded {
            runs = AgentGitHubReading.runs(output: output.text)
        }
        return AgentGitHubReport(problem: nil, branch: branch, pullRequest: pullRequest, runs: runs)
    }

    private static func result(of action: AgentGitHubAction, in folder: URL) -> AgentGitHubResult {
        guard let arguments = AgentGitHubReading.arguments(for: action) else {
            return AgentGitHubResult(action: action, succeeded: false, message: "The Mac refused that request.")
        }
        guard let output = run(arguments, in: folder, timeout: actionTimeout) else {
            return AgentGitHubResult(action: action, succeeded: false, message: AgentGitHubReading.missingMessage)
        }
        return AgentGitHubReading.result(for: action, succeeded: output.succeeded, output: output.text)
    }

    private static func run(_ arguments: [String], in folder: URL, timeout: TimeInterval) -> AgentGitOutput? {
        guard let executable else { return nil }
        var environment = [
            // gh runs git and reads its token through /usr/bin/security.
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:/opt/local/bin",
            "HOME": NSHomeDirectory(),
            "GH_PROMPT_DISABLED": "1",
            "GH_NO_UPDATE_NOTIFIER": "1",
            "GH_SPINNER_DISABLED": "1",
            "NO_COLOR": "1",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = socket }
        guard let result = GroupProcess.run(
            executable: executable, arguments: arguments, directory: folder, environment: environment,
            mergeStandardError: true, outputLimit: outputLimit, timeout: timeout
        ) else { return nil }
        return AgentGitOutput(data: result.output, truncated: result.stopped, succeeded: result.status == 0 && !result.timedOut && !result.stopped)
    }
}
