import Foundation
import MacCastKit
import RemoteCore

/// One chat as the manager holds it. Every property is read and written under the manager's lock.
final class AgentSession: @unchecked Sendable {
    let id: UUID
    let ownerClientID: String
    let agentID: String
    let title: String
    let directory: String
    let createdAt: Date

    var adapter: any AgentAdapter
    /// False for a chat read back from disk and for one whose CLI has ended: the next thing sent to it starts a new adapter.
    var adapterLive: Bool
    var transcript: AgentTranscriptBuffer
    var state: AgentSessionState = .idle
    var pendingApprovals: Set<String> = []
    var cliSessionID: String?
    var model: String?
    var permissionMode: AgentPermissionMode
    var usage: AgentUsage?
    var lastReply: String?
    var telemetry = AgentTurnTelemetry()

    init(
        ownerClientID: String,
        agentID: String,
        title: String,
        directory: String,
        adapter: any AgentAdapter
    ) {
        id = UUID()
        createdAt = Date()
        self.ownerClientID = ownerClientID
        self.agentID = agentID
        self.title = title
        self.directory = directory
        self.adapter = adapter
        adapterLive = true
        transcript = AgentTranscriptBuffer()
        permissionMode = adapter.defaultPermissionMode
    }

    /// A chat read back from disk. Idle whatever it was doing when the host went away, and not live.
    init(restoring record: AgentSessionRecord, adapter: any AgentAdapter) {
        id = record.id
        createdAt = record.createdAt
        ownerClientID = record.ownerClientID
        agentID = record.agentID
        title = record.title
        directory = record.directory
        self.adapter = adapter
        adapterLive = false
        transcript = AgentTranscriptBuffer(
            restoring: record.events, nextIndex: record.nextIndex, truncatedAtFront: record.truncatedAtFront
        )
        cliSessionID = record.cliSessionID
        model = record.model
        permissionMode = record.permissionMode
        usage = record.usage
    }

    var resume: AgentResume {
        AgentResume(cliSessionID: cliSessionID, model: model, permissionMode: permissionMode)
    }

    var info: AgentSessionInfo {
        AgentSessionInfo(
            id: id,
            agentID: agentID,
            title: title,
            directory: directory,
            state: state,
            lastIndex: transcript.lastIndex,
            model: model,
            permissionMode: permissionMode,
            permissionModes: adapter.permissionModes,
            modelChoices: agentID == CodexAdapter.command ? CodexModelCache.visibleModels() : nil,
            usage: usage,
            createdAt: createdAt
        )
    }

    var record: AgentSessionRecord {
        AgentSessionRecord(
            id: id,
            ownerClientID: ownerClientID,
            agentID: agentID,
            title: title,
            directory: directory,
            createdAt: createdAt,
            cliSessionID: cliSessionID,
            model: model,
            permissionMode: permissionMode,
            usage: usage,
            events: transcript.events,
            nextIndex: transcript.nextIndex,
            truncatedAtFront: transcript.truncatedAtFront
        )
    }

    var isBusy: Bool {
        state == .working || state == .awaitingApproval
    }
}
