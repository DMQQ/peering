import Foundation
import Network
import Security
import os

/// Rate-limits and merges outgoing commands so a 120 Hz touch stream does not flood the link.
///
/// - Absolute positions (`.mouseMove`) are superseded by a newer sample and replaced in place, the
///   original slot being kept so a coalesced move cannot jump ahead of an already-queued command.
/// - Relative deltas (`.joystickMove`, `.scroll`) are summed, never dropped, or a fast flick would
///   arrive as a single small nudge.
/// - Everything else goes out as it is produced, since a dropped `mouseUp` leaves a button stuck down.
///
/// The output rate is bounded by `interval` (60 Hz by default), except that a command arriving when
/// nothing has been sent for a full interval goes out immediately, without which a single tap would
/// wait up to 16 ms before its cursor move left.
public final class CommandCoalescer: @unchecked Sendable {
    public let interval: TimeInterval

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let sink: @Sendable (RemoteCommand) -> Void

    private var pending: [RemoteCommand] = []
    private var lastFlush: TimeInterval = 0
    private var timer: DispatchSourceTimer?

    public init(
        interval: TimeInterval = 1.0 / 60.0,
        queue: DispatchQueue = DispatchQueue(label: "pl.dmq.peering.commands"),
        sink: @escaping @Sendable (RemoteCommand) -> Void
    ) {
        self.interval = interval
        self.queue = queue
        self.sink = sink
    }

    deinit { timer?.cancel() }

/// Arms the trailing-edge timer, if there is anything for it to send. A timer with an empty queue
/// is a pointless 60 Hz wake-up for the life of a session. Idempotent.
    public func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        guard !pending.isEmpty else { lock.unlock(); return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        // A little leeway: this is a stream of cursor positions, and waking the CPU at an
        // exact 16.6 ms boundary costs power for a frame the eye cannot distinguish.
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in self?.flush() }
        timer = source
        lock.unlock()
        source.resume()
    }

    public func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    public var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer != nil
    }

    public func enqueue(_ command: RemoteCommand) {
        lock.lock()
        insert(command)
        let due = command.coalescing == .none || now() - lastFlush >= interval
        let batch = due ? drain() : []
        let waiting = !pending.isEmpty
        lock.unlock()

        for item in batch { sink(item) }
        if waiting { start() }
    }

/// Sends whatever is pending. Disarms the timer when the queue comes back empty.
    public func flush() {
        lock.lock()
        let batch = drain()
        let idle = pending.isEmpty
        lock.unlock()
        for item in batch { sink(item) }
        if idle { stop() }
    }

    // MARK: - Queue handling (call with `lock` held)

    private func insert(_ command: RemoteCommand) {
        switch command.coalescing {
        case .none:
            pending.append(command)

        case .replaceLatest:
            // Replaced in place: appending would reorder the move ahead of commands queued before
            // it, which for a move-then-click pair means clicking at the previous position.
            if let index = pending.firstIndex(where: { Self.sameShape($0, command) }) {
                pending[index] = command
            } else {
                pending.append(command)
            }

        case .accumulate:
            if let index = pending.firstIndex(where: { Self.sameShape($0, command) }),
               let merged = Self.merge(pending[index], command) {
                pending[index] = merged
            } else {
                pending.append(command)
            }
        }
    }

    private func drain() -> [RemoteCommand] {
        guard !pending.isEmpty else { return [] }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lastFlush = now()
        return batch
    }

    private func now() -> TimeInterval {
        // `DispatchTime` rather than `Date`: this measures an interval, and a wall clock can
        // step backwards when the device syncs its time mid-gesture.
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Case-level, not value-level: two `.mouseMove`s collapse, but a `.mouseMove` and a
    /// `.joystickMove` are different channels of control and must not.
    private static func sameShape(_ lhs: RemoteCommand, _ rhs: RemoteCommand) -> Bool {
        switch (lhs, rhs) {
        case (.mouseMove, .mouseMove): return true
        case (.joystickMove, .joystickMove): return true
        case (.scroll, .scroll): return true
        default: return false
        }
    }

    private static func merge(_ older: RemoteCommand, _ newer: RemoteCommand) -> RemoteCommand? {
        switch (older, newer) {
        case (.joystickMove(let x1, let y1), .joystickMove(let x2, let y2)):
            return .joystickMove(dx: x1 + x2, dy: y1 + y2)
        case (.scroll(let x1, let y1), .scroll(let x2, let y2)):
            return .scroll(dx: x1 + x2, dy: y1 + y2)
        default:
            return nil
        }
    }
}
