import Foundation
import PeeringKit
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
    /// When the chat was stopped, if this run watched it happen; otherwise when it began. What History sorts a paused chat by.
    let pausedAt: Date

    /// Stopped on purpose and kept: it has no process and does not count against the open chats.
    let isPaused: Bool

    var isLive: Bool { state != .exited && state != .failed && !isPaused }

    init(_ session: RemoteAgentSession, pauses: AgentPauseClock = AgentPauseClock()) {
        id = session.id
        agentID = session.agentID
        title = session.title
        directory = session.directory
        createdAt = session.createdAt
        pausedAt = pauses.date(for: session.id, fallback: session.createdAt)
        state = session.state
        activity = session.transcript.activity
        plan = session.transcript.planProgress
        preview = session.transcript.preview
        isPaused = AgentPause.isPaused(session.transcript)
    }
}
