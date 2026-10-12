import Foundation
import MacCastKit

extension HostServer {
    /// The Mac user's answer to a pairing that arrived without the QR secret.
    func resolvePairingApproval(sessionID: UUID, approved: Bool) {
        queue.async { [weak self] in
            guard let self, connections.holdsPairingPrompt(sessionID) else { return }
            connections.session(id: sessionID)?.resolveApproval(approved: approved)
        }
    }

    /// Only one connection at a time may put a pairing prompt in front of the Mac user, and each address only so often.
    func installPairingPrompt(on session: HostSession, address: String) {
        session.claimPairingPrompt = { [weak self, weak session] in
            guard let self, let session else { return .anotherPairingInProgress }
            return connections.claimPairingPrompt(session: session.id, address: address, now: Date())
        }
        session.releasePairingPrompt = { [weak self, weak session] in
            guard let self, let session else { return false }
            return connections.releasePairingPrompt(session: session.id)
        }
    }
}
