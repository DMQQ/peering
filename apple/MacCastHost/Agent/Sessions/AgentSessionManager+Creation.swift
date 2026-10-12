import Foundation
import MacCastKit
import os
import RemoteCore

/// Starting a chat and making room for it.
extension AgentSessionManager {
    /// Running CLIs per phone. Chats with no process (restored, ended) do not count against it.
    private static let maximumLiveSessionsPerClient = 4
    /// Chats kept per phone, running or not: the oldest one with no process gives way.
    private static let maximumStoredSessionsPerClient = 20

    func start(agentID: String, requested: String?, clientID: String, sink: @escaping Sink) {
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
        // Off the connection's queue: looking inside a protected folder waits for the Mac's permission dialog, and that queue carries pings and every other request.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                agentLog.error("agent chat directory missing · \(directory.path, privacy: .public)")
                sink(.failed(sessionID: nil, message: "There is no folder at \(directory.path) on this Mac."))
                return
            }
            self?.create(entry: entry, directory: directory, clientID: clientID, sink: sink)
        }
    }

    func create(entry: AgentCatalogue.Entry, directory: URL, clientID: String, sink: @escaping Sink) {
        let agentID = entry.id
        let adapter = entry.make(directory, nil)
        var created: AgentSession?
        var evicted: [AgentSession] = []
        var failure: String?
        lock.withLock {
            var existing = sessions.values.filter { $0.ownerClientID == clientID }
            guard existing.filter(\.adapterLive).count < Self.maximumLiveSessionsPerClient else {
                failure = "Chat session limit reached."
                return
            }
            evicted = makeRoom(among: &existing)
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
            forget(session.id)
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

    /// Drops the oldest chats with no process until there is room for one more. Called under the lock.
    func makeRoom(among existing: inout [AgentSession]) -> [AgentSession] {
        var evicted: [AgentSession] = []
        while existing.count >= Self.maximumStoredSessionsPerClient,
              let oldest = existing.filter({ !$0.adapterLive }).min(by: { $0.createdAt < $1.createdAt }) {
            sessions[oldest.id] = nil
            existing.removeAll { $0.id == oldest.id }
            evicted.append(oldest)
        }
        return evicted
    }

    static func uniqueTitle(base: String, among sessions: [AgentSession]) -> String {
        var title = base
        var counter = 2
        while sessions.contains(where: { $0.title == title }) {
            title = "\(base) \(counter)"
            counter += 1
        }
        return title
    }
}
