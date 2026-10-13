import Foundation
import PeeringKit
import RemoteCore

/// Exec mode has no approval channel (a CLI fact): the session's sandbox constrains it. The model is passed per turn with `-c model=` only after the picker is used.
final class CodexAdapter: PerTurnAdapter, @unchecked Sendable {
    private var stream: AgentCodexStream
    private var logPath: URL?

    override class var command: String { "codex" }
    override class var displayName: String { "Codex" }

    override init(directory: URL, resume: AgentResume?) {
        stream = AgentCodexStream(directory: directory.path, cliSessionID: resume?.cliSessionID)
        super.init(directory: directory, resume: resume)
    }

    override func arguments(for text: String) -> [String] {
        // A resume names the thread only: this CLI refuses to re-take sandbox or folder, and the working directory is how it finds the thread.
        var arguments: [String] = []
        // Before the subcommand, where global overrides go, so one pair serves first turn and resume.
        if let model { arguments += ["-c", "model=\(model)"] }
        let sandbox = permissionMode == .auto ? "danger-full-access" : "workspace-write"
        // A resume refuses `--sandbox`, so it is set through config, which it accepts.
        if stream.cliSessionID != nil { arguments += ["-c", "sandbox_mode=\"\(sandbox)\""] }
        arguments += ["exec"]
        if let thread = stream.cliSessionID {
            arguments += ["resume", "--skip-git-repo-check", "--json", thread, text]
        } else {
            arguments += ["--json", "--sandbox", sandbox, "--skip-git-repo-check", "--cd", directory.path, text]
        }
        return arguments
    }

    override func receive(line: String) -> [AgentStreamEvent.Payload] {
        stream.receive(line: line)
    }

    /// The session log knows the context and the limits, and by the time the process has ended it
    /// has been written; the turn reports are the fallback when it cannot be found.
    override func turnProcessEnded() {
        var usage = stream.usage
        if let thread = stream.cliSessionID,
           let logged = CodexSessionLogFile.usage(thread: thread, knownPath: &logPath) {
            usage = logged
        }
        onUsage?(usage)
    }
}
