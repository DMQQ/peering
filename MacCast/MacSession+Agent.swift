import Foundation
import MacCastKit
import RemoteCore
import SwiftUI

/// The folder picker's state: where it is looking, what it found, and what went wrong.
struct AgentPickerState {
    /// The folder on screen. `nil` while the Mac's home folder is still being resolved.
    var path: String?
    /// Where this walk started, which is the one folder the recents are offered from.
    var startPath: String?
    var entries: [RemoteDirectoryEntry] = []
    var isLoading = false
    var failure: String?
}

/// Agent chats: the events the Mac sends, and the requests the phone makes.
///
/// The same shape as ``MacSession+Terminal``, and deliberately: a chat is reattached from a
/// listing, replayed, owner-scoped on the Mac, and forgotten when it says the session is gone.
/// What differs is that a listing carries no conversation, so history is asked for lazily and
/// each session remembers how far it has read.
extension MacSession {
    // MARK: - Requests

    /// The sessions this Mac holds for this phone, as summaries.
    func refreshAgentSessions() {
        guard hostSupportsAgentChat else { return }
        wire?.sendAgent(.list)
    }

    /// Everything this session's transcript has not seen yet.
    ///
    /// `since` is the highest index applied, so a reattach fetches only what was missed; a
    /// session never read asks from zero, and the Mac answers with its whole buffer and says
    /// whether that buffer still holds the beginning.
    func loadAgentHistory(_ id: UUID, since: UInt64) {
        wire?.sendAgent(.history(sessionID: id, since: since))
    }

    /// Opens a chat. The Mac runs the CLI in `directory`, or in its home folder when nil.
    func startAgentChat(agentID: String, directory: String?) {
        AgentFolderHistory.record(directory: directory, agentID: agentID, macName: model.hostName)
        wire?.sendAgent(.start(agentID: agentID, directory: directory))
    }

    /// One user turn. The transcript's copy of it arrives from the Mac, which writes it down as
    /// it sends it, so there is nothing optimistic here and nothing to duplicate.
    func sendAgentPrompt(_ text: String, to id: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = agentSessions.firstIndex(where: { $0.id == id }) {
            agentSessions[index].failure = nil
        }
        wire?.sendAgent(.prompt(sessionID: id, text: trimmed))
    }

    /// The answer to a permission prompt. A second answer for the same ask is ignored by the
    /// Mac, and by the time one could be sent twice the bar is already gone.
    func respondToAgentApproval(_ approvalID: String, decision: AgentApprovalDecision, in id: UUID) {
        wire?.sendAgent(.approval(sessionID: id, approvalID: approvalID, decision: decision))
    }

    /// Stops the turn in flight. The session stays.
    func interruptAgent(_ id: UUID) {
        wire?.sendAgent(.interrupt(sessionID: id))
    }

    /// Changes which model the session runs from now on. `nil` is the CLI's own default.
    func setAgentModel(_ model: String?, in id: UUID) {
        wire?.sendAgent(.setModel(sessionID: id, model: model))
    }

    /// Ends the session and the CLI with it.
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
            // The transcripts already read are kept: the listing says which sessions exist and
            // what the Mac last knew about them, and the conversation itself arrives in the
            // replay that follows each top-up below.
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
            // The CLI naming its model at the start is the same fact as the picker changing it,
            // and this is the only path either one takes to the screen.
            if case .sessionReady(_, _, let model, _) = streamEvent.payload, let model {
                agentSessions[index].model = model
            }

        case .modelChanged(let id, let model):
            guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
            agentSessions[index].model = model

        case .replay(let id, let events, _, let truncatedAtFront):
            guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
            // A replay from index 1 is the whole conversation, so what is held is replaced
            // rather than doubled. The Mac only ever sends a full replay to a session that
            // asked for one.
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
    
        // The same list, for the chats: a turn finishing or an approval arriving changes what
        // the Lock Screen is showing without the session moving at all.
        publishWork()
}
}

/// The folders a chat was last started in, per agent, so the second one is two taps rather than
/// a browse.
///
/// The same shape as ``AgentHistory``: a small list in the defaults, newest first, bounded.
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
        // The home folder is what starting with nothing means, and recording "no choice" as a
        // recent would put a row that says nothing above one that says where.
        guard let directory else { return }
        var entries = load().filter { !($0.agentID == agentID && $0.path == directory) }
        entries.insert(Entry(agentID: agentID, path: directory, macName: macName ?? "", date: .now), at: 0)
        let kept = Array(entries.prefix(limit))
        if let data = try? JSONEncoder().encode(kept) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
