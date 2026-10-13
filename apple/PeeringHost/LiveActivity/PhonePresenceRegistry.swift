import Foundation
import PeeringKit

/// The shared answer to "is this phone looking at the app": one lock around ``PhonePresenceBook``, read from the terminal, agent and Live Activity code.
final class PhonePresenceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var book = PhonePresenceBook()

    func connected(clientID: String, session: UUID) {
        lock.withLock { book.connected(clientID: clientID, session: session) }
    }

    func backgroundChanged(clientID: String, session: UUID, background: Bool) {
        lock.withLock { book.backgroundChanged(clientID: clientID, session: session, background: background) }
    }

    func disconnected(clientID: String, session: UUID) {
        lock.withLock { book.disconnected(clientID: clientID, session: session) }
    }

    func presence(of clientID: String) -> PhonePresence {
        lock.withLock { book.presence(of: clientID) }
    }
}
