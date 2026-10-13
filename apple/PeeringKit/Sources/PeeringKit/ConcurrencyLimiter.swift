import Foundation

/// A cap on work in flight. Work that has timed out but whose thread is still parked in the kernel keeps its slot until it really ends, which is the point: a hung mount must not be able to take every thread.
public final class ConcurrencyLimiter: @unchecked Sendable {
    public let limit: Int
    private let lock = NSLock()
    private var inUse = 0  // guarded by lock

    public init(limit: Int) {
        self.limit = limit
    }

    public func tryAcquire() -> Bool {
        lock.withLock {
            guard inUse < limit else { return false }
            inUse += 1
            return true
        }
    }

    public func release() {
        lock.withLock { inUse = max(0, inUse - 1) }
    }

    public var activeCount: Int { lock.withLock { inUse } }
}
