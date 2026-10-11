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
    let createdAt: Date

    /// Stopped on purpose and kept: it has no process and does not count against the open chats.
    let isPaused: Bool

    var isLive: Bool { state != .exited && state != .failed && !isPaused }

    init(_ session: RemoteAgentSession) {
        id = session.id
        agentID = session.agentID
        title = session.title
        directory = session.directory
        createdAt = session.createdAt
        state = session.state
        activity = session.transcript.activity
        plan = session.transcript.planProgress
        preview = session.transcript.preview
        isPaused = AgentPause.isPaused(session.transcript)
    }
}
