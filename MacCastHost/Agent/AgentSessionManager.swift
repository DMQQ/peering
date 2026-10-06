import Foundation
import MacCastKit
import os
import RemoteCore

private let agentLog = Logger(subsystem: "pl.dmq.peering.host", category: "agent")

/// Agent chat sessions, owned independently of the connection that started them.
///
/// The shape is ``TerminalSessionManager``'s, for the same reasons: a session outlives the phone
/// that opened it, a later authenticated connection with the same client identity reattaches and
/// is replayed what it missed, and every request naming a session is checked against its owner.
/// What differs is what a session is: not a shell whose bytes are forwarded, but a CLI whose
/// events are normalised, indexed and kept as a transcript.
final class AgentSessionManager: @unchecked Sendable {
    typealias Sink = @Sendable (AgentEvent) -> Void

    /// Which catalogue commands can hold a chat. The other agents in the list are terminal-only:
    /// a structured stream is what separates the two, and only these have one.
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

        /// The normalised conversation, indexed, trimmed at turn boundaries. Read under the
        /// manager's lock.
        var transcript: [AgentStreamEvent] = []
        var nextIndex: UInt64 = 1
        var bytes = 0
        var truncatedAtFront = false
        var state: AgentSessionState = .idle
        var pendingApprovals: Set<String> = []
        /// What the CLI says it runs, which the picker shows and the listing carries.
        var model: String?
        /// The last thing the agent said, for a notification body worth reading.
        var lastReply: String?

        init(ownerClientID: String, agentID: String, title: String, directory: String, adapter: any AgentAdapter) {
            self.ownerClientID = ownerClientID
            self.agentID = agentID
            self.title = title
            self.directory = directory
            self.adapter = adapter
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
                createdAt: createdAt
            )
        }
    }

    /// Nothing said to the phone can make this side run out of disk or memory.
    private static let maximumSessionsPerClient = 4
    /// How much of one chunk of replay, roughly, beside the event count.
    private static let replayChunkBytes = 64 * 1024

    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]
    private var sinks: [String: Sink] = [:]

    /// Called when the phone should learn about something while its control channel is not there
    /// to hear it: an approval that is waiting, or a turn that ended. Arguments: APNs device
    /// token, notification title, body. Same contract as the terminal manager's.
    var onPushNeeded: (@Sendable (String, String, String) -> Void)?

    /// Called when the set of sessions that are doing something becomes empty or stops being
    /// empty, so the Mac can hold its sleep assertion while an agent is working.
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
            // The prompt goes into the transcript here and not from the CLI's echo, so both CLIs
            // read the same way to the phone and the user's own words are on screen the moment
            // they are sent.
            append(.userPrompt(text: text), to: session)
            session.adapter.prompt(text)

        case .setModel(let id, let model):
            guard let session = ownedSession(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That chat is no longer here."))
                return
            }
            // The adapter answers through ``onModel`` once the change is real: Claude confirms it
            // inside the running process and Codex takes one for its next turn, so nothing here
            // reports the model as changed on the strength of the ask alone.
            session.adapter.setModel(model)

        case .approval(let id, let approvalID, let decision):
            guard let session = ownedSession(id, ownerClientID: clientID) else {
                sink(.failed(sessionID: id, message: "That chat is no longer here."))
                return
            }
            // Answered twice, or answered late: a prompt that is no longer waiting cannot be
            // answered, and saying so would be noise about something already decided.
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

    /// A phone that has gone drops its sink and nothing else: the sessions keep working, and a
    /// later connection with the same client identity lists them and is replayed.
    func disconnect(clientID: String) {
        lock.withLock { sinks.removeValue(forKey: clientID) }
    }

    // MARK: - Sessions

    private func start(agentID: String, requested: String?, clientID: String, sink: @escaping Sink) {
        guard let name = Self.chatAgents[agentID] else {
            sink(.failed(sessionID: nil, message: "This app cannot chat with that agent."))
            return
        }

        // The same shape the terminal browser enforces, for the same reason: a relative path would
        // resolve against this process's working directory rather than anything the user meant.
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
        adapter.onModel = { [weak self, weak session] model in
            guard let self, let session else { return }
            let changed: Bool = self.lock.withLock {
                guard session.model != model else { return false }
                session.model = model
                return true
            }
            guard changed else { return }
            // Sent rather than appended: the model is a fact about the session, not a line of the
            // conversation, so it is not indexed into the transcript and not replayed. A phone
            // that reattaches learns it from the listing.
            let sink = self.lock.withLock { self.sinks[session.ownerClientID] }
            sink?(.modelChanged(sessionID: session.id, model: model))
        }
        sink(.created(session.info))
        agentLog.notice("agent chat created · \(agentID, privacy: .public) · \(directory.path, privacy: .public)")

        // Off the connection's queue: resolving the binary runs a login shell, and starting a CLI
        // reads a disk. Both can take a noticeable moment on the first chat of a launch, and the
        // queue behind them carries the phone's pings.
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

    /// The one place an event becomes the session's state: indexed, stored, sent, and worth a
    /// notification when nobody is listening.
    private func append(_ payload: AgentStreamEvent.Payload, to session: Session) {
        // Read before the lock, the terminal manager's rule: the token store has a lock of its
        // own, and one lock order held everywhere is one fewer way for two to deadlock.
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
                // Reaches the user whether or not the control channel is up: a phone can be
                // suspended behind Picture in Picture with the socket still open, which is the
                // case terminal alerts already push through.
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
                // **The CLI's own answer to what ran, and the only one worth keeping.** A model
                // asked for is announced when the CLI accepts it, and this corrects that to the
                // truth: a Mac whose configuration pins a model goes on running it whatever the
                // picker was told, and the picker should end up saying so rather than naming a
                // model that never ran.
                if let model = summary.model, model != session.model {
                    session.model = model
                    correctedModel = model
                }
                // Only when the phone is not there to see it: a banner for every turn while the
                // user is watching the transcript would be the app telling them what they read.
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
                // The CLI naming its model is the same fact as the picker changing it, and the
                // listing should carry whichever happened last.
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

    /// Drops whole turns from the front once a session outgrows its budget, cutting at a user
    /// prompt so a card and its result are never separated.
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
