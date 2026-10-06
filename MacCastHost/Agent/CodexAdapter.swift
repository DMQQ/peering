import Foundation
import MacCastKit
import os
import RemoteCore

private let agentLog = Logger(subsystem: "pl.dmq.peering.host", category: "agent")

/// Codex, one process per turn against a stored thread.
///
/// The shape is the CLI's own: `codex exec --json` runs a turn and exits, and `codex exec resume
/// <thread_id> --json` runs the next one with the thread's memory. Exec mode has no approval
/// channel at all, which is a fact about the CLI rather than a choice made here: the sandbox the
/// session was created with is what constrains it, and the UI says so rather than drawing a
/// permission bar that could never fill.
///
/// The model is whatever the user's Codex configuration says, exactly as in their terminal,
/// unless the picker has been used: then it is passed per turn with `-c model=…`, because a turn
/// is a process and this CLI takes its model at spawn. A configuration whose model the account
/// refuses fails with the API's own sentence rather than being second-guessed here.
final class CodexAdapter: AgentAdapter, @unchecked Sendable {
    var onEvent: (@Sendable (AgentStreamEvent.Payload) -> Void)?
    var onModel: (@Sendable (String?) -> Void)?

    private let directory: URL
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.agent.codex")
    /// Read and written on ``queue`` only.
    private var stream: AgentCodexStream
    private var binary: String?
    /// Prompts that arrived before ``start()`` resolved the binary. A chat's first prompt can beat
    /// the login shell that is still resolving where Codex lives, and a prompt dropped by that
    /// race is a session that sits silent forever while nothing was ever wrong.
    private var pendingPrompts: [String] = []
    private var turnProcess: AgentProcess?
    private var turnFinished = false
    private var interrupted = false
    private var loggedFirstLine = false
    private var stderrTail: [String] = []
    /// The model the picker chose, applied to every turn from here on. Nil runs the CLI's own
    /// configured default.
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
        // The session is the thread; nothing else runs until a prompt does.
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
            // A resume names the thread and nothing else: this CLI refuses to re-take the sandbox
            // or the folder on a resume, and both were fixed when the first turn created the
            // thread. The process's own working directory is still the session's, which is also
            // how resume finds the thread.
            var arguments: [String] = []
            // Before the subcommand, where this CLI's global overrides go, so the same pair works
            // for a first turn and for a resume.
            if let model = self.model { arguments += ["-c", "model=\(model)"] }
            arguments += ["exec"]
            if let thread = self.stream.cliSessionID {
                arguments += ["resume", "--skip-git-repo-check", "--json", thread, text]
            } else {
                arguments += [
                    "--json", "--sandbox", "workspace-write", "--skip-git-repo-check",
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

    /// Takes the model for the *next* turn. A turn is a process here, so nothing about the one
    /// already running changes — which is what the picker says while it spins.
    func setModel(_ model: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.model = model
            self.onModel?(model)
        }
    }

    func respond(approvalID: String, decision: AgentApprovalDecision) {
        // Exec mode has no approval channel: nothing here ever asked, so there is nothing to answer.
    }

    func interrupt() {
        queue.async { [weak self] in
            guard let self, let process = self.turnProcess else { return }
            self.interrupted = true
            // The thread outlives the process, so stopping the turn is killing the turn's child:
            // the next prompt resumes the same conversation.
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
        // A turn process that ends without its own ending is one that was stopped or crashed. The
        // thread is intact either way, so this is the turn's outcome and not the session's.
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
