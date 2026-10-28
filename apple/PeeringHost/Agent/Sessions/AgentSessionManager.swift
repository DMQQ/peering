import Foundation
import PeeringKit
import os
import RemoteCore

final class AgentSessionManager: @unchecked Sendable {
    typealias Sink = @Sendable (AgentEvent) -> Void

    static var chatAgents: [String: String] { AgentCatalogue.names }

    private static let replayChunkBytes = 64 * 1024

    let lock = NSLock()
    var sessions: [UUID: AgentSession] = [:]
    var sinks: [String: Sink] = [:]
    /// Events held back for a client whose connection is backed up. Guarded by `lock`.
    var outputs: [String: HeldOutput<UUID, AgentEvent>] = [:]
    var wasActive = false
    /// When each conversation this app closed was last ours, by CLI session id. Guarded by `lock`.
    var releasedConversations: [String: Date] = [:]

    let store: AgentSessionDiskStore
    let persistQueue = DispatchQueue(label: "pl.dmq.peering.host.agent.persist", qos: .utility)

    var onPushNeeded: (@Sendable (String, String, String, RelayPushAction?) -> Void)?
    /// Set once before any phone connects.
    var externalApprovals: (@Sendable (String, AgentApprovalDecision) -> Bool)?
    var onActivityChanged: (@Sendable (Bool) -> Void)?
    /// Called with the owner when one of its chats changes state. Set once before any phone connects.
    var onChatStateChanged: (@Sendable (String) -> Void)?
    /// Where a phone is, for deciding whether a finished turn is pushed. Set once before any phone connects.
    var presence: (@Sendable (String) -> PhonePresence)?

    init(store: AgentSessionDiskStore = AgentSessionManager.defaultStore()) {
        self.store = store
        restore()
    }

    deinit {
        let active = lock.withLock { Array(sessions.values) }
        for session in active { adapter(of: session).stop() }
    }

    private static func defaultStore() -> AgentSessionDiskStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "pl.dmq.peering.host"
        return AgentSessionDiskStore(directory: support.appendingPathComponent(bundle).appendingPathComponent("AgentChats"))
    }

    /// What a Live Activity needs to know about one phone's chats: which exist and what each is doing.
    func liveActivityObservations(for clientID: String) -> [LiveActivityChatTracker.Observed] {
        lock.withLock {
            sessions.values
                .filter { $0.ownerClientID == clientID }
                .map { LiveActivityChatTracker.Observed(id: $0.id.uuidString, state: $0.state) }
        }
    }

    /// Chats come back idle and without a process: the CLI is started again by the first thing sent to one.
    private func restore() {
        let records = store.loadAll()
        lock.withLock {
            for record in records {
                guard let entry = AgentCatalogue.entry(for: record.agentID) else { continue }
                let adapter = entry.make(URL(fileURLWithPath: record.directory), AgentResume(
                    cliSessionID: record.cliSessionID, model: record.model, permissionMode: record.permissionMode
                ))
                let session = AgentSession(restoring: record, adapter: adapter)
                // An ask the old process was waiting on can never be answered now.
                for approvalID in session.transcript.unresolvedApprovalIDs {
                    session.transcript.append(.approvalResolved(approvalID: approvalID, decision: .deny))
                }
                sessions[record.id] = session
            }
        }
        if !records.isEmpty { agentLog.notice("agent chats restored · \(records.count)") }
    }

    // MARK: - Requests

    func handle(clientID: String, request: AgentRequest, sink: @escaping Sink) {
        guard !clientID.isEmpty else {
            sink(.failed(sessionID: nil, message: "The authenticated device has no identity."))
            return
        }
        lock.withLock { sinks[clientID] = sink }

        switch request {
        case .list:
            let snapshot = lock.withLock {
                sessions.values
                    .filter { $0.ownerClientID == clientID }
                    .map(\.info)
                    .sorted { $0.createdAt < $1.createdAt }
            }
            sink(.snapshot(snapshot))
            announceQueues(ownedBy: clientID, to: sink)

        case .history(let id, let since):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            replay(session, since: since, sink: sink)

        case .start(let agentID, let directory):
            start(agentID: agentID, requested: directory, clientID: clientID, sink: sink)

        case .prompt(let id, let text):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            guard text.utf8.count <= 64 * 1024 else {
                sink(.failed(sessionID: id, message: "That prompt is too long to send."))
                return
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let adapter = ensureLive(session) else {
                sink(.failed(sessionID: id, message: "That chat cannot be continued. Start a new one."))
                return
            }
            append(.userPrompt(text: text), to: session)
            adapter.prompt(text)

        case .setModel(let id, let model):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            // Reported back through ``onModel`` by the adapter, and by the CLI's own answer where it gives one.
            ensureLive(session)?.setModel(model)

        case .setPermissionMode(let id, let mode):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            guard adapter(of: session).permissionModes.contains(mode) else {
                sink(.failed(sessionID: id, message: "This agent cannot run in that mode."))
                return
            }
            // Reported through ``onPermissionMode`` once the CLI has taken it, as the model is.
            ensureLive(session)?.setPermissionMode(mode)

        case .approval(let id, let approvalID, let decision):
            // A hook in a terminal has no chat here to own it.
            if externalApprovals?(approvalID, decision) == true { return }
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            guard lock.withLock({ session.pendingApprovals.remove(approvalID) != nil }) else { return }
            append(.approvalResolved(approvalID: approvalID, decision: decision), to: session)
            adapter(of: session).respond(approvalID: approvalID, decision: decision)

        case .interrupt(let id):
            guard let session = owned(id, by: clientID) else { return }
            if lock.withLock({ session.adapterLive }) { adapter(of: session).interrupt() }

        case .close(let id):
            guard let session = owned(id, by: clientID) else { return }
            remove(session)
            sink(.closed(sessionID: id))

        case .browse(let path):
            AgentDirectoryBrowser.list(requested: path, sink: sink)

        case .changes(let id):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            AgentChangesReader.read(directory: session.directory, sessionID: id, sink: sink)

        case .commit(let id, let paths, let message):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            AgentGitActions.commit(directory: session.directory, sessionID: id, paths: paths, message: message, sink: sink)

        case .push(let id):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            AgentGitActions.push(directory: session.directory, sessionID: id, sink: sink)

        case .pause(let id):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            pause(session, sink: sink)

        case .queue(let id, let text):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            handleQueue(text, for: session, sink: sink)

        case .unqueue(let id, let index, let text):
            guard let session = owned(id, by: clientID) else { return }
            handleUnqueue(text, at: index, for: session)

        case .listResumable:
            listResumable(clientID: clientID, sink: sink)

        case .resume(let agentID, let cliSessionID):
            resume(agentID: agentID, cliSessionID: cliSessionID, clientID: clientID, sink: sink)

        case .peekResumable(let cliSessionID):
            peekResumable(cliSessionID: cliSessionID, sink: sink)
        }
    }

    func disconnect(clientID: String) {
        _ = lock.withLock {
            outputs.removeValue(forKey: clientID)
            return sinks.removeValue(forKey: clientID)
        }
    }

    private func owned(_ id: UUID, by clientID: String) -> AgentSession? {
        lock.withLock {
            guard let session = sessions[id], session.ownerClientID == clientID else { return nil }
            return session
        }
    }

    private func owned(_ id: UUID, by clientID: String, reporting sink: Sink) -> AgentSession? {
        let session = owned(id, by: clientID)
        if session == nil { sink(.failed(sessionID: id, message: "That chat is no longer here.")) }
        return session
    }

    // MARK: - Replay

    func replay(_ session: AgentSession, since: UInt64, sink: @escaping Sink) {
        let (chunks, truncated) = lock.withLock {
            (session.transcript.chunks(since: since, byteBudget: Self.replayChunkBytes), session.transcript.truncatedAtFront)
        }
        guard !chunks.isEmpty else {
            sink(.replay(sessionID: session.id, events: [], isLast: true, truncatedAtFront: truncated))
            return
        }
        for (index, chunk) in chunks.enumerated() {
            sink(.replay(
                sessionID: session.id,
                events: chunk,
                isLast: index == chunks.count - 1,
                truncatedAtFront: truncated
            ))
        }
    }
}
