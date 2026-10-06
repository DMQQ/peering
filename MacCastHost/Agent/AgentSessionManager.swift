import Foundation
import MacCastKit
import os
import RemoteCore

private let agentLog = Logger(subsystem: "pl.dmq.peering.host", category: "agent")

final class AgentSessionManager: @unchecked Sendable {
    typealias Sink = @Sendable (AgentEvent) -> Void

    static let chatAgents: [String: String] = [
        "claude": "Claude Code",
        "codex": "Codex",
        "opencode": "OpenCode",
    ]

    private final class Session: @unchecked Sendable {
        let id = UUID()
        let ownerClientID: String
        let agentID: String
        let title: String
        let directory: String
        let createdAt = Date()
        let adapter: any AgentAdapter

        var transcript: [AgentStreamEvent] = []
        var nextIndex: UInt64 = 1
        var bytes = 0
        var truncatedAtFront = false
        var state: AgentSessionState = .idle
        var pendingApprovals: Set<String> = []
        var model: String?
        var permissionMode: AgentPermissionMode
        var lastReply: String?

        init(ownerClientID: String, agentID: String, title: String, directory: String, adapter: any AgentAdapter) {
            self.ownerClientID = ownerClientID
            self.agentID = agentID
            self.title = title
            self.directory = directory
            self.adapter = adapter
            self.permissionMode = adapter.defaultPermissionMode
        }

        var lastIndex: UInt64 { nextIndex - 1 }

        var info: AgentSessionInfo {
            AgentSessionInfo(
                id: id,
                agentID: agentID,
                title: title,
                directory: directory,
                state: state,
                lastIndex: lastIndex,
                model: model,
                permissionMode: permissionMode,
                permissionModes: adapter.permissionModes,
                createdAt: createdAt
            )
        }
    }

    private static let maximumSessionsPerClient = 4
    private static let replayChunkBytes = 64 * 1024

    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]
    private var sinks: [String: Sink] = [:]

    var onPushNeeded: (@Sendable (String, String, String) -> Void)?

    var onActivityChanged: (@Sendable (Bool) -> Void)?
    private var wasActive = false

    deinit {
        let active = lock.withLock { Array(sessions.values) }
        for session in active { session.adapter.stop() }
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
            guard let session = ownedSession(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That chat is no longer here."))
                return
            }
            replay(session, since: since, sink: sink)

        case .start(let agentID, let directory):
            start(agentID: agentID, requested: directory, clientID: clientID, sink: sink)

        case .prompt(let id, let text):
            guard let session = ownedSession(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That chat is no longer here."))
                return
            }
            guard text.utf8.count <= 64 * 1024 else {
                sink(.failed(sessionID: id, message: "That prompt is too long to send."))
                return
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            append(.userPrompt(text: text), to: session)
            session.adapter.prompt(text)

        case .setModel(let id, let model):
            guard let session = ownedSession(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That chat is no longer here."))
                return
            }
            // Model changes are reported by the adapter via ``onModel`` once real, never on the strength of the ask alone.
            session.adapter.setModel(model)

        case .setPermissionMode(let id, let mode):
            guard let session = ownedSession(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That chat is no longer here."))
                return
            }
            guard session.adapter.permissionModes.contains(mode) else {
                sink(.failed(sessionID: id, message: "This agent cannot run in that mode."))
                return
            }
            // Reported through ``onPermissionMode`` once the CLI has taken it, as the model is.
            session.adapter.setPermissionMode(mode)

        case .approval(let id, let approvalID, let decision):
            guard let session = ownedSession(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That chat is no longer here."))
                return
            }
            guard lock.withLock({ session.pendingApprovals.remove(approvalID) != nil }) else { return }
            append(.approvalResolved(approvalID: approvalID, decision: decision), to: session)
            session.adapter.respond(approvalID: approvalID, decision: decision)

        case .interrupt(let id):
            ownedSession(id, ownerClientID: clientID)?.adapter.interrupt()

        case .close(let id):
            guard let session = ownedSession(id, ownerClientID: clientID) else { return }
            session.adapter.stop()
            lock.withLock { sessions.removeValue(forKey: id) }
            sink(.closed(sessionID: id))

        case .browse(let path):
            browse(requested: path, sink: sink)
        }
    }

    func disconnect(clientID: String) {
        lock.withLock { sinks.removeValue(forKey: clientID) }
    }

    // MARK: - Sessions

    private func start(agentID: String, requested: String?, clientID: String, sink: @escaping Sink) {
        guard let name = Self.chatAgents[agentID] else {
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

        let adapter: any AgentAdapter
        switch agentID {
        case "claude": adapter = ClaudeCodeAdapter(directory: directory)
        case "opencode": adapter = OpenCodeAdapter(directory: directory)
        default: adapter = CodexAdapter(directory: directory)
        }

        var session: Session?
        var failure: String?
        lock.withLock {
            let existing = sessions.values.filter { $0.ownerClientID == clientID }
            guard existing.count < Self.maximumSessionsPerClient else {
                failure = "Chat session limit reached."
                return
            }
            let title = Self.uniqueTitle(base: "\(name) · \(directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent)", among: existing)
            let created = Session(
                ownerClientID: clientID,
                agentID: agentID,
                title: title,
                directory: directory.path,
                adapter: adapter
            )
            sessions[created.id] = created
            session = created
        }
        if let failure {
            sink(.failed(sessionID: nil, message: failure))
            return
        }
        guard let session else { return }

        adapter.onEvent = { [weak self, weak session] payload in
            guard let self, let session else { return }
            self.append(payload, to: session)
        }
        adapter.onPermissionMode = { [weak self, weak session] mode in
            guard let self, let session else { return }
            let changed: Bool = self.lock.withLock {
                guard session.permissionMode != mode else { return false }
                session.permissionMode = mode
                return true
            }
            guard changed else { return }
            let sink = self.lock.withLock { self.sinks[session.ownerClientID] }
            sink?(.permissionModeChanged(sessionID: session.id, mode: mode))
        }
        adapter.onModel = { [weak self, weak session] model in
            guard let self, let session else { return }
            let changed: Bool = self.lock.withLock {
                guard session.model != model else { return false }
                session.model = model
                return true
            }
            guard changed else { return }
            // Sent, not appended: the model is a session fact, not transcript, so it is neither indexed nor replayed.
            let sink = self.lock.withLock { self.sinks[session.ownerClientID] }
            sink?(.modelChanged(sessionID: session.id, model: model))
        }
        sink(.created(session.info))
        agentLog.notice("agent chat created · \(agentID, privacy: .public) · \(directory.path, privacy: .public)")

        // Off the connection's queue: resolving the binary runs a login shell and that queue carries pings.
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak session] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                guard let self, let session else { return }
                agentLog.error("agent chat directory missing · \(directory.path, privacy: .public)")
                self.append(.failure(message: "There is no folder at \(directory.path) on this Mac."), to: session)
                return
            }
            do {
                try adapter.start()
            } catch let failure as AgentLaunchFailure {
                guard let self, let session else { return }
                agentLog.error("agent chat could not start · \(failure.message, privacy: .public)")
                self.append(.failure(message: failure.message), to: session)
            } catch {
                guard let self, let session else { return }
                agentLog.error("agent chat could not start · \(String(describing: error), privacy: .public)")
                self.append(.failure(message: "That agent could not be started."), to: session)
            }
        }
    }

    private static func uniqueTitle(base: String, among sessions: [Session]) -> String {
        var title = base
        var counter = 2
        while sessions.contains(where: { $0.title == title }) {
            title = "\(base) \(counter)"
            counter += 1
        }
        return title
    }

    private func ownedSession(_ id: UUID, ownerClientID: String) -> Session? {
        lock.withLock {
            guard let session = sessions[id], session.ownerClientID == ownerClientID else { return nil }
            return session
        }
    }

    // MARK: - Events

    private func append(_ payload: AgentStreamEvent.Payload, to session: Session) {
        // Read before the lock: one lock order everywhere avoids deadlock with the token store.
        let token = PushTokenStore.shared.tokensByClient()[session.ownerClientID]
        var event: AgentStreamEvent?
        var sink: Sink?
        var push: (title: String, body: String)?
        var nowActive = false
        /// A model the turn's own report disagrees with what this session was showing.
        var correctedModel: String??

        lock.withLock {
            let indexed = AgentStreamEvent(index: session.nextIndex, payload: payload)
            session.transcript.append(indexed)
            session.nextIndex += 1
            event = indexed

            switch payload {
            case .turnStarted:
                session.state = .working
            case .approvalRequested(let approvalID, let call, let reason):
                session.pendingApprovals.insert(approvalID)
                session.state = .awaitingApproval
                // Reaches the user even with the socket open: the phone may be suspended behind Picture in Picture.
                if token != nil {
                    push = (
                        "\(Self.displayName(of: session)) asks",
                        reason ?? call.detail ?? "Needs your approval."
                    )
                }
            case .approvalResolved(let approvalID, _):
                session.pendingApprovals.remove(approvalID)
                if session.pendingApprovals.isEmpty, session.state == .awaitingApproval {
                    session.state = .working
                }
            case .textFinal(let text):
                session.lastReply = text
            case .turnFinished(let summary):
                session.pendingApprovals.removeAll()
                session.state = .idle
                // The CLI's own answer wins: a Mac whose config pins a model keeps running it whatever the picker was told.
                if let model = summary.model, model != session.model {
                    session.model = model
                    correctedModel = model
                }
                if sinks[session.ownerClientID] == nil, token != nil {
                    push = (
                        "\(Self.displayName(of: session)) \(summary.ok ? "finished" : (summary.stopped ? "stopped" : "failed"))",
                        Self.pushBody(for: session, summary: summary)
                    )
                }
            case .failure:
                session.state = .failed
            case .sessionExited:
                session.state = .exited
            case .sessionReady(_, _, let model, _):
                if let model { session.model = model }
            case .userPrompt, .textDelta, .toolStarted, .toolFinished, .notice:
                break
            }

            session.bytes += Self.approximateBytes(of: payload)
            Self.trim(&session.transcript, bytes: &session.bytes, truncatedAtFront: &session.truncatedAtFront)
            sink = sinks[session.ownerClientID]
            nowActive = self.sessions.values.contains { $0.state == .working || $0.state == .awaitingApproval }
        }

        if let event {
            sink?(.stream(sessionID: session.id, event: event))
        }
        if let model = correctedModel {
            sink?(.modelChanged(sessionID: session.id, model: model))
        }
        if let push, let token {
            onPushNeeded?(token, push.title, push.body)
        }
        if nowActive != wasActive {
            wasActive = nowActive
            onActivityChanged?(nowActive)
        }
    }

    private static func displayName(of session: Session) -> String {
        chatAgents[session.agentID] ?? session.agentID
    }

    private static func pushBody(for session: Session, summary: AgentTurnSummary) -> String {
        if let lastReply = session.lastReply, !lastReply.isEmpty {
            let firstLine = lastReply.split(separator: "\n").first.map(String.init) ?? lastReply
            return String(firstLine.prefix(140))
        }
        return summary.ok ? "The turn finished." : (summary.stopped ? "The turn was stopped." : "The turn failed.")
    }

    private static func trim(_ transcript: inout [AgentStreamEvent], bytes: inout Int, truncatedAtFront: inout Bool) {
        guard bytes > AgentLimits.maximumTranscriptBytes else { return }
        let turnStarts = transcript.indices.filter { index in
            if case .userPrompt = transcript[index].payload { return true }
            return false
        }
        guard turnStarts.count > 1, let cut = turnStarts.dropFirst().first else { return }
        bytes -= transcript[0..<cut].reduce(0) { $0 + approximateBytes(of: $1.payload) }
        transcript.removeFirst(cut)
        truncatedAtFront = true
    }

    private static func approximateBytes(of payload: AgentStreamEvent.Payload) -> Int {
        switch payload {
        case .userPrompt(let text), .textFinal(let text), .textDelta(let text), .notice(let text):
            return text.utf8.count
        case .failure(let message):
            return message.utf8.count
        case .toolStarted(let call):
            return (call.detail ?? "").utf8.count + (call.diff ?? "").utf8.count
        case .toolFinished(_, _, let output, _):
            return (output ?? "").utf8.count
        case .sessionReady, .turnStarted, .approvalRequested, .approvalResolved, .turnFinished, .sessionExited:
            return 64
        }
    }

    // MARK: - Replay

    private func replay(_ session: Session, since: UInt64, sink: @escaping Sink) {
        var chunks: [[AgentStreamEvent]] = []
        var truncated = false
        lock.withLock {
            let events = session.transcript.filter { $0.index > since }
            truncated = session.truncatedAtFront
            var current: [AgentStreamEvent] = []
            var size = 0
            for event in events {
                let eventSize = Self.approximateBytes(of: event.payload)
                if !current.isEmpty, current.count >= AgentLimits.maximumReplayEvents || size + eventSize > Self.replayChunkBytes {
                    chunks.append(current)
                    current = []
                    size = 0
                }
                current.append(event)
                size += eventSize
            }
            if !current.isEmpty { chunks.append(current) }
        }
        if chunks.isEmpty {
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

    // MARK: - The picker

    private func browse(requested: String?, sink: @escaping Sink) {
        let path = requested ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/") else {
            sink(.browseFailure(path: path, message: "That is not a folder this Mac can open."))
            return
        }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        DispatchQueue.global(qos: .userInitiated).async {
            switch DirectoryListing.entries(in: directory) {
            case .entries(let entries, let truncated):
                sink(.directory(path: directory.path, entries: entries, truncated: truncated))
            case .failure(let message):
                sink(.browseFailure(path: directory.path, message: message))
            }
        }
    }
}
