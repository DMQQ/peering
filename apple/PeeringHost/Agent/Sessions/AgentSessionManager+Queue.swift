import Foundation
import PeeringKit
import RemoteCore

/// Messages typed behind a running turn are held here, not on the phone, so the next one goes out when the turn ends whether or not the phone is still connected. Held in memory only: a Mac that restarts loses them with the processes they were waiting on.
extension AgentSessionManager {
    static let queueLimit = 50

    func handleQueue(_ text: String, for session: AgentSession, sink: @escaping Sink) {
        guard text.utf8.count <= 64 * 1024 else {
            sink(.failed(sessionID: session.id, message: "That prompt is too long to send."))
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let outcome: AgentPromptQueue.Submission? = lock.withLock {
            if session.isBusy, session.queue.prompts.count >= Self.queueLimit { return nil }
            return session.queue.submit(text, sessionState: session.state)
        }
        switch outcome {
        case .none:
            sink(.failed(sessionID: session.id, message: "Too many messages are waiting in this chat."))
        case .send:
            guard sendNow(text, to: session) else {
                sink(.failed(sessionID: session.id, message: "That chat cannot be continued. Start a new one."))
                return
            }
        case .queued:
            announceQueue(of: session)
        }
    }

    func handleUnqueue(_ text: String, at index: Int, for session: AgentSession) {
        lock.withLock { _ = session.queue.remove(text, at: index) }
        announceQueue(of: session)
    }

    /// Gives a prompt to the CLI and records it as said. False when the chat has no process to give it to.
    @discardableResult
    func sendNow(_ text: String, to session: AgentSession) -> Bool {
        guard let adapter = ensureLive(session) else { return false }
        append(.userPrompt(text: text), to: session)
        adapter.prompt(text)
        return true
    }

    func announceQueue(of session: AgentSession) {
        let (prompts, sink) = lock.withLock { (session.queue.prompts, sinks[session.ownerClientID]) }
        sink?(.queueChanged(sessionID: session.id, prompts: prompts))
    }

    /// What a phone that just listed its chats still needs to be told: a queue it was away for.
    func announceQueues(ownedBy clientID: String, to sink: Sink) {
        let waiting = lock.withLock {
            sessions.values.filter { $0.ownerClientID == clientID && !$0.queue.prompts.isEmpty }.map { ($0.id, $0.queue.prompts) }
        }
        for (id, prompts) in waiting { sink(.queueChanged(sessionID: id, prompts: prompts)) }
    }
}
