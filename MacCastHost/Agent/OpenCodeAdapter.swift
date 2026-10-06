import Foundation
import MacCastKit
import os
import RemoteCore

private let agentLog = Logger(subsystem: "pl.dmq.peering.host", category: "agent")

/// OpenCode, one process per turn against a stored session.
///
/// The shape is the CLI's own: `opencode run --format json` runs a turn and exits, and the same
/// with `-s <session id>` runs the next one with the session's memory. Run mode has no approval
/// channel: without `--auto` a call that would need one (anything outside the folder) is
/// rejected by the CLI and reported as a failed tool, which is the safe direction and the one this
/// leaves it in. `--auto` is deliberately not passed.
///
/// The model is whatever the user's OpenCode configuration says unless the picker has been used,
/// when it is passed per turn as `-m provider/model`.
final class OpenCodeAdapter: AgentAdapter, @unchecked Sendable {
    var onEvent: (@Sendable (AgentStreamEvent.Payload) -> Void)?
    var onModel: (@Sendable (String?) -> Void)?

    private let directory: URL
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.agent.opencode")
    /// Read and written on ``queue`` only.
    private var stream: AgentOpenCodeStream
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
    /// The model the picker chose (`provider/model`), applied to every turn from here on. Nil runs
    /// the CLI's own configured default.
    private var model: String?

    static let command = "opencode"

    init(directory: URL) {
        self.directory = directory
        self.stream = AgentOpenCodeStream(directory: directory.path)
    }

    func start() throws {
        guard let binary = AgentEnvironment.shared.binary(named: Self.command) else {
            throw AgentLaunchFailure(
                message: "OpenCode is not installed on this Mac, or its command is not on the login shell's PATH."
            )
        }
        let waiting = queue.sync { () -> [String] in
            self.binary = binary
            let prompts = self.pendingPrompts
            self.pendingPrompts = []
            return prompts
        }
        agentLog.notice("opencode session ready · \(binary, privacy: .public) · \(waiting.count) prompt(s) waiting")
        for text in waiting {
            prompt(text)
        }
        // The session is the CLI's own; nothing else runs until a prompt does.
    }

    func prompt(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let binary = self.binary else {
                self.pendingPrompts.append(text)
                agentLog.notice("opencode prompt held: the session has not resolved its binary yet")
                return
            }
            guard self.turnProcess == nil else {
                self.onEvent?(.notice(text: "A turn is already running."))
                return
            }
            // `--` ahead of the text, because a prompt that begins with a dash would otherwise be
            // read as one of the CLI's own flags.
            var arguments = ["run", "--format", "json"]
            if let model = self.model { arguments += ["-m", model] }
            if let session = self.stream.cliSessionID { arguments += ["-s", session] }
            arguments += ["--", text]

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
                agentLog.notice("opencode turn spawned · \(arguments.prefix(3).joined(separator: " "), privacy: .public)…")
            } catch {
                agentLog.error("opencode could not start: \(String(describing: error), privacy: .public)")
                self.onEvent?(.failure(message: "OpenCode could not be started."))
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
        // Run mode has no approval channel: nothing here ever asked, so there is nothing to answer.
    }

    func interrupt() {
        queue.async { [weak self] in
            guard let self, let process = self.turnProcess else { return }
            self.interrupted = true
            // The session outlives the process, so stopping the turn is killing the turn's child:
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
            agentLog.notice("opencode first line: \(line.prefix(140), privacy: .public)")
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
        agentLog.notice("opencode turn process ended · status \(status) · finished \(self.turnFinished) · stderr \(self.stderrTail.count) line(s)")
        guard !turnFinished else { return }
        // A turn process that ends without its own ending is one that was stopped or crashed. The
        // thread is intact either way, so this is the turn's outcome and not the session's.
        if interrupted {
            onEvent?(.turnFinished(summary: AgentTurnSummary(ok: false, stopped: true)))
        } else {
            let tail = stderrTail.joined(separator: "\n")
            let message = "OpenCode exited with status \(status) before finishing the turn."
            onEvent?(.notice(text: tail.isEmpty ? message : "\(message)\n\(tail)"))
            onEvent?(.turnFinished(summary: AgentTurnSummary(ok: false)))
        }
    }
}
