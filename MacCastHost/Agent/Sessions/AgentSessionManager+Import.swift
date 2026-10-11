import Foundation
import MacCastKit
import os
import RemoteCore

/// Picking up a conversation that was started in a terminal on this Mac.
extension AgentSessionManager {
    func listResumable(clientID: String, sink: @escaping Sink) {
        agentLog.notice("resumable conversations asked for")
        let (known, released) = lock.withLock { (Set(sessions.values.compactMap(\.cliSessionID)), releasedConversations) }
        // Off the connection's queue: this reads the heads and tails of up to a month of files.
        DispatchQueue.global(qos: .userInitiated).async {
            let sessions = ClaudeSessionLibrary.list(excluding: known, releasedAt: released)
            agentLog.notice("resumable conversations listed · \(sessions.count)")
            sink(.resumable(sessions))
            // After the list is sent: the question parks until someone answers it on the Mac, and the list should not wait for that.
            for root in Self.protectedRoots(of: sessions) { FolderAccessWatch.requestAccess(to: root) }
        }
    }

    /// The Desktop, Documents or Downloads folder macOS guards, for each one a listed conversation lives under.
    private static func protectedRoots(of sessions: [AgentResumableSession]) -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let guarded = ["Desktop", "Documents", "Downloads"].map { "\(home)/\($0)" }
        return Set(guarded.filter { root in sessions.contains { $0.directory == root || $0.directory.hasPrefix(root + "/") } })
    }

    func resume(agentID: String, cliSessionID: String, clientID: String, sink: @escaping Sink) {
        guard agentID == ClaudeCodeAdapter.command, let entry = AgentCatalogue.entry(for: agentID) else {
            sink(.failed(sessionID: nil, message: "Only Claude Code conversations can be continued from here yet."))
            return
        }
        let held = lock.withLock {
            sessions.values.first { $0.ownerClientID == clientID && $0.cliSessionID == cliSessionID }
        }
        if let held {
            sink(.created(lock.withLock { held.info }))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let conversation = ClaudeSessionLibrary.conversation(cliSessionID: cliSessionID) else {
                sink(.failed(sessionID: nil, message: "That conversation is no longer on this Mac."))
                return
            }
            self?.adopt(conversation, cliSessionID: cliSessionID, entry: entry, clientID: clientID, sink: sink)
        }
    }

    private func adopt(
        _ conversation: ClaudeSessionLibrary.Conversation,
        cliSessionID: String,
        entry: AgentCatalogue.Entry,
        clientID: String,
        sink: @escaping Sink
    ) {
        let directory = URL(fileURLWithPath: conversation.summary.directory)
        var adopted: AgentSession?
        var evicted: [AgentSession] = []
        lock.withLock {
            var existing = sessions.values.filter { $0.ownerClientID == clientID }
            evicted = makeRoom(among: &existing)
            let session = AgentSession(
                ownerClientID: clientID,
                agentID: entry.id,
                title: Self.uniqueTitle(base: conversation.summary.title, among: existing),
                directory: directory.path,
                adapter: entry.make(directory, AgentResume(cliSessionID: cliSessionID, model: nil, permissionMode: nil))
            )
            // No process yet: the first prompt starts the CLI with `--resume`, as it does for a chat read back from disk.
            session.adapterLive = false
            session.cliSessionID = cliSessionID
            session.usage = conversation.usage
            for payload in AgentClaudeSessionFile.settled(conversation.events) { session.transcript.append(payload) }
            if conversation.startsMidConversation { session.transcript.markTruncatedAtFront() }
            session.transcript.append(.notice(text: "Continued from a Claude Code session started on this Mac."))
            sessions[session.id] = session
            adopted = session
        }
        for session in evicted {
            forget(session.id)
            sink(.closed(sessionID: session.id))
        }
        guard let adopted else { return }
        sink(.created(lock.withLock { adopted.info }))
        persist(adopted)
        agentLog.notice("agent chat adopted from a terminal session · \(entry.id, privacy: .public)")
    }
}
