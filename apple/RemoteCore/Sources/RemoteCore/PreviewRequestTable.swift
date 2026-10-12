import Foundation

/// The phone's open web-preview requests, so the events that come back on the control stream find the request that is waiting for them.
final class PreviewRequestTable: @unchecked Sendable {
    typealias Continuation = AsyncStream<PreviewProxyEvent>.Continuation

    /// A reader that stops reading would otherwise let a page's body pile up without bound.
    static let maximumBufferedEvents = 1024

    // Every property below is guarded by `lock`. Continuations are only resumed after it is released.
    private let lock = NSLock()
    private var waiting: [UInt32: Continuation] = [:]
    private var lastID: UInt32 = 0

    func register(_ continuation: Continuation) -> UInt32 {
        lock.withLock {
            lastID &+= 1
            waiting[lastID] = continuation
            return lastID
        }
    }

    /// Whether the request was still open, which is what decides if the Mac needs telling to stop.
    func remove(_ id: UInt32) -> Bool {
        lock.withLock { waiting.removeValue(forKey: id) != nil }
    }

    func deliver(_ event: PreviewProxyEvent) {
        let continuation = lock.withLock { () -> Continuation? in
            event.isFinal ? waiting.removeValue(forKey: event.requestID) : waiting[event.requestID]
        }
        guard let continuation else { return }
        let result = continuation.yield(event)
        // Ending the stream makes its termination handler tell the Mac to stop sending.
        if event.isFinal { continuation.finish() } else if case .dropped = result { continuation.finish() }
    }

    /// The link to the Mac is gone: every waiting request ends with a reason instead of hanging.
    func failAll(_ reason: PreviewFailure) {
        let all = lock.withLock { () -> [UInt32: Continuation] in
            let open = waiting
            waiting = [:]
            return open
        }
        for (id, continuation) in all {
            continuation.yield(.failure(id: id, reason: reason))
            continuation.finish()
        }
    }
}
