import Foundation

/// The session's event stream keeps only the newest events when the reader falls behind. A drop is reported by an `outputDropped` event placed ahead of the next output, so the marker is never the oldest thing in the buffer.
final class SSHEventSink: @unchecked Sendable {
    private let continuation: AsyncStream<SSHSessionEvent>.Continuation
    // `hasDropped` is guarded by `lock`.
    private let lock = NSLock()
    private var hasDropped = false

    init(_ continuation: AsyncStream<SSHSessionEvent>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ event: SSHSessionEvent) {
        guard case .output = event else {
            continuation.yield(event)
            return
        }
        let needsMarker = lock.withLock { () -> Bool in
            defer { hasDropped = false }
            return hasDropped
        }
        if needsMarker { continuation.yield(.outputDropped) }

        if case .dropped = continuation.yield(event) {
            lock.withLock { hasDropped = true }
        }
    }

    func finish() {
        continuation.finish()
    }
}
