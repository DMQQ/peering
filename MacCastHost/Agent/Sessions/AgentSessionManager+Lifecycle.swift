import Foundation
import os
import MacCastKit
import RemoteCore

/// Starting, restarting, ending and observing a session's CLI.
extension AgentSessionManager {
    /// The adapter to talk to: a chat whose CLI is not running gets a new one that resumes where it left off.
    /// Nil for a chat that cannot be continued: it had a conversation and its CLI never named the session, so a new process would start with no memory of it.
    func ensureLive(_ session: AgentSession) -> (any AgentAdapter)? {
        var revived: (any AgentAdapter)?
        let current: (any AgentAdapter)? = lock.withLock {
            if session.adapterLive { return session.adapter }
            guard session.cliSessionID != nil || !session.hasHistory,
                  let entry = AgentCatalogue.entry(for: session.agentID)
            else { return nil }
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

    func adapter(of session: AgentSession) -> any AgentAdapter {
        lock.withLock { session.adapter }
    }

    func attach(_ adapter: any AgentAdapter, to session: AgentSession) {
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
    func change<Value: Equatable>(
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
    func launch(_ adapter: any AgentAdapter, for session: AgentSession) {
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
    func abandon(_ adapter: any AgentAdapter, of session: AgentSession?, message: String) {
        guard let session else { return }
        lock.withLock { if session.adapter === adapter { session.adapterLive = false } }
        append(.failure(message: message), to: session)
    }

    func remove(_ session: AgentSession) {
        adapter(of: session).stop()
        lock.withLock { sessions[session.id] = nil }
        forget(session.id)
        refreshActivity()
    }

    /// Through the queue the saves use, so a save already waiting cannot bring the file back.
    func forget(_ id: UUID) {
        persistQueue.async { [store] in store.remove(id) }
    }

    func refreshActivity() {
        let changed: Bool? = lock.withLock {
            let nowActive = sessions.values.contains { $0.isBusy }
            guard nowActive != wasActive else { return nil }
            wasActive = nowActive
            return nowActive
        }
        if let changed { onActivityChanged?(changed) }
    }
}
