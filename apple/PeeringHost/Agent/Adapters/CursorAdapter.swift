import Foundation
import PeeringKit
import RemoteCore

/// Print mode has no approval channel: without `--force` a shell command outside the allowlist is refused, the safe direction.
final class CursorAdapter: PerTurnAdapter, @unchecked Sendable {
    private var stream: AgentCursorStream

    static let command = AgentCursorStream.agentID
    static let displayName = "Cursor"

    init(directory: URL, resume: AgentResume?) {
        stream = AgentCursorStream(directory: directory.path, cliSessionID: resume?.cliSessionID)
        super.init(command: Self.command, displayName: Self.displayName, directory: directory, resume: resume)
    }

    override func arguments(for text: String) -> [String] {
        // `--trust` answers the workspace prompt print mode cannot show; the phone already chose this folder.
        var arguments = ["--print", "--output-format", "stream-json", "--trust"]
        if permissionMode == .auto { arguments.append("--force") }
        if let model { arguments += ["--model", model] }
        if let session = stream.cliSessionID { arguments += ["--resume", session] }
        arguments += ["--", text]
        return arguments
    }

    override func receive(line: String) -> [AgentStreamEvent.Payload] {
        stream.receive(line: line)
    }
}
