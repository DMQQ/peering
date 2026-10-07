import Foundation
import MacCastKit
import RemoteCore

/// `--permission-prompt-tool stdio` routes permission prompts here as `can_use_tool` requests; without it the CLI denies tools needing approval itself and nothing reaches the phone.
final class ClaudeCodeAdapter: AgentAdapter, @unchecked Sendable {
    var onEvent: (@Sendable (AgentStreamEvent.Payload) -> Void)?
    var onModel: (@Sendable (String?) -> Void)?
    var onPermissionMode: (@Sendable (AgentPermissionMode) -> Void)?
    var onUsage: (@Sendable (AgentUsage) -> Void)?

    let permissionModes: [AgentPermissionMode] = [.manual, .acceptEdits, .plan]
    let defaultPermissionMode: AgentPermissionMode = .manual

    private let directory: URL
    private let resume: AgentResume?
    private let process = AgentProcess()
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.agent.claude")
    private var stream = AgentClaudeStream()
    private var requests = AgentControlRequests()
    private var stderrTail: [String] = []
    private var seenReady = false
    private var currentMode: AgentPermissionMode
    private var modeBeforePlan: AgentPermissionMode = .manual
    private var planApprovals: Set<String> = []
    private var pendingText = ""
    private var flushScheduled = false

    /// Delta batching window: a delta per API chunk would flood the shared channel and re-lay-out per token.
    private static let deltaFlushInterval: TimeInterval = 0.05
    private static let deltaFlushBytes = 4096

    static let command = "claude"

    init(directory: URL, resume: AgentResume?) {
        self.directory = directory
        self.resume = resume
        currentMode = resume?.permissionMode ?? .manual
    }

    func start() throws {
        guard let binary = AgentEnvironment.shared.binary(named: Self.command) else {
            throw AgentLaunchFailure(
                message: "Claude Code is not installed on this Mac, or its command is not on the login shell's PATH."
            )
        }
        process.onLine = { [weak self] line in
            self?.queue.async { [weak self] in self?.consume(line) }
        }
        process.onStderrLine = { [weak self] line in
            self?.queue.async { [weak self] in self?.note(stderr: line) }
        }
        process.onDiscardedLine = { [weak self] in
            self?.queue.async { [weak self] in
                self?.onEvent?(.notice(text: "A line from the agent was too long to read and was skipped."))
            }
        }
        process.onExit = { [weak self] status in
            self?.queue.async { [weak self] in self?.ended(status) }
        }
        try process.start(AgentProcess.Launch(
            binary: binary,
            arguments: launchArguments(),
            directory: directory,
            environment: AgentEnvironment.shared.variables()
        ))
    }

    /// A restart names the CLI's own session, so its context comes back; model and mode are put back with it.
    private func launchArguments() -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--replay-user-messages",
            "--permission-prompt-tool", "stdio",
        ]
        if let id = resume?.cliSessionID { arguments += ["--resume", id] }
        if let model = resume?.model { arguments += ["--model", model] }
        if let mode = resume?.permissionMode, mode != .manual { arguments += ["--permission-mode", mode.claudeCLIName] }
        return arguments
    }

    func prompt(_ text: String) {
        send(["type": "user", "message": ["role": "user", "content": text], "parent_tool_use_id": NSNull()])
    }

    func respond(approvalID: String, decision: AgentApprovalDecision) {
        queue.async { [weak self] in
            guard let self else { return }
            // Echoed back on an allow; absent after a replay, when the CLI no longer holds the ask.
            let input = self.stream.takeApprovalInput(approvalID) ?? [:]
            let body: [String: Any]
            switch decision {
            case .allow:
                body = ["behavior": "allow", "updatedInput": input]
            case .deny:
                body = ["behavior": "deny", "message": "Denied from Peering."]
            case .choose(let label):
                // A question ask is answered by an allow whose input carries the answers keyed by question text (verified on Claude Code 2.1.289); otherwise the question comes back.
                var updated = input
                if let questions = input["questions"] as? [[String: Any]],
                   let question = questions.first?["question"] as? String {
                    updated["answers"] = [question: label]
                }
                body = ["behavior": "allow", "updatedInput": updated]
            }
            self.send([
                "type": "control_response",
                "response": ["subtype": "success", "request_id": approvalID, "response": body],
            ])
            // Approving the plan ends plan mode, and the CLI does not say what it falls back to.
            if self.planApprovals.remove(approvalID) != nil, case .allow = decision {
                self.applyMode(self.modeBeforePlan)
            }
        }
    }

    func interrupt() {
        queue.async { [weak self] in
            guard let self, let line = self.requests.make(subtype: "interrupt") else { return }
            self.process.write(line: line)
        }
    }

    /// Confirmation is a control_response with the request id; it carries the resolved model.
    func setModel(_ model: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            // Model omitted for "default", which the CLI reads as the session default.
            let fields: [String: Any] = model.map { ["model": $0] } ?? [:]
            self.control("set_model", fields) { [weak self] outcome in
                switch outcome {
                case .success(let body):
                    self?.onModel?((body?["model"] as? String) ?? model)
                case .failure(let message):
                    self?.onEvent?(.notice(text: message ?? "That model was not accepted."))
                }
            }
        }
    }

    func setPermissionMode(_ mode: AgentPermissionMode) {
        queue.async { [weak self] in
            guard let self, self.permissionModes.contains(mode) else { return }
            self.applyMode(mode)
        }
    }

    /// Runs on the queue.
    private func applyMode(_ mode: AgentPermissionMode) {
        control("set_permission_mode", ["mode": mode.claudeCLIName]) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success:
                if mode == .plan, self.currentMode != .plan { self.modeBeforePlan = self.currentMode }
                self.currentMode = mode
                self.onPermissionMode?(mode)
            case .failure(let message):
                self.onEvent?(.notice(text: message ?? "That mode was not accepted."))
            }
        }
    }

    func stop() {
        process.stop()
    }

    // MARK: - Writing

    private func send(_ object: [String: Any]) {
        guard let line = AgentControlRequests.encode(object) else { return }
        process.write(line: line)
    }

    private func control(_ subtype: String, _ fields: [String: Any], completion: @escaping (AgentControlRequests.Outcome) -> Void) {
        guard let line = requests.make(subtype: subtype, fields: fields, completion: completion) else { return }
        process.write(line: line)
    }

    // MARK: - The queue

    private func consume(_ line: String) {
        if requests.resolve(line: line) { return }
        let payloads = stream.receive(line: line)
        for payload in payloads {
            if case .textDelta(let text) = payload {
                pendingText += text
                if pendingText.utf8.count >= Self.deltaFlushBytes {
                    flushText()
                } else {
                    scheduleFlush()
                }
                continue
            }
            flushText()
            if case .sessionReady = payload { seenReady = true }
            if case .approvalRequested(let id, let call, _) = payload, call.name == "ExitPlanMode" { planApprovals.insert(id) }
            if case .turnFinished = payload { onUsage?(stream.usage) }
            onEvent?(payload)
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.deltaFlushInterval) { [weak self] in
            self?.flushText()
        }
    }

    private func flushText() {
        flushScheduled = false
        guard !pendingText.isEmpty else { return }
        let text = pendingText
        pendingText = ""
        onEvent?(.textDelta(text: text))
    }

    private func note(stderr line: String) {
        stderrTail.append(line)
        if stderrTail.count > 12 { stderrTail.removeFirst() }
    }

    private func ended(_ status: Int32) {
        flushText()
        // A session that died before hello is a CLI too old for these flags or unauthenticated; its last words are the user's sentence.
        if !seenReady || status != 0 {
            let tail = stderrTail.joined(separator: "\n")
            let message = seenReady
                ? "Claude Code exited with status \(status)."
                : "Claude Code started and stopped before saying anything. Update it, or use the terminal instead."
            onEvent?(.failure(message: tail.isEmpty ? message : "\(message)\n\(tail)"))
        }
        onEvent?(.sessionExited(status: status))
    }
}

struct AgentLaunchFailure: Error {
    let message: String
}
