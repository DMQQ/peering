import Foundation
import RemoteCore

/// ``DuplicateInputFilter`` behind a lock: input arrives from the control connection's queue and the datagram socket's at once.
final class DuplicateInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var filter = DuplicateInputFilter()

    func shouldApply(_ command: RemoteCommand, from source: DuplicateInputFilter.Source) -> Bool {
        lock.withLock { filter.shouldApply(command, from: source, now: ProcessInfo.processInfo.systemUptime) }
    }
}
