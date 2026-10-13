import Foundation
import PeeringKit

/// Runs blocking file-system work with a cap on how much can be in flight and a deadline on the answer. A network mount that stops answering parks its thread in the kernel for good; the cap is what keeps the threads of everything else from going the same way.
enum FileWork {
    enum Outcome<Value: Sendable>: Sendable {
        case done(Value)
        case timedOut
        case busy
    }

    static let browsing = ConcurrencyLimiter(limit: 8)
    static let archiving = ConcurrencyLimiter(limit: 2)

    // Wire text: the phone looks these sentences up in its own catalog, so they stay English whatever language this Mac uses.
    static let timedOutMessage = "This Mac did not answer in time. The folder may be on a drive that is not responding."
    static let busyMessage = "This Mac is busy with other file requests. Try again in a moment."

    static func run<Value: Sendable>(
        limiter: ConcurrencyLimiter = browsing,
        timeout: TimeInterval = 15,
        work: @escaping @Sendable () -> Value,
        then deliver: @escaping @Sendable (Outcome<Value>) -> Void
    ) {
        guard limiter.tryAcquire() else {
            deliver(.busy)
            return
        }
        let once = Once()
        DispatchQueue.global(qos: .userInitiated).async {
            let value = work()
            // The slot comes back only when the work really ends, which for a hung mount may be never.
            limiter.release()
            if once.claim() { deliver(.done(value)) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if once.claim() { deliver(.timedOut) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false  // guarded by lock

        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }
}
