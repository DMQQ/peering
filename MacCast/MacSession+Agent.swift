import Foundation
import MacCastKit
import RemoteCore
import SwiftUI

struct AgentPickerState {
    var path: String?
    var startPath: String?
    var entries: [RemoteDirectoryEntry] = []
    var isLoading = false
    var failure: String?
}

/// Agent chats mirror ``MacSession+Terminal``: reattached from a listing, replayed, owner-scoped on the Mac, forgotten when the session is gone. A listing carries no conversation, so history is asked lazily and each session remembers how far it has read.
extension MacSession {
    // MARK: - Requests

    func refreshAgentSessions() {
        guard hostSupportsAgentChat else { return }
        wire?.sendAgent(.list)
    }

    /// `since` is the highest index applied, so a reattach fetches only what was missed; a never-read session asks from zero.
    func loadAgentHistory(_ id: UUID, since: UInt64) {
        wire?.sendAgent(.history(sessionID: id, since: since))
    }

    func startAgentChat(agentID: String, directory: String?) {
        AgentFolderHistory.record(directory: directory, agentID: agentID, macName: model.hostName)
        wire?.sendAgent(.start(agentID: agentID, directory: directory))
    }

    /// The transcript's copy arrives from the Mac, so nothing is optimistic here.
    func sendAgentPrompt(_ text: String, to id: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = agentSessions.firstIndex(where: { $0.id == id }) {
            agentSessions[index].failure = nil
        }
        wire?.sendAgent(.prompt(sessionID: id, text: trimmed))
    }

    func respondToAgentApproval(_ approvalID: String, decision: AgentApprovalDecision, in id: UUID) {
        wire?.sendAgent(.approval(sessionID: id, approvalID: approvalID, decision: decision))
    }

    func interruptAgent(_ id: UUID) {
        wire?.sendAgent(.interrupt(sessionID: id))
    }

    func setAgentModel(_ model: String?, in id: UUID) {
        wire?.sendAgent(.setModel(sessionID: id, model: model))
    }

    /// How freely the session may act from now on. The mode shown changes when the Mac confirms it.
    func setAgentPermissionMode(_ mode: AgentPermissionMode, in id: UUID) {
        guard hostSupportsAgentPermissionModes else { return }
        wire?.sendAgent(.setPermissionMode(sessionID: id, mode: mode))
    }

    func closeAgentSession(_ id: UUID) {
        wire?.sendAgent(.close(sessionID: id))
    }

    func browseAgentFolder(_ path: String?) {
        agentPicker.isLoading = true
        agentPicker.failure = nil
        wire?.sendAgent(.browse(path: path))
    }

    // MARK: - Events

    func apply(agent event: AgentEvent) {
        switch event {
        case .snapshot(let infos):
            // Transcripts already read are kept: the listing says which sessions exist and the conversation arrives in the replay after each top-up.
            let previous = agentSessions
            agentSessions = infos.map { info in
                var session = RemoteAgentSession(info)
                if let known = previous.first(where: { $0.id == info.id }) {
                    session.transcript = known.transcript
                    session.isLoaded = known.isLoaded
                }
                return session
            }
            if selectedAgentSessionID == nil || !agentSessions.contains(where: { $0.id == selectedAgentSessionID }) {
                selectedAgentSessionID = agentSessions.first?.id
            }
            for session in agentSessions where session.isLoaded {
                loadAgentHistory(session.id, since: session.transcript.lastIndex)
            }

        case .created(let info):
            if let index = agentSessions.firstIndex(where: { $0.id == info.id }) {
                agentSessions[index].infoState = info.state
            } else {
                agentSessions.append(RemoteAgentSession(info))
            }
            selectedAgentSessionID = info.id
            newAgentSessionID = info.id
            loadAgentHistory(info.id, since: 0)

        case .stream(let id, let streamEvent):
            guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
            agentSessions[index].transcript.apply(streamEvent)
            agentSessions[index].isLoaded = true
            agentSessions[index].infoState = agentSessions[index].transcript.state
            agentSessions[index].failure = nil
            // The CLI naming its model at the start is the same fact as the picker changing it; this is the only path either takes to the screen.
            if case .sessionReady(_, _, let model, _) = streamEvent.payload, let model {
                agentSessions[index].model = model
            }

        case .modelChanged(let id, let model):
            guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
            agentSessions[index].model = model

        case .usageChanged(let id, let usage):
            guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
            agentSessions[index].usage = usage

        case .permissionModeChanged(let id, let mode):
            guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
            agentSessions[index].permissionMode = mode

        case .replay(let id, let events, _, let truncatedAtFront):
            guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
            // A replay from index 1 is the whole conversation, so what is held is replaced rather than doubled.
            if events.first?.index == 1 {
                agentSessions[index].transcript.reset()
            }
            agentSessions[index].transcript.apply(events)
            if truncatedAtFront {
                agentSessions[index].transcript.markTruncatedAtFront()
            }
            agentSessions[index].isLoaded = true

        case .directory(let path, let entries, _):
            agentPicker = AgentPickerState(
                path: path,
                startPath: agentPicker.startPath ?? path,
                entries: entries,
                isLoading: false,
                failure: nil
            )

        case .browseFailure(_, let message):
            agentPicker.isLoading = false
            agentPicker.failure = message

        case .closed(let id):
            agentSessions.removeAll { $0.id == id }
            if selectedAgentSessionID == id {
                selectedAgentSessionID = agentSessions.first?.id
            }

        case .failed(let id, let message):
            if let id, let index = agentSessions.firstIndex(where: { $0.id == id }) {
                agentSessions[index].failure = message
            } else {
                append(note: message)
            }
        }
    
        publishWork()
}
}

enum AgentFolderHistory {
    static let key = "Peering.agentFolders"
    static let limit = 20

    struct Entry: Codable, Equatable {
        let agentID: String
        let path: String
        let macName: String
        let date: Date
    }

    static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries.sorted { $0.date > $1.date }
    }

    static func record(directory: String?, agentID: String, macName: String?) {
        // The home folder is what starting with nothing means, so recording no choice as a recent would add a row that says nothing.
        guard let directory else { return }
        var entries = load().filter { !($0.agentID == agentID && $0.path == directory) }
        entries.insert(Entry(agentID: agentID, path: directory, macName: macName ?? "", date: .now), at: 0)
        let kept = Array(entries.prefix(limit))
        if let data = try? JSONEncoder().encode(kept) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
