import Foundation

/// A chat stopped on purpose and moved to history: its process is stopped and its conversation kept, and the next message starts it again where it left off.
public enum AgentPause {
    /// The transcript line the Mac writes on pausing. The phone reads a chat as paused while this is the last thing in it, so the state needs no field of its own on the wire.
    public static let notice = "Stopped and moved to history. Send a message to pick this chat up where it left off."

    public static func isPaused(_ transcript: AgentTranscript) -> Bool {
        if case .notice(_, let text) = transcript.items.last { return text == notice }
        return false
    }
}

/// A conversation the CLI will not reopen, so it can be read here and no more.
public enum AgentExpiry {
    public static let message = "Claude Code can no longer reopen this conversation. You can read it here."

    /// What the CLI says when `--resume` names a conversation it no longer has.
    public static func isResumeRefusal(stderr: String) -> Bool {
        stderr.localizedCaseInsensitiveContains("no conversation found")
    }

    public static func isExpired(_ transcript: AgentTranscript) -> Bool {
        transcript.items.suffix(4).contains { item in
            if case .failure(_, let text) = item { return text == message }
            return false
        }
    }
}

/// The opening message for a new chat that stands in for one that cannot be reopened: where the old one left off, in the person's own words and the agent's.
public enum AgentRecap {
    public static let exchanges = 3
    public static let excerptLength = 400

    public static func text(from transcript: AgentTranscript) -> String? {
        var turns: [(asked: String, answered: String?)] = []
        for item in transcript.items {
            switch item {
            case .user(_, let text):
                turns.append((text, nil))
            case .reply(_, let text):
                if let last = turns.indices.last { turns[last].answered = text }
            default:
                continue
            }
        }
        guard !turns.isEmpty else { return nil }
        var lines = ["I am continuing a conversation that can no longer be reopened. This is where it left off."]
        for turn in turns.suffix(exchanges) {
            lines.append("")
            lines.append("I asked: \(excerpt(turn.asked))")
            if let answered = turn.answered { lines.append("You answered: \(excerpt(answered))") }
        }
        lines.append("")
        lines.append("Please carry on from here.")
        return lines.joined(separator: "\n")
    }

    private static func excerpt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > excerptLength else { return trimmed }
        return String(trimmed.prefix(excerptLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
