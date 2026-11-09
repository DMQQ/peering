import Foundation
import PeeringKit
import os
import RemoteCore

/// The chats routines run in: started like a phone's own, titled after the routine, and read back for how the run went.
extension AgentSessionManager {
    enum RoutineStart {
        case started(UUID)
        case refused(String)
    }

    /// Creates the chat and sends the prompt once the CLI is up. Folder and binary checks are the caller's.
    func startRoutineChat(_ routine: AgentRoutine, ownerClientID: String) -> RoutineStart {
        guard let entry = AgentCatalogue.entry(for: routine.agentID) else {
            return .refused(String(localized: "This Mac no longer has that agent."))
        }
        let directory = URL(fileURLWithPath: routine.directory).standardizedFileURL
        let adapter = entry.make(directory, AgentResume(cliSessionID: nil, model: nil, permissionMode: routine.permissionMode))
        guard let (session, evicted) = insertRoutineSession(routine, directory: directory, adapter: adapter, clientID: ownerClientID) else {
            return .refused(String(localized: "Too many chats are running on this Mac."))
        }
        let sink = lock.withLock { sinks[ownerClientID] }
        for old in evicted {
            forget(old.id)
            sink?(.closed(sessionID: old.id))
        }
        session.finishAlert = routine.notifiesWhenDone ?? true
        attach(adapter, to: session)
        sink?(.created(lock.withLock { session.info }))
        persist(session)
        agentLog.notice("routine chat created · \(routine.agentID, privacy: .public)")
        let prompt = routine.prompt
        launch(adapter, for: session) { [weak self, weak session] in
            guard let self, let session else { return }
            self.append(.userPrompt(text: prompt), to: session)
            adapter.prompt(prompt)
        }
        return .started(session.id)
    }

    private func insertRoutineSession(
        _ routine: AgentRoutine, directory: URL, adapter: any AgentAdapter, clientID: String
    ) -> (AgentSession, [AgentSession])? {
        lock.withLock {
            var existing = sessions.values.filter { $0.ownerClientID == clientID }
            guard existing.filter(\.adapterLive).count < Self.maximumLiveSessionsPerClient else { return nil }
            let evicted = makeRoom(among: &existing)
            let session = AgentSession(
                ownerClientID: clientID,
                agentID: routine.agentID,
                title: Self.uniqueTitle(base: routine.name, among: existing),
                directory: directory.path,
                adapter: adapter
            )
            session.permissionMode = routine.permissionMode
            sessions[session.id] = session
            return (session, evicted)
        }
    }

    /// The chat's state and how its last turn ended. A nil state is a chat that is gone.
    func routineChatStatus(_ id: UUID) -> (state: AgentSessionState?, finishedOK: Bool?) {
        lock.withLock {
            guard let session = sessions[id] else { return (nil, nil) }
            let finished = session.transcript.events.last { event in
                if case .turnFinished = event.payload { true } else { false }
            }
            guard case .turnFinished(let summary)? = finished?.payload else { return (session.state, nil) }
            return (session.state, summary.ok && !summary.stopped)
        }
    }

    func interruptRoutineChat(_ id: UUID) {
        let session = lock.withLock { sessions[id] }
        guard let session, lock.withLock({ session.adapterLive }) else { return }
        adapter(of: session).interrupt()
    }
}
