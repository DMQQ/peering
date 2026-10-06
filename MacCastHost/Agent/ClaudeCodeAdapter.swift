import Foundation
import MacCastKit
import RemoteCore

/// `--permission-prompt-tool stdio` routes permission prompts here as `can_use_tool` requests; without it the CLI denies tools needing approval itself and nothing reaches the phone.
final class ClaudeCodeAdapter: AgentAdapter, @unchecked Sendable {
    var onEvent: (@Sendable (AgentStreamEvent.Payload) -> Void)?
    var onModel: (@Sendable (String?) -> Void)?
    var onPermissionMode: (@Sendable (AgentPermissionMode) -> Void)?
    var onUsage: (@Sendable (AgentUsage) -> Void)?

    let permissionModes: [AgentPermissionMode] = [.manual, .acceptEdits]
    let defaultPermissionMode: AgentPermissionMode = .manual
    private var pendingModeRequest: String?
    private var pendingMode: AgentPermissionMode?

    private let directory: URL
    private let process = AgentProcess()
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.agent.claude")
    private var stream = AgentClaudeStream()
    private var stderrTail: [String] = []
    private var seenReady = false
    private var pendingText = ""
    private var flushScheduled = false
    private var pendingModelRequest: String?
    private var pendingModel: String?

    /// Delta batching window: a delta per API chunk would flood the shared channel and re-lay-out per token.
    private static let deltaFlushInterval: TimeInterval = 0.05
    private static let deltaFlushBytes = 4096

    static let command = "claude"

    init(directory: URL) {
        self.directory = directory
    }

    func start() throws {
        guard let binary = AgentEnvironment.shared.binary(named: Self.command) else {
            throw AgentLaunchFailure(
                message: "Claude Code is not installed on this Mac, or its command is not on the login shell's PATH."
            )
        }
        process.onLine = { [weak self] line in
            self?.queue.async { self?.consume(line) }
        }
        process.onStderrLine = { [weak self] line in
            self?.queue.async { self?.note(stderr: line) }
        }
        process.onExit = { [weak self] status in
            self?.queue.async { self?.ended(status) }
        }
        try process.start(AgentProcess.Launch(
            binary: binary,
            arguments: [
                "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--replay-user-messages",
                "--permission-prompt-tool", "stdio",
            ],
            directory: directory,
            environment: AgentEnvironment.shared.variables()
        ))
    }

    func prompt(_ text: String) {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
            "parent_tool_use_id": NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let line = String(data: data, encoding: .utf8)
        else { return }
        process.write(line: line)
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
            let response: [String: Any] = [
                "type": "control_response",
                "response": [
                    "subtype": "success",
                    "request_id": approvalID,
                    "response": body,
                ],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: response),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            self.process.write(line: line)
        }
    }

    func interrupt() {
        let request: [String: Any] = [
            "type": "control_request",
            "request_id": UUID().uuidString,
            "request": ["subtype": "interrupt"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8)
        else { return }
        process.write(line: line)
    }

    /// Confirmation is a control_response with the request id, handled in ``consume(_:)``; it carries the resolved model.
    func setModel(_ model: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            let requestID = UUID().uuidString
            self.pendingModelRequest = requestID
            self.pendingModel = model
            // Model omitted for "default", which the CLI reads as the session default.
            var body: [String: Any] = ["subtype": "set_model"]
            if let model { body["model"] = model }
            let request: [String: Any] = [
                "type": "control_request",
                "request_id": requestID,
                "request": body,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: request),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            self.process.write(line: line)
        }
    }

    func setPermissionMode(_ mode: AgentPermissionMode) {
        queue.async { [weak self] in
            guard let self, self.permissionModes.contains(mode) else { return }
            let requestID = UUID().uuidString
            self.pendingModeRequest = requestID
            self.pendingMode = mode
            let request: [String: Any] = [
                "type": "control_request",
                "request_id": requestID,
                "request": [
                    "subtype": "set_permission_mode",
                    "mode": mode == .acceptEdits ? "acceptEdits" : "default",
                ],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: request),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            self.process.write(line: line)
        }
    }

    func stop() {
        process.stop()
    }

    // MARK: - The queue

    private func consume(_ line: String) {
        if consumeModelResponse(line) || consumeModeResponse(line) { return }
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

    /// True when the line was the answer to a model change (own traffic, must not reach the transcript).
    private func consumeModelResponse(_ line: String) -> Bool {
        guard let requestID = pendingModelRequest,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              response["request_id"] as? String == requestID
        else { return false }

        pendingModelRequest = nil
        let asked = pendingModel
        pendingModel = nil
        if response["subtype"] as? String == "success" {
            let payload = response["response"] as? [String: Any]
            let resolved = payload?["model"] as? String
            onModel?(resolved ?? asked)
        } else {
            let message = (response["error"] as? String)
                ?? (response["response"] as? [String: Any])?["error"] as? String
                ?? "That model was not accepted."
            onEvent?(.notice(text: message))
        }
        return true
    }

    /// The answer to a mode change: this side's own traffic, kept out of the transcript.
    private func consumeModeResponse(_ line: String) -> Bool {
        guard let requestID = pendingModeRequest,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              response["request_id"] as? String == requestID
        else { return false }

        pendingModeRequest = nil
        let asked = pendingMode
        pendingMode = nil
        if response["subtype"] as? String == "success", let asked {
            onPermissionMode?(asked)
        } else {
            let message = (response["error"] as? String) ?? "That mode was not accepted."
            onEvent?(.notice(text: message))
        }
        return true
    }

    private func note(stderr line: String) {
        stderrTail.append(line)
        if stderrTail.count > 5 { stderrTail.removeFirst() }
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
