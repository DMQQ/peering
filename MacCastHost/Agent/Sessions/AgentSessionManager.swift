import Foundation
import MacCastKit
import os
import RemoteCore

private let agentLog = Logger(subsystem: "pl.dmq.peering.host", category: "agent")

final class AgentSessionManager: @unchecked Sendable {
    typealias Sink = @Sendable (AgentEvent) -> Void

    static var chatAgents: [String: String] { AgentCatalogue.names }

    private static let maximumSessionsPerClient = 4
    private static let replayChunkBytes = 64 * 1024

    let lock = NSLock()
    var sessions: [UUID: AgentSession] = [:]
    var sinks: [String: Sink] = [:]
    var wasActive = false

    let store: AgentSessionDiskStore
    let persistQueue = DispatchQueue(label: "pl.dmq.peering.host.agent.persist", qos: .utility)

    var onPushNeeded: (@Sendable (String, String, String) -> Void)?
    var onActivityChanged: (@Sendable (Bool) -> Void)?

    init(store: AgentSessionDiskStore = AgentSessionManager.defaultStore()) {
        self.store = store
        restore()
    }

    deinit {
        let active = lock.withLock { Array(sessions.values) }
        for session in active { session.adapter.stop() }
    }

    private static func defaultStore() -> AgentSessionDiskStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "pl.dmq.peering.host"
        return AgentSessionDiskStore(directory: support.appendingPathComponent(bundle).appendingPathComponent("AgentChats"))
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
                sessions[record.id] = AgentSession(restoring: record, adapter: adapter)
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
            let adapter = ensureLive(session)
            append(.userPrompt(text: text), to: session)
            adapter.prompt(text)

        case .setModel(let id, let model):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            // Model changes are reported by the adapter via ``onModel`` once real, never on the strength of the ask alone.
            ensureLive(session).setModel(model)

        case .setPermissionMode(let id, let mode):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            guard session.adapter.permissionModes.contains(mode) else {
                sink(.failed(sessionID: id, message: "This agent cannot run in that mode."))
                return
            }
            // Reported through ``onPermissionMode`` once the CLI has taken it, as the model is.
            ensureLive(session).setPermissionMode(mode)

        case .approval(let id, let approvalID, let decision):
            guard let session = owned(id, by: clientID, reporting: sink) else { return }
            guard lock.withLock({ session.pendingApprovals.remove(approvalID) != nil }) else { return }
            append(.approvalResolved(approvalID: approvalID, decision: decision), to: session)
            session.adapter.respond(approvalID: approvalID, decision: decision)

        case .interrupt(let id):
            guard let session = owned(id, by: clientID) else { return }
            if lock.withLock({ session.adapterLive }) { session.adapter.interrupt() }

        case .close(let id):
            guard let session = owned(id, by: clientID) else { return }
            remove(session)
            sink(.closed(sessionID: id))

        case .browse(let path):
            AgentDirectoryBrowser.list(requested: path, sink: sink)
        }
    }

    func disconnect(clientID: String) {
        _ = lock.withLock { sinks.removeValue(forKey: clientID) }
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

    // MARK: - Sessions

    private func start(agentID: String, requested: String?, clientID: String, sink: @escaping Sink) {
        guard let entry = AgentCatalogue.entry(for: agentID) else {
            sink(.failed(sessionID: nil, message: "This app cannot chat with that agent."))
            return
        }

        // A relative path would resolve against this process's working directory.
        let path = requested ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/") else {
            sink(.failed(sessionID: nil, message: "That is not a folder this Mac can open."))
            return
        }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            agentLog.error("agent chat directory missing · \(directory.path, privacy: .public)")
            sink(.failed(sessionID: nil, message: "There is no folder at \(directory.path) on this Mac."))
            return
        }

        let adapter = entry.make(directory, nil)
        var created: AgentSession?
        var evicted: [AgentSession] = []
        var failure: String?
        lock.withLock {
            var existing = sessions.values.filter { $0.ownerClientID == clientID }
            // An ended chat is only history: it gives way before a new one is refused.
            while existing.count >= Self.maximumSessionsPerClient,
                  let oldest = existing.filter({ $0.state == .exited }).min(by: { $0.createdAt < $1.createdAt }) {
                sessions[oldest.id] = nil
                existing.removeAll { $0.id == oldest.id }
                evicted.append(oldest)
            }
            guard existing.count < Self.maximumSessionsPerClient else {
                failure = "Chat session limit reached."
                return
            }
            let name = directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent
            let session = AgentSession(
                ownerClientID: clientID,
                agentID: agentID,
                title: Self.uniqueTitle(base: "\(entry.name) · \(name)", among: existing),
                directory: directory.path,
                adapter: adapter
            )
            sessions[session.id] = session
            created = session
        }
        for session in evicted {
            store.remove(session.id)
            sink(.closed(sessionID: session.id))
        }
        if let failure {
            sink(.failed(sessionID: nil, message: failure))
            return
        }
        guard let created else { return }

        attach(adapter, to: created)
        sink(.created(lock.withLock { created.info }))
        persist(created)
        agentLog.notice("agent chat created · \(agentID, privacy: .public) · \(directory.path, privacy: .public)")
        launch(adapter, for: created)
    }

    /// The adapter to talk to: a chat whose CLI is not running gets a new one that resumes where it left off.
    @discardableResult
    private func ensureLive(_ session: AgentSession) -> any AgentAdapter {
        var revived: (any AgentAdapter)?
        let current: any AgentAdapter = lock.withLock {
            guard !session.adapterLive, let entry = AgentCatalogue.entry(for: session.agentID) else { return session.adapter }
            let adapter = entry.make(URL(fileURLWithPath: session.directory), session.resume)
            session.adapter = adapter
            session.adapterLive = true
            if session.state == .exited || session.state == .failed { session.state = .idle }
            revived = adapter
            return adapter
        }
        if let revived {
            attach(revived, to: session)
            launch(revived, for: session)
            agentLog.notice("agent chat restarted · \(session.agentID, privacy: .public)")
        }
        return current
    }

    private func attach(_ adapter: any AgentAdapter, to session: AgentSession) {
        adapter.onEvent = { [weak self, weak session] payload in
            guard let self, let session else { return }
            self.append(payload, to: session)
        }
        adapter.onUsage = { [weak self, weak session] usage in
            guard let self, let session else { return }
            self.change(session, \.usage, to: usage, announcing: .usageChanged(sessionID: session.id, usage: usage))
        }
        adapter.onPermissionMode = { [weak self, weak session] mode in
            guard let self, let session else { return }
            self.change(session, \.permissionMode, to: mode, announcing: .permissionModeChanged(sessionID: session.id, mode: mode))
        }
        adapter.onModel = { [weak self, weak session] model in
            guard let self, let session else { return }
            // Sent, not appended: the model is a session fact, not transcript, so it is neither indexed nor replayed.
            self.change(session, \.model, to: model, announcing: .modelChanged(sessionID: session.id, model: model))
        }
    }

    /// Sets a session fact, and tells the owner and the disk only if it differs from what was held.
    private func change<Value: Equatable>(
        _ session: AgentSession,
        _ path: ReferenceWritableKeyPath<AgentSession, Value>,
        to value: Value,
        announcing event: AgentEvent
    ) {
        let (changed, sink): (Bool, Sink?) = lock.withLock {
            guard session[keyPath: path] != value else { return (false, nil) }
            session[keyPath: path] = value
            return (true, sinks[session.ownerClientID])
        }
        guard changed else { return }
        sink?(event)
        persist(session)
    }

    /// Off the connection's queue: resolving the binary runs a login shell and that queue carries pings.
    private func launch(_ adapter: any AgentAdapter, for session: AgentSession) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak session] in
            let directory = session.map { URL(fileURLWithPath: $0.directory) }
            var isDirectory: ObjCBool = false
            if let directory,
               !(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
                self?.abandon(adapter, of: session, message: "There is no folder at \(directory.path) on this Mac.")
                return
            }
            do {
                try adapter.start()
            } catch let failure as AgentLaunchFailure {
                agentLog.error("agent chat could not start · \(failure.message, privacy: .public)")
                self?.abandon(adapter, of: session, message: failure.message)
            } catch {
                agentLog.error("agent chat could not start · \(String(describing: error), privacy: .public)")
                self?.abandon(adapter, of: session, message: "That agent could not be started.")
            }
        }
    }

    /// A start that failed leaves the chat not live, so sending to it tries again.
    private func abandon(_ adapter: any AgentAdapter, of session: AgentSession?, message: String) {
        guard let session else { return }
        lock.withLock { if session.adapter === adapter { session.adapterLive = false } }
        append(.failure(message: message), to: session)
    }

    private func remove(_ session: AgentSession) {
        session.adapter.stop()
        _ = lock.withLock { sessions.removeValue(forKey: session.id) }
        store.remove(session.id)
    }

    private static func uniqueTitle(base: String, among sessions: [AgentSession]) -> String {
        var title = base
        var counter = 2
        while sessions.contains(where: { $0.title == title }) {
            title = "\(base) \(counter)"
            counter += 1
        }
        return title
    }

    // MARK: - Replay

    private func replay(_ session: AgentSession, since: UInt64, sink: @escaping Sink) {
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
