import Foundation
import PeeringKit
import RemoteCore

extension AgentSessionManager {
    /// Sends a chat's live event to its owner, or holds it while the owner's connection is backed up. The transcript has every event either way.
    func forward(_ event: AgentEvent, from session: AgentSession, index: UInt64, to sink: Sink) {
        let sendNow = lock.withLock {
            outputs[session.ownerClientID, default: HeldOutput()].offer(event, key: session.id, index: index)
        }
        if sendNow { sink(event) }
    }

    /// While a client's connection is backed up its chats' events wait, and what did not fit is replayed from the transcript when it drains, as the phone does for itself after a reconnect.
    func setOutputPaused(_ paused: Bool, clientID: String) {
        guard !paused else {
            lock.withLock { outputs[clientID, default: HeldOutput()].pause() }
            return
        }
        guard let sink = lock.withLock({ sinks[clientID] }) else {
            _ = lock.withLock { outputs.removeValue(forKey: clientID) }
            return
        }
        var batch: HeldOutput<UUID, AgentEvent>.Batch? = lock.withLock { outputs[clientID]?.resume() }
        while let current = batch {
            for event in current.events { sink(event) }
            for (id, since) in current.resync.sorted(by: { $0.value < $1.value }) {
                if let session = lock.withLock({ sessions[id] }) { replay(session, since: since, sink: sink) }
            }
            batch = lock.withLock { outputs[clientID]?.finishedDraining() }
        }
    }
}
