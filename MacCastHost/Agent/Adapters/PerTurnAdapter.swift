import Foundation
import MacCastKit
import os
import RemoteCore

private let agentLog = Logger(subsystem: "pl.dmq.peering.host", category: "agent")

/// The shared half of a CLI that runs one process per turn and resumes its thread by id (Codex, OpenCode).
///
/// A subclass names its CLI, builds the arguments for a turn and turns its output lines into events.
class PerTurnAdapter: AgentAdapter, @unchecked Sendable {
    var onEvent: (@Sendable (AgentStreamEvent.Payload) -> Void)?
    var onModel: (@Sendable (String?) -> Void)?
    var onPermissionMode: (@Sendable (AgentPermissionMode) -> Void)?
    var onUsage: (@Sendable (AgentUsage) -> Void)?

    /// Run and exec mode cannot ask, so the sandbox is all there is to choose: the folder, or everywhere.
    let permissionModes: [AgentPermissionMode] = [.acceptEdits, .auto]
    let defaultPermissionMode: AgentPermissionMode = .acceptEdits

    let directory: URL
    /// Every property below is touched on this queue only.
    let queue: DispatchQueue
    private(set) var binary: String?
    private(set) var model: String?
    private(set) var permissionMode: AgentPermissionMode

    private var pendingPrompts: [String] = []
    private var turnProcess: AgentProcess?
    private var turnFinished = false
    private var interrupted = false
    private var loggedFirstLine = false
    private var stderrTail: [String] = []

    class var command: String { fatalError("subclasses name their CLI") }
    class var displayName: String { fatalError("subclasses name their CLI") }

    init(directory: URL, resume: AgentResume?) {
        self.directory = directory
        model = resume?.model
        permissionMode = resume?.permissionMode ?? .acceptEdits
        queue = DispatchQueue(label: "pl.dmq.peering.host.agent.\(Self.command)")
    }

    // MARK: - For subclasses

    /// The arguments for one turn, after the binary. Runs on the queue.
    func arguments(for text: String) -> [String] { [] }

    /// Runs on the queue.
    func receive(line: String) -> [AgentStreamEvent.Payload] { [] }

    /// A turn's process has ended and its events are all in; the place to report usage. Runs on the queue.
    func turnProcessEnded() {}

    // MARK: - AgentAdapter

    func start() throws {
        let name = Self.displayName
        guard let binary = AgentEnvironment.shared.binary(named: Self.command) else {
            throw AgentLaunchFailure(
                message: "\(name) is not installed on this Mac, or its command is not on the login shell's PATH."
            )
        }
        let waiting = queue.sync { () -> [String] in
            self.binary = binary
            let prompts = self.pendingPrompts
            self.pendingPrompts = []
            return prompts
        }
        agentLog.notice("\(Self.command, privacy: .public) session ready · \(binary, privacy: .public) · \(waiting.count) prompt(s) waiting")
        for text in waiting {
            prompt(text)
        }
    }

    func prompt(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let command = Self.command
            guard let binary = self.binary else {
                self.pendingPrompts.append(text)
                agentLog.notice("\(command, privacy: .public) prompt held: the session has not resolved its binary yet")
                return
            }
            guard self.turnProcess == nil else {
                self.onEvent?(.notice(text: "A turn is already running."))
                return
            }

            let arguments = self.arguments(for: text)
            let process = AgentProcess()
            self.stderrTail = []
            self.turnFinished = false
            self.interrupted = false
            self.loggedFirstLine = false
            process.onLine = { [weak self] line in
                self?.queue.async { [weak self] in self?.consume(line) }
            }
            process.onStderrLine = { [weak self] line in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.stderrTail.append(line)
                    if self.stderrTail.count > 12 { self.stderrTail.removeFirst() }
                }
            }
            process.onDiscardedLine = { [weak self] in
                self?.queue.async { [weak self] in
                    self?.onEvent?(.notice(text: "A line from the agent was too long to read and was skipped."))
                }
            }
            process.onExit = { [weak self] status in
                self?.queue.async { [weak self] in self?.turnEnded(status) }
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
                agentLog.notice("\(command, privacy: .public) turn spawned · \(arguments.prefix(3).joined(separator: " "), privacy: .public)…")
            } catch {
                agentLog.error("\(command, privacy: .public) could not start: \(String(describing: error), privacy: .public)")
                self.onEvent?(.failure(message: "\(Self.displayName) could not be started."))
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

    /// There is no approval channel to answer.
    func respond(approvalID: String, decision: AgentApprovalDecision) {}

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
            agentLog.notice("\(Self.command, privacy: .public) first line: \(line.prefix(140), privacy: .public)")
        }
        for payload in receive(line: line) {
            if case .turnFinished = payload { turnFinished = true }
            onEvent?(payload)
        }
    }

    private func turnEnded(_ status: Int32) {
        guard turnProcess != nil else { return }
        turnProcess = nil
        turnProcessEnded()
        agentLog.notice("\(Self.command, privacy: .public) turn process ended · status \(status) · finished \(self.turnFinished) · stderr \(self.stderrTail.count) line(s)")
        guard !turnFinished else { return }
        if interrupted {
            onEvent?(.turnFinished(summary: AgentTurnSummary(ok: false, stopped: true)))
        } else {
            let tail = stderrTail.joined(separator: "\n")
            let message = "\(Self.displayName) exited with status \(status) before finishing the turn."
            onEvent?(.notice(text: tail.isEmpty ? message : "\(message)\n\(tail)"))
            onEvent?(.turnFinished(summary: AgentTurnSummary(ok: false)))
        }
    }
}
