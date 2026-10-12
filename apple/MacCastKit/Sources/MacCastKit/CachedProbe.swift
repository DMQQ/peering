import Foundation

/// One probe in flight at a time, and its answer kept for a while. Callers that arrive meanwhile share it instead of each starting a slow command.
public final class CachedProbe<Value: Sendable>: @unchecked Sendable {
    public enum Step {
        case answer(Value)
        case wait
        case start
    }

    public let lifetime: TimeInterval
    private let lock = NSLock()
    private var cached: (value: Value, at: TimeInterval)?  // guarded by lock
    private var waiting: [@Sendable (Value) -> Void] = []  // guarded by lock
    private var running = false  // guarded by lock

    public init(lifetime: TimeInterval = 60) {
        self.lifetime = lifetime
    }

    /// `.start` means this caller must run the probe and call ``finish(_:at:)``; `.wait` means whoever runs it will call `reply`. On `.answer` the caller replies itself.
    public func request(at now: TimeInterval, reply: @escaping @Sendable (Value) -> Void) -> Step {
        lock.withLock {
            if let cached, now - cached.at < lifetime { return .answer(cached.value) }
            waiting.append(reply)
            guard !running else { return .wait }
            running = true
            return .start
        }
    }

    public func finish(_ value: Value, at now: TimeInterval) {
        let replies = lock.withLock { () -> [@Sendable (Value) -> Void] in
            cached = (value, now)
            running = false
            defer { waiting = [] }
            return waiting
        }
        for reply in replies { reply(value) }
    }
}
