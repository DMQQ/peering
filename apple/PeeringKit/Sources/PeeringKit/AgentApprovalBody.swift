import Foundation

/// What an approval says it wants to do. The command is what the user is deciding on; the CLI's own reason for asking ("Contains brace with quote character") says nothing about it alone, so it only ever follows the command.
public enum AgentApprovalBody {
    public static func text(command: String?, reason: String?) -> String? {
        let parts = [command, reason]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
