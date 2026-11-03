import Foundation
import PeeringKit
import RemoteCore

/// Headless mode has no approval channel: a tool the approval mode does not allow is denied and reported as a failed call.
final class GeminiAdapter: PerTurnAdapter, @unchecked Sendable {
    private var stream: AgentGeminiStream

    static let command = AgentGeminiStream.agentID
    static let displayName = "Gemini CLI"

    init(directory: URL, resume: AgentResume?) {
        stream = AgentGeminiStream(directory: directory.path, cliSessionID: resume?.cliSessionID)
        super.init(command: Self.command, displayName: Self.displayName, directory: directory, resume: resume)
    }

    override func arguments(for text: String) -> [String] {
        let approval = permissionMode == .auto ? "yolo" : "auto_edit"
        // An untrusted folder silently drops the approval mode to one headless mode denies everything in.
        var arguments = ["--output-format", "stream-json", "--approval-mode", approval, "--skip-trust"]
        if let model { arguments += ["--model", model] }
        if let session = stream.cliSessionID { arguments += ["--resume", session] }
        // Joined to its flag so a prompt starting with a dash is a value, not an option.
        arguments.append("--prompt=\(text)")
        return arguments
    }

    override func receive(line: String) -> [AgentStreamEvent.Payload] {
        stream.receive(line: line)
    }

    override func turnProcessEnded() {
        onUsage?(stream.usage)
    }
}
