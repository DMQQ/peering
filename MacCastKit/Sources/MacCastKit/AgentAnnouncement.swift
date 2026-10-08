import Foundation
import RemoteCore

/// What a change in a chat's state is worth telling the person about while they are elsewhere in the app.
public enum AgentAnnouncement: Equatable {
    case approval(AgentApproval)
    case finished(reply: String?)
    case failed

    /// Only a change the person did not cause: a replay of history after a reconnect lands as state changes too, so a chat not yet loaded announces nothing.
    public static func of(
        from before: AgentSessionState,
        to after: AgentSessionState,
        isLoaded: Bool,
        transcript: AgentTranscript
    ) -> AgentAnnouncement? {
        guard after != before, isLoaded else { return nil }
        switch (before, after) {
        case (_, .awaitingApproval):
            return transcript.pendingApprovals.first.map(AgentAnnouncement.approval)
        case (.working, .idle):
            var reply: String?
            for entry in transcript.items.reversed() {
                if case .reply(_, let text) = entry { reply = text; break }
            }
            return .finished(reply: reply.map { String($0.suffix(600)) })
        case (_, .failed):
            return .failed
        default:
            return nil
        }
    }
}
