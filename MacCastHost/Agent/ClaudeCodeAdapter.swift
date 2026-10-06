import Foundation
import MacCastKit
import RemoteCore

/// One long-lived Claude Code process, spoken to in its stream-json dialect.
///
/// The invocation is the one the SDK itself uses (`-p --input-format stream-json --output-format
/// stream-json --verbose --include-partial-messages --replay-user-messages
/// --permission-prompt-tool stdio`), with one detail worth keeping: `--permission-prompt-tool
/// stdio` is what routes permission prompts to this side as `can_use_tool` control requests. A
/// run without it does not refuse to ask, it answers itself: a tool needing approval is denied
/// with a sentence about needing approval, and nothing ever reaches the phone.
final class ClaudeCodeAdapter: AgentAdapter, @unchecked Sendable {
    var onEvent: (@Sendable (AgentStreamEvent.Payload) -> Void)?
    var onModel: (@Sendable (String?) -> Void)?

    private let directory: URL
    private let process = AgentProcess()
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.agent.claude")
    /// Read and written on ``queue`` only.
    private var stream = AgentClaudeStream()
    private var stderrTail: [String] = []
    private var seenReady = false
    /// Text deltas waiting to be sent as one event. Read and written on ``queue``.
    private var pendingText = ""
    private var flushScheduled = false
    /// The model change asked for and not yet confirmed, by the request id the CLI will echo.
    /// Read and written on ``queue``.
    private var pendingModelRequest: String?
    private var pendingModel: String?

    /// How long deltas are gathered before one event carries them.
    ///
    /// `--include-partial-messages` emits a delta per API chunk, several a second; a frame each
    /// would put hundreds of messages a second on a channel shared with the phone's input, and
    /// the transcript view would re-lay-out per token. Fifty milliseconds is under the eye's
    /// threshold and turns a burst into a handful of events.
    private static let deltaFlushInterval: TimeInterval = 0.05
    /// And a cap, so a generator writing faster than the timer fires cannot grow the buffer.
    private static let deltaFlushBytes = 4096

    /// The binary the session runs, for the failure sentence when it is not installed.
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
            // The input the ask carried, echoed back on an allow because that is the shape the
            // CLI documents its answer in. Absent for an answer arriving after a replay, which is
            // exactly the case where the CLI no longer holds the ask either.
            let input = self.stream.takeApprovalInput(approvalID) ?? [:]
            let body: [String: Any]
            switch decision {
            case .allow:
                body = ["behavior": "allow", "updatedInput": input]
            case .deny:
                body = ["behavior": "deny", "message": "Denied from Peering."]
            case .choose(let label):
                // A question ask is answered by an allow whose input carries the answers, keyed by
                // the question's own text. Verified against Claude Code 2.1.289: an allow without
                // this reads to the model as "no answer was given", and the question comes back.
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

    /// Asks the CLI to switch models. The confirmation is a `control_response` carrying the
    /// request id, watched for in ``consume(_:)``: the answer holds the *resolved* model, which is
    /// what the picker then shows, and an error there is the only way to learn that a name the
    /// user typed does not exist.
    func setModel(_ model: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            let requestID = UUID().uuidString
            self.pendingModelRequest = requestID
            self.pendingModel = model
            // The model is left out entirely for "default", which is the SDK's own spelling: the
            // CLI reads an absent model as the session default.
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

    func stop() {
        process.stop()
    }

    // MARK: - The queue

    private func consume(_ line: String) {
        if consumeModelResponse(line) { return }
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
            // Anything else is a boundary: the text so far belongs before it.
            flushText()
            if case .sessionReady = payload { seenReady = true }
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

    /// Watches for the answer to a model change, which the stream parser is not interested in.
    ///
    /// True when the line was that answer: it is this side's own traffic coming back, exactly like
    /// the approval receipts the parser already drops, so it must not reach the transcript.
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
            // The resolved name when the CLI sends one, and what was asked for when it does not.
            let payload = response["response"] as? [String: Any]
            let resolved = payload?["model"] as? String
            onModel?(resolved ?? asked)
        } else {
            let message = (response["error"] as? String)
                ?? (response["response"] as? [String: Any])?["error"] as? String
                ?? "That model was not accepted."
            // The session is still on the model it was on, so nothing is reported as changed:
            // the picker goes on showing what is really running, and the sentence says why.
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
        // A session that never said hello and then died is the shape of a CLI too old for these
        // flags, or one that failed to authenticate; the last thing it said is the sentence the
        // user needs, and the death alone would be silent.
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

/// A session that cannot start, with the sentence the phone shows.
struct AgentLaunchFailure: Error {
    let message: String
}
