import Foundation
import MacCastKit
import Observation
import RemoteCore
import SSHCore

extension SSHModel {
    /// Called from the transport, so it hops to the main actor to queue a sheet and waits. `owner` is the tab that asked: closing it answers its prompts with no.
    func ask(about prompt: SSHHostKeyPrompt, owner: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard terminals.contains(where: { $0.id == owner }) else {
                    continuation.resume(returning: false)
                    return
                }
                keyQueue.enqueue(PendingKeyPrompt(prompt: SSHKeyPrompt(prompt: prompt), continuation: continuation), owner: owner)
                keyPrompt = keyQueue.current?.prompt
            }
        }
    }

    func answerKeyPrompt(_ accepted: Bool) {
        keyQueue.removeCurrent()?.continuation.resume(returning: accepted)
        keyPrompt = keyQueue.current?.prompt
    }

    func refuseKeyPrompts() {
        for pending in keyQueue.removeAll() { pending.continuation.resume(returning: false) }
        keyPrompt = nil
    }

    func refuseKeyPrompts(ownedBy owner: UUID) {
        for pending in keyQueue.removeAll(owner: owner) { pending.continuation.resume(returning: false) }
        keyPrompt = keyQueue.current?.prompt
    }

    static func describe(_ error: SSHSessionError) -> String {
        switch error {
        case .hostKeyRejected:
            return String(localized: "You did not accept this server's key.")
        case .hostKeyChanged:
            return String(localized: "The server's key has changed since you last connected. If this was not you, do not continue.")
        case .transport(let reason):
            return reason
        case .notConnected:
            return String(localized: "The connection ended.")
        // A browse that failed is reported where it happened (see `browseMessage(_:)`).
        case .browse(let reason):
            return reason
        // Nor is a forward that failed: its sentence belongs on the forward's row. This case only keeps the switch exhaustive as the error type grows.
        case .forward(let reason):
            return SSHForwarder.describe(reason)
        }
    }
}
