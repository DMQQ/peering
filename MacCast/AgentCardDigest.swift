import Foundation
import MacCastKit
import RemoteCore

/// What a list card needs from a chat, and nothing that changes on every streamed token. The list reads these, rebuilt a couple of times a second, instead of the transcripts, which change many times a second while an agent works and made every switch of tab compete with a redraw of the whole page.
struct AgentCardDigest: Identifiable, Equatable {
    let id: UUID
    let agentID: String
    let title: String
    let directory: String
    let state: AgentSessionState
    let preview: String?
    let activity: String?
    let plan: AgentPlanProgress?

    var isLive: Bool { state != .exited && state != .failed }

    init(_ session: RemoteAgentSession) {
        id = session.id
        agentID = session.agentID
        title = session.title
        directory = session.directory
        state = session.state
        activity = session.transcript.activity
        plan = session.transcript.planProgress
        preview = Self.preview(of: session)
    }

    /// The last thing said, plain: the card is a glance at where the conversation stands.
    private static func preview(of session: RemoteAgentSession) -> String? {
        for item in session.transcript.items.reversed() {
            switch item {
            case .reply(_, let text), .user(_, let text):
                let plain = text
                    .replacingOccurrences(of: "```", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "#", with: "")
                    .split(whereSeparator: \.isNewline)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !plain.isEmpty { return String(plain.prefix(140)) }
            default:
                continue
            }
        }
        return nil
    }
}
