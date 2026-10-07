import Foundation
import MacCastKit
import RemoteCore
import SwiftUI

extension MacSession {
    // MARK: - Events

    func apply(agent event: AgentEvent) {
        defer {
            if case .stream = event { scheduleAgentCards() } else { refreshAgentCards() }
        }
        switch event {
        case .snapshot(let infos):
            // Transcripts already read are kept: the listing says which sessions exist and the conversation arrives in the replay after each top-up.
            let previous = agentSessions
            agentHistoryRequested = []
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
            let before = agentSessions[index].transcript.state
            agentSessions[index].transcript.apply(streamEvent)
            announceAgentChange(at: index, from: before)
            flushAgentQueue(id, state: agentSessions[index].transcript.state)
            // Events on a chat never read are the tail of a conversation, not the conversation: it is loaded when its replay lands.
            if !agentSessions[index].isLoaded { ensureAgentHistory(id) }
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
            agentHistoryRequested.insert(id)
            // A turn can end while the phone is away, and the replay is the only news of it.
            flushAgentQueue(id, state: agentSessions[index].transcript.state)

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
            #if DEBUG
            if let id, AgentSeed.owns(id) { return }
            #endif
            if let id, let index = agentSessions.firstIndex(where: { $0.id == id }) {
                agentSessions[index].failure = message
            } else {
                append(note: message)
            }
        }

        publishWork()
        publishAgentWidget()
    }
}
