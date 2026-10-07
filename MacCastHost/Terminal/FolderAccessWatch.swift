import Foundation

/// Reading a protected folder can park on the Mac's "Peering would like to access files in your Desktop folder" dialog, which nobody holding the phone can see. This says so after a short wait instead of leaving the caller in silence.
enum FolderAccessWatch {
    static let slowAfter: TimeInterval = 2.5

    static let listingMessage = "The Mac may be asking whether Peering can open this folder. Peering only reads folders you open from your phone, and shows them only to your paired devices. Allow it on the Mac and the list appears here."
    static let chatMessage = "Waiting for the Mac to allow access to this folder. If it shows a permission dialog, allow it there: Peering and the agent only read what you ask them to, and nothing leaves your paired devices."
    static let deniedMessage = "Peering cannot read this folder. If macOS blocked it, allow Peering under Privacy & Security, Files and Folders."

    /// Runs `work` here and calls `slow` once if it has not finished by then. `slow` never runs after `work` has returned, so its message cannot arrive behind the answer.
    static func perform<Result>(slow: @escaping @Sendable () -> Void, work: () -> Result) -> Result {
        let lock = NSLock()
        var finished = false
        let timer = DispatchWorkItem {
            lock.withLock { if !finished { slow() } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + slowAfter, execute: timer)
        let result = work()
        lock.withLock { finished = true }
        timer.cancel()
        return result
    }

    static func run<Result: Sendable>(
        slow: @escaping @Sendable () -> Void,
        work: @escaping @Sendable () -> Result,
        done: @escaping @Sendable (Result) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            done(perform(slow: slow, work: work))
        }
    }
}
