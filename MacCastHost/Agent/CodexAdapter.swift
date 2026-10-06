import Foundation
import MacCastKit
import os
import RemoteCore

private let agentLog = Logger(subsystem: "pl.dmq.peering.host", category: "agent")

/// Exec mode has no approval channel (a CLI fact): the session's sandbox constrains it. The model is passed per turn with `-c model=` only after the picker is used.
final class CodexAdapter: AgentAdapter, @unchecked Sendable {
    var onEvent: (@Sendable (AgentStreamEvent.Payload) -> Void)?
    var onModel: (@Sendable (String?) -> Void)?
    var onPermissionMode: (@Sendable (AgentPermissionMode) -> Void)?

    /// Exec mode cannot ask, so the sandbox is all there is to choose: the folder, or everywhere.
    let permissionModes: [AgentPermissionMode] = [.acceptEdits, .auto]
    let defaultPermissionMode: AgentPermissionMode = .acceptEdits
    private var permissionMode: AgentPermissionMode = .acceptEdits

    private let directory: URL
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.agent.codex")
    private var stream: AgentCodexStream
    private var binary: String?
    /// Prompts that beat the login shell resolving the binary are queued, not dropped.
    private var pendingPrompts: [String] = []
    private var turnProcess: AgentProcess?
    private var turnFinished = false
    private var interrupted = false
    private var loggedFirstLine = false
    private var stderrTail: [String] = []
    private var model: String?

    static let command = "codex"

    init(directory: URL) {
        self.directory = directory
        self.stream = AgentCodexStream(directory: directory.path)
    }

    func start() throws {
        guard let binary = AgentEnvironment.shared.binary(named: Self.command) else {
            throw AgentLaunchFailure(
                message: "Codex is not installed on this Mac, or its command is not on the login shell's PATH."
            )
        }
        let waiting = queue.sync { () -> [String] in
            self.binary = binary
            let prompts = self.pendingPrompts
            self.pendingPrompts = []
            return prompts
        }
        agentLog.notice("codex session ready · \(binary, privacy: .public) · \(waiting.count) prompt(s) waiting")
        for text in waiting {
            prompt(text)
        }
    }

    func prompt(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let binary = self.binary else {
                self.pendingPrompts.append(text)
                agentLog.notice("codex prompt held: the session has not resolved its binary yet")
                return
            }
            guard self.turnProcess == nil else {
                self.onEvent?(.notice(text: "A turn is already running."))
                return
            }
            // A resume names the thread only: this CLI refuses to re-take sandbox or folder, and the working directory is how it finds the thread.
            var arguments: [String] = []
            // Before the subcommand, where global overrides go, so one pair serves first turn and resume.
            if let model = self.model { arguments += ["-c", "model=\(model)"] }
            let sandbox = self.permissionMode == .auto ? "danger-full-access" : "workspace-write"
            // A resume refuses `--sandbox`, so it is set through config, which it accepts.
            if self.stream.cliSessionID != nil { arguments += ["-c", "sandbox_mode=\"\(sandbox)\""] }
            arguments += ["exec"]
            if let thread = self.stream.cliSessionID {
                arguments += ["resume", "--skip-git-repo-check", "--json", thread, text]
            } else {
                arguments += [
                    "--json", "--sandbox", sandbox, "--skip-git-repo-check",
                    "--cd", self.directory.path, text,
                ]
            }

            let process = AgentProcess()
            self.stderrTail = []
            self.turnFinished = false
            self.interrupted = false
            self.loggedFirstLine = false
            process.onLine = { [weak self] line in
                self?.queue.async { self?.consume(line) }
            }
            process.onStderrLine = { [weak self] line in
                self?.queue.async {
                    guard let self else { return }
                    self.stderrTail.append(line)
                    if self.stderrTail.count > 5 { self.stderrTail.removeFirst() }
                }
            }
            process.onExit = { [weak self] status in
                self?.queue.async { self?.turnEnded(status) }
            }
            do {
                try process.start(AgentProcess.Launch(
                    binary: binary,
                    arguments: arguments,
                    directory: self.directory,
                    environment: AgentEnvironment.shared.variables(),
                    input: .null
                ))
                self.turnProcess = process
                agentLog.notice("codex turn spawned · \(arguments.prefix(3).joined(separator: " "), privacy: .public)…")
            } catch {
                agentLog.error("codex could not start: \(String(describing: error), privacy: .public)")
                self.onEvent?(.failure(message: "Codex could not be started."))
                self.onEvent?(.turnFinished(summary: AgentTurnSummary(ok: false)))
            }
        }
    }

    /// Applies to the next turn; a turn is a process, so the running one is unchanged.
    func setModel(_ model: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.model = model
            self.onModel?(model)
        }
    }

    func setPermissionMode(_ mode: AgentPermissionMode) {
        queue.async { [weak self] in
            guard let self, self.permissionModes.contains(mode) else { return }
            self.permissionMode = mode
            self.onPermissionMode?(mode)
        }
    }

    func respond(approvalID: String, decision: AgentApprovalDecision) {
    }

    func interrupt() {
        queue.async { [weak self] in
            guard let self, let process = self.turnProcess else { return }
            self.interrupted = true
            process.stop()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.turnProcess?.stop()
        }
    }

    // MARK: - The queue

    private func consume(_ line: String) {
        if !loggedFirstLine {
            loggedFirstLine = true
            agentLog.notice("codex first line: \(line.prefix(140), privacy: .public)")
        }
        let payloads = stream.receive(line: line)
        for payload in payloads {
            if case .turnFinished = payload { turnFinished = true }
            onEvent?(payload)
        }
    }

    private func turnEnded(_ status: Int32) {
        guard turnProcess != nil else { return }
        turnProcess = nil
        agentLog.notice("codex turn process ended · status \(status) · finished \(self.turnFinished) · stderr \(self.stderrTail.count) line(s)")
        guard !turnFinished else { return }
        if interrupted {
            onEvent?(.turnFinished(summary: AgentTurnSummary(ok: false, stopped: true)))
        } else {
            let tail = stderrTail.joined(separator: "\n")
            let message = "Codex exited with status \(status) before finishing the turn."
            onEvent?(.notice(text: tail.isEmpty ? message : "\(message)\n\(tail)"))
            onEvent?(.turnFinished(summary: AgentTurnSummary(ok: false)))
        }
    }
}
