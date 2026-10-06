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

    /// A chat the Mac already had when this phone connected is listed but empty: nothing else asks for its conversation.
    func ensureAgentHistory(_ id: UUID) {
        guard let session = agentSessions.first(where: { $0.id == id }),
              !session.isLoaded, agentHistoryRequested.insert(id).inserted
        else { return }
        loadAgentHistory(id, since: 0)
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
            if agentSessions[index].transcript.state == .working || !(agentQueues[id] ?? []).isEmpty {
                agentQueues[id, default: []].append(trimmed)
                return
            }
        }
        wire?.sendAgent(.prompt(sessionID: id, text: trimmed))
    }

    func refreshAgentCards() {
        agentCardsTask?.cancel()
        agentCardsTask = nil
        let cards = agentSessions.map(AgentCardDigest.init)
        if cards != agentCards { agentCards = cards }
    }

    /// Trailing, not leading: a burst of tokens becomes one rebuild after it settles a little, and the card still reads current within a blink.
    func scheduleAgentCards() {
        guard agentCardsTask == nil else { return }
        agentCardsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.refreshAgentCards()
        }
    }

    func removeQueuedAgentPrompt(at offset: Int, in id: UUID) {
        guard agentQueues[id]?.indices.contains(offset) == true else { return }
        agentQueues[id]?.remove(at: offset)
    }

    private func flushAgentQueue(_ id: UUID, state: AgentSessionState) {
        guard var queue = agentQueues[id], !queue.isEmpty else { return }
        switch state {
        case .idle:
            let next = queue.removeFirst()
            agentQueues[id] = queue
            wire?.sendAgent(.prompt(sessionID: id, text: next))
        case .failed, .exited:
            agentQueues[id] = nil
        case .working, .awaitingApproval:
            break
        }
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
        publishAgentWidget()
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

extension MacSession {
    /// Only a change the person did not cause: replay of history after a reconnect lands here too, so a turn that was already over is not announced.
    fileprivate func announceAgentChange(at index: Int, from before: AgentSessionState) {
        let session = agentSessions[index]
        let after = session.transcript.state
        guard after != before, session.isLoaded else { return }
        if before == .awaitingApproval { InAppBanner.shared.resolve(chatID: session.id) }
        let item: InAppBannerItem
        switch (before, after) {
        case (_, .awaitingApproval):
            guard let approval = session.transcript.pendingApprovals.first else { return }
            let options = approval.call.options?.map(\.label) ?? []
            let sessionID = session.id
            item = InAppBannerItem(
                symbol: options.isEmpty ? "hand.raised.fill" : "questionmark.bubble.fill",
                title: session.title,
                summary: options.isEmpty ? approval.call.title : String(localized: "Asks a question"),
                body: approval.reason ?? approval.call.detail,
                needsYou: true,
                chatID: sessionID,
                options: options,
                respond: { [weak self] decision in
                    self?.respondToAgentApproval(approval.id, decision: decision, in: sessionID)
                }
            )
        case (.working, .idle):
            var reply: String?
            for entry in session.transcript.items.reversed() {
                if case .reply(_, let text) = entry { reply = text; break }
            }
            item = InAppBannerItem(
                symbol: "checkmark.circle.fill",
                title: session.title,
                summary: String(localized: "Finished"),
                body: reply.map { String($0.suffix(600)) },
                needsYou: false,
                chatID: session.id
            )
        case (_, .failed):
            item = InAppBannerItem(
                symbol: "exclamationmark.triangle.fill",
                title: session.title,
                summary: String(localized: "The chat stopped with an error."),
                body: session.failure,
                needsYou: true,
                chatID: session.id
            )
        default:
            return
        }
        InAppBanner.shared.post(item)
    }
}

extension MacSession {
    /// The chats as the widget draws them. Called after every agent event; the publisher drops what changed nothing.
    func publishAgentWidget() {
        let chats = agentSessions.compactMap { session -> AgentChatSnapshot? in
            let state: AgentChatSnapshot.State
            switch session.state {
            case .working: state = .working
            case .awaitingApproval: state = .needsYou
            case .idle: state = .ready
            case .failed: state = .failed
            case .exited: return nil
            }
            let plan = session.transcript.planProgress
            let agent = TerminalAgent.all.first { $0.id == session.agentID }
            let folder = (session.directory as NSString).lastPathComponent
            return AgentChatSnapshot(
                id: session.id.uuidString,
                hostID: hostID,
                title: session.title,
                symbol: agent?.symbol ?? "sparkles",
                folder: folder.isEmpty ? session.directory : folder,
                state: state,
                activity: session.transcript.activity,
                planDone: plan?.completed ?? 0,
                planTotal: plan?.total ?? 0,
                planStepNumber: plan?.currentNumber,
                planStep: plan?.current?.text,
                updatedAt: .now
            )
        }
        AgentWidgetPublisher.shared.update(hostKey: hostID ?? hostName ?? id.uuidString, chats: chats)
    }
}
