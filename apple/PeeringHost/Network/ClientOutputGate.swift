import Foundation
import MacCastKit
import RemoteCore

/// What one client is shown while it is not looking. Terminal output is not sent (the host keeps 512 KB of history and replays it on return); agent events are held in order, since an approval or a reply must still arrive.
final class ClientOutputGate: @unchecked Sendable {
    struct Return {
        let heldAgentEvents: [AgentEvent]
        let terminalNeedsReplay: Bool
    }

    private let lock = NSLock()
    private var inBackground = false  // guarded by lock
    private var terminalOutputSkipped = false  // guarded by lock
    private var heldAgentEvents = HeldEventQueue<AgentEvent>()  // guarded by lock

    /// False while the client is away, remembering that its screen is now behind.
    func admitsTerminalOutput() -> Bool {
        lock.withLock {
            guard inBackground else { return true }
            terminalOutputSkipped = true
            return false
        }
    }

    /// True when the event was kept for later and must not be sent now.
    func holdsAgentEvent(_ event: AgentEvent, cost: @autoclosure () -> Int) -> Bool {
        lock.withLock {
            guard inBackground else { return false }
            heldAgentEvents.append(event, cost: cost())
            return true
        }
    }

    /// What has to be delivered now that the client is back, or nil when nothing changed.
    func clientBackground(_ background: Bool) -> Return? {
        lock.withLock {
            guard background != inBackground else { return nil }
            inBackground = background
            guard !background else { return nil }
            defer { terminalOutputSkipped = false }
            return Return(heldAgentEvents: heldAgentEvents.drain(), terminalNeedsReplay: terminalOutputSkipped)
        }
    }
}
